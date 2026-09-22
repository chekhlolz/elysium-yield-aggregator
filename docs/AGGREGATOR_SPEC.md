# Elysium Yield Aggregator — Architectural Specification

**Status**: design draft · **Target chain**: Elysium mainnet (Arbitrum Orbit L2 by Kinetiq) · **Depends on**: HyperCore market-data read precompile + ElysiumCoreWriter predeploy (both ship ~4 weeks post-mainnet)

---

## 1. Why this product

### 1.1 The gap

HyperCore currently hosts four yield sources for HYPE-denominated capital:

| # | Source | Yield (Sep 2026) | Notes |
|---|---|---|---|
| 1 | HYPE native staking | 1.89% APY | on HyperEVM, unstake 8-9d |
| 2 | kHYPE LST (Liminal, $1.215B TVL) | ~3-4% APY | includes staking + LST premium |
| 3 | HYPE perp funding (long → short receive) | 10.30% APY (90d mean) | **93.4% of 15,750 historical hours positive** |
| 4 | Basis (spot + short perp delta-neutral) | 12-15% APY | depends on funding regime |

**No one aggregates all four.** Liminal xHYPE does source #4 only (TVL $7.04M, 14.50% APY). Anyone else wants to manually rebalance across sources, or accept a single-product yield.

The aggregator is a dynamic allocation router that switches between sources based on funding regime, staking yield curves, and current perp basis. Its alpha over Liminal comes from switching, not from any single yield source.

### 1.2 Why Elysium (not HyperEVM)

Three Elysium-native advantages that HyperEVM cannot match:

1. **100-200ms blocks** → sub-second reaction to funding regime change. HyperEVM 1s blocks are too slow for switching on a 15-hour negative funding streak (longest historical).
2. **Market-data read precompile** → on-chain decisions, no oracle gas. HyperEVM has to pull from the API.
3. **ElysiumCoreWriter predeploy** → cross-chain perp rebalance in 100-200ms. HyperEVM vaults route through HyperCore RPC with no on-chain intent primitive.

## 2. Architecture

```
┌──────────────────────────────────────────────────────────┐
│  Elysium L2                                                │
│                                                            │
│  ┌────────────────────────────────────────────────────┐   │
│  │  YieldAggregator (ERC-4626 vault)                  │   │
│  │   - shares() / totalAssets()                       │   │
│  │   - allocate(regime, weights)                      │   │
│  │   - deposit() / withdraw() / previewWithdraw()     │   │
│  │   - rebalance() [keeper-only, timelocked]          │   │
│  └────────────────────────────────────────────────────┘   │
│            │  │  │  │                                       │
│            ▼  ▼  ▼  ▼                                       │
│    ┌─────┐ ┌────┐ ┌────┐ ┌────┐                            │
│    │Spot │ │kHYP│ │Perp│ │Basi│  <- YieldLeg contracts     │
│    │vault│ │mint│ │keep│ │hedg│                            │
│    └─────┘ └────┘ └────┘ └────┘                            │
│                                                            │
│  ┌────────────────────────────────────────────────────┐   │
│  │  RegimeDetector (read-only on-chain)               │   │
│  │    - reads HyperCore market-data precompile        │   │
│  │    - emits FundRegimeUpdated(regime, ts)           │   │
│  │    - regimes: FUNGING_STRONG / FUNDING_WEAK /      │   │
│  │              FUNDING_NEG / HIGH_VOL                 │   │
│  └────────────────────────────────────────────────────┘   │
│                                                            │
│  ┌────────────────────────────────────────────────────┐   │
│  │  ElysiumCoreWriter predeploy                       │   │
│  │    - intent(user, asset, side, size)                │   │
│  │    - keeper signs as trade-only agent               │   │
│  │    - executes on HyperCore in 100-200ms             │   │
│  └────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────┘
                          │
                          │ settlement (100-byte cert)
                          ▼
                    ┌───────────┐
                    │ HyperEVM  │  <- L1, chain ID 999
                    └───────────┘
                          │
                          ▼
                    ┌───────────┐
                    │ HyperCore │  <- venue where perps, kHYPE, spot live
                    └───────────┘
```

## 3. Core contracts

### 3.1 `YieldAggregator.sol` — ERC-4626 vault

```solidity
interface IYieldAggregator {
    struct Share {
        address owner;
        uint256 amount;
    }
    function shares(address) external view returns (uint256);
    function totalAssets() external view returns (uint256);
    function asset() external view returns (address);   // always USDC (or HYPE)
    function deposit(uint256 shares, address receiver) external returns (uint256);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256);
    function previewDeposit(uint256 assets) external view returns (uint256);
    function previewWithdraw(uint256 shares) external view returns (uint256);

    // Regime-driven allocation (keeper triggers, timelocked)
    event AllocationChanged(Regime regime, uint256[4] weights, uint64 executedAt);

    struct Regime {
        address spotVault;   // IYieldLeg
        address khypeVault;  // IYieldLeg
        address perpKeeper;  // IYieldLeg
        address basisHedge;  // IYieldLeg
        uint8[] weights;     // [0..10000], sum = 10000
    }
    function allocate(Regime calldata regime) external;
}
```

- **ERC-4626** share accounting so any frontend can display APY without bespoke math.
- **Regime** is a tuple: 4 legs + 4 weight buckets (0..10000 basis points).
- `allocate` is called by keeper; it computes dollar allocation, calls each leg's `allocateTo`, and emits `AllocationChanged`.
- Allocation changes are **timelocked** (default 5 min) — see §3.5.

### 3.2 `IYieldLeg.sol` — abstraction for each yield source

```solidity
interface IYieldLeg {
    function name() external view returns (string memory);
    function expectedApy() external view returns (uint256);  // bps, real-time
    function apyHistory() external view returns (uint256[] memory);
    function allocateTo(uint256 amount) external returns (uint256);   // returns allocated USD
    function harvest() external;                                       // move realized yield to aggregator
}
```

Each of the 4 legs is a separate contract implementing this interface. The aggregator treats them as opaque black boxes. This is the key architectural decision — **the aggregator never touches HyperCore state directly**; it always routes through a leg.

### 3.3 The four legs

| Leg | Underlying | Mechanism |
|---|---|---|
| `SpotStakingLeg` | HYPE staking on HyperEVM | bridge HYPE, stake via HyperEVM LSP, harvest rewards |
| `KHYPELeg` | kHYPE LST on HyperCore | mint kHYPE via HyperCore spot, receive LST yield |
| `PerpFundingLeg` | Long spot + short perp | ElysiumCoreWriter intent for perp open; receives funding hourly |
| `BasisHedgeLeg` | HR=1.0 delta-neutral | Same infra as PerpFundingLeg but hedged with `hypeback` HR=1.0 params |

### 3.4 `RegimeDetector.sol` — pure on-chain observer

```solidity
contract RegimeDetector {
    struct RegimeSnapshot {
        uint8 regime;              // 0=FUNDING_STRONG, 1=WEAK, 2=NEG, 3=HIGH_VOL
        uint256 fundingApy_30m;    // read from market-data precompile
        uint256 fundingApy_24h;
        uint256 hypeVol_24h;
        uint256 basisBps;          // spot - perp mark
        uint64 observedAt;
    }

    event RegimeUpdated(uint8 indexed regime, uint256 fundingApy, uint64 ts);

    // Keeper calls every block to keep state fresh
    function observe() external;

    function current() external view returns (RegimeSnapshot memory);
}
```

Regime thresholds:

| Regime | Trigger | Allocation shift |
|---|---|---|
| FUNDING_STRONG | 24h funding > 8% APY | PerpFunding 60% / BasisHedge 30% / KHYPE 10% |
| FUNDING_WEAK | 24h funding 3-8% | PerpFunding 40% / BasisHedge 20% / KHYPE 20% / Spot 20% |
| FUNDING_NEG | 24h funding < 0% | PerpFunding 0% / KHYPE 60% / Spot 40% |
| HIGH_VOL | 24h realized vol > 90% | KHYPE 50% / Spot 50% (perp exposure off) |

Thresholds are tunable via governance; defaults above are the `hypeback` sensitivity-sweep winners (see README).

### 3.5 Keeper + timelock

```
keeper (relayer) → allocate(regime) → aggregator timelock (5 min) → execute
```

The 5-minute timelock is a safety net against keeper compromise. During the timelock, `cancelPending()` can be called by any address (or via governance) to abort a malicious allocation.

## 4. Alpha sources (vs Liminal xHYPE 14.50% live APY)

| Source | Mechanism | Estimated edge |
|---|---|---|
| Regime switching | PerpFundingLeg → KHYPELeg on FUNDING_NEG regime | +2-3% APY (based on 15h longest negative streak in data) |
| Fast rebalance | 100-200ms ElysiumCoreWriter vs 1-2s HyperEVM block | +0.5-1% APY (less slippage on rebalance) |
| On-chain decisions | market-data precompile vs oracle gas | +0.3-0.5% APY (no oracle cost) |
| Basis opportunity | capture spot-perp basis via BasisHedgeLeg on regime shift | +0.5-1% APY |

**Total edge estimate**: +3-5% APY over Liminal, achievable only if the aggregator reacts faster than the market can adapt to its own rebalancing.

## 5. Kill gate

Before any production deployment, the aggregator's simulated performance must clear the `hypeback` kill gate on **the exact same funding data**:

- Net APY > 4% annualized
- Max DD < 15%
- Zero liquidations over the full 2024-12 → 2026-09 window

The current delta-neutral baseline (HR=1.0, Lev=3) clears this at 13.28% APY / 0.23% DD. The aggregator is expected to clear it at higher APY since it adds regime switching on top of the delta-neutral floor.

## 6. Deployment timeline

| Phase | Dependency | Deliverable |
|---|---|---|
| 0 | mainnet launch | `YieldAggregator.sol`, `IYieldLeg.sol`, `RegimeDetector.sol` deployed to Elysium mainnet |
| 1 | +4 weeks (precompiles ship) | 4 leg contracts live; aggregator in "observe-only" mode |
| 2 | +8 weeks | Timelock shortened from 5 min → 30s after 30d no-incident |
| 3 | +12 weeks | Governance enables (Tally + snapshot), keeper becomes open |

## 7. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Keeper gets compromised | 5-min timelock + `cancelPending()` from any address |
| Precompile latency spike | Fallback to stale state (regime only updates when fresh data arrives) |
| kHYPE unstake > 9d blocks rebalance | Keep 10% of vault always in HYPE spot for liquidity |
| Funding regime flips within 100ms window | RegimeDetector uses 24h EMA, not instantaneous rate |
| Elysium sequencer halts | Aggregator can pause `allocate()` via governance |
| ElysiumCoreWriter fails mid-flight | Reconciler task compares intended vs executed, emits `IntentFailed` event |

## 8. What's not in scope

- **Options market** — HyperCore does not have options; this aggregator is perp + spot + LST only.
- **Multi-asset** — aggregator is HYPE-USD only. BTC/ETH aggregators are a future version, same architecture.
- **Institutional custody** — aggregator is open-source and permissionless; institutional use requires a separate custody layer that this spec does not cover.
- **MEV capture** — Kinetiq explicitly says "no privileged lanes" in Elysium's fee market. The aggregator does not attempt search or bundle; it just reacts to on-chain state.

## 9. Reference numbers (from `hypeback`)

Deterministic seed=42, funding history 2024-12-05 → 2026-09-22:

| Config | Net APY | Max DD | Sharpe | Liq |
|---|---|---|---|---|
| HR=1.0, Lev=3, 2 rebal/day | 13.28% | 0.23% | 19.67 | n |
| HR=1.5, Lev=3, 2 rebal/day | 6.50% | 25.02% | 0.42 | n (but MC: 31/500 liq) |
| HR=2.0, Lev=3, 2 rebal/day | -0.51% | 49.50% | - | Y (MC) |
| HR=1.0, 90d window | 58.01% | — | — | — |
| Liminal xHYPE (live) | 14.50% | — | — | — |

MC edge vs Liminal (median 500 paths): **+1.41% APY** on HR=1.0 delta-neutral baseline. Regime switching expected to add another +1.5-2% APY in the aggregator layer.

---

*Generated for the Elysium builder workstream. Questions to the Kinetiq team on the `builders` allocation allocation channel.*
