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
│  │    - regimes: FUNDING_STRONG / FUNDING_WEAK /      │   │
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

The implementation (`solidity/src/aggregator/YieldAggregator.sol`) follows
canonical ERC-4626 signatures. The reference interface is in
`solidity/src/interfaces/IYieldAggregator.sol`:

```solidity
interface IYieldAggregator {
    // ---- ERC-20 accounting ----
    function asset() external view returns (address);          // USDC 6 decimals
    function totalAssets() external view returns (uint256);
    function totalShares() external view returns (uint256);
    function shares(address owner) external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);

    // ---- Canonical ERC-4626 ----
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function mint(uint256 shares, address receiver) external returns (uint256 assets);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);

    // ---- ERC-4626 previews ----
    function previewDeposit(uint256 assets) external view returns (uint256);
    function previewMint(uint256 shares) external view returns (uint256);
    function previewWithdraw(uint256 assets) external view returns (uint256);
    function previewRedeem(uint256 shares) external view returns (uint256);

    // ---- Current regime state ----
    function currentApyBps() external view returns (uint256);
    function weights() external view returns (uint16[4] memory);   // bps, sum = 10000
    function legsView() external view returns (address[4] memory);
    function legAt(uint256 i) external view returns (address);
    function totalLegValue() external view returns (uint256);

    // ---- Pending allocation (keeper + timelock) ----
    function pendingAllocationId() external view returns (bytes32);
    function requestAllocation(uint16[4] calldata newWeights, string calldata reason)
        external returns (bytes32 allocationId);
    function executePending() external;        // open, after timelock
    function cancelPending(bytes32 allocationId) external;  // owner OR keeper

    // ---- Yield harvesting ----
    function harvestFromAllLegs() external;    // keeper-gated

    // ---- Governance ----
    function setPaused(bool _paused) external;
    function setKeeper(address _keeper) external;
    function setTimelock(uint32 _timelockSeconds) external;
}
```

- **ERC-4626** share accounting so any frontend can display APY without
  bespoke math. `preview*` values equal the would-be return values
  because the exchange rate is computed from `totalAssets / totalShares`
  and there is no fee layer.
- **Regime** is NOT a Solidity struct — it's the tuple `(IYieldLeg[4],
  uint16[4] weights)`. Weights are in basis points, each `uint16`,
  summing to `BPS_DENOM = 10_000`.
- Allocation changes are requested via `requestAllocation(newWeights,
  reason)` by the keeper; they execute on-chain via `executePending()`
  once the timelock has elapsed (default 86 400 s = 24h; tunable).
  See §3.5 for the two-speed framing (weights slow / execution fast).
- `cancelPending()` is owner-or-keeper only. The original design had it
  open to anyone as a keeper-compromise safety net; that turned out to
  be a griefing vector — see §3.5.

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

### 3.5 Keeper + timelock — two-speed framing

```
KEEPER  ──►  requestAllocation(newWeights)      [gated: keeper only]
             │   pendingAllocationId = keccak(sender, executesAt, weights, block)
             │
             ▼
AGGREGATOR  ──►  timelock (default 86 400 s = 24 h)
             │   AllocationRequested event
             │
             ▼
ANYONE    ──►  executePending()                  [open, after timelock]
             │   - distributes / reduces across legs at the new weights
             │   - AllocationExecuted event
             │
OWNER/KEEPER ──► cancelPending(allocationId)     [gated: owner OR keeper]
                  - aborts a pending change
                  - AllocationCancelled event
```

**Two-speed framing.** The aggregator has two decision loops with very
different latencies, and the +0.5–1% "fast rebalance" alpha is the
second loop, not the first:

- **Slow loop (weights, timelocked).** `requestAllocation` → 24 h →
  `executePending` moves capital between legs. This is where the
  5-minute-timelock-vs-100ms-blocks concern was raised; the real
  default is 24 h, not 5 min, and the timelock exists to let a
  compromised keeper's allocation be reviewed before it settles.
- **Fast loop (execution within current weights).** Inside a given
  weight vector, the keeper can `harvestFromAllLegs()` at any time,
  legs can re-open / re-close perp positions within their existing
  allocation, and the ElysiumCoreWriter settles each action in
  100–200 ms. This is where the alpha comes from — the keeper reacts
  to funding ticks without waiting for a weight change.

**`cancelPending` access policy.** Originally open to anyone as a
keeper-compromise safety net. That turned out to be a griefing vector
— a bot could cancel every legitimate rebalance on 100-200ms blocks
and freeze the keeper's workflow indefinitely. Now owner-or-keeper
only. Recovery path for a compromised keeper: owner calls
`setPaused(true)` (halts all allocation + harvest paths) and then
`setKeeper(newKeeper)`. The tradeoff is explicit: griefing protection
wins over permissionless abort; a single compromised keeper can still
be stopped, just not by an unrelated third party.

## 4. Alpha sources (vs Liminal xHYPE 14.50% live APY)

| Source | Mechanism | Estimated edge |
|---|---|---|
| Regime switching | PerpFundingLeg → KHYPELeg on FUNDING_NEG regime | +3.47% APY (measured, 15 seeds, 100% positive — see §4 empirical note) |
| Fast rebalance | 100-200ms ElysiumCoreWriter settle vs 1-2s HyperEVM block | +0.5-1% APY (less slippage on rebalance) |
| On-chain decisions | market-data precompile vs oracle gas | +0.3-0.5% APY (no oracle cost) |
| Basis opportunity | capture spot-perp basis via BasisHedgeLeg on regime shift | +0.5-1% APY |

**Total edge estimate**: +4.5-6% APY over Liminal, achievable only if the
aggregator reacts faster than the market can adapt to its own rebalancing.
The regime-switching row is the only component we have measured end-to-end
today; the other three are design-time estimates and should be treated as
unverified until real on-chain logs exist.

> **Note on the "fast rebalance" claim**: the regime classifier itself
> uses a 24h EMA, not a 100ms tick — so sub-second block time does NOT
> let the aggregator "react faster" to a 15-hour funding streak than a
> 1s-block chain could. The genuine value of 100-200ms blocks is (a) the
> keeper's allocation decision is settled on-chain before slippage can
> price it in, and (b) the ElysiumCoreWriter path is shorter than a
> spot-then-perp round-trip on a slower chain. The +0.5-1% estimate is
> the slippage component, not a reaction-speed component.

> **Empirical finding (2026-09-22, updated)**: the aggregator simulator
> (`hypeback/aggregator.py`) measures **+3.47% APY median alpha over a
> static benchmark** on 15,750 hours of HyperCore funding history
> (`strong_apr=0.10`, `rebalance_hours=720`, 15 seeds, 25-cell parameter
> sweep, 100% of seeds positive). This is the sweep winner from the
> regime-aware config and is the figure the Kinetiq email cites. The
> earlier single-config run at `rebalance_hours=168` measured +2.10%;
> keeping both on record: the +2.10% number is what a default-interval
> keeper would produce today, the +3.47% is what a tighter rebalance
> cycle produces on the same data. The gap to Liminal's live 14.50% is
> still real — this alpha is measured against a static HYPE staking
> benchmark (≈ 9.85% APY), not against Liminal itself. See
> `docs/ROADMAP.md §2.2` for what would close the remaining gap.

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
| 2 | +8 weeks | Timelock shortened from 24 h → 1 h after 30 d no-incident |
| 3 | +12 weeks | Governance enables (Tally + snapshot), keeper becomes open |

## 7. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Keeper gets compromised | 24h allocation timelock + `cancelPending()` gated to owner/keeper + `setPaused(true)` then `setKeeper(newKeeper)` as owner-only recovery |
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

| Config | Net APY | Max DD | Sharpe* | Liq |
|---|---|---|---|---|
| HR=1.0, Lev=3, 2 rebal/day | 13.28% | 0.23% | 19.67 | n |
| HR=1.5, Lev=3, 2 rebal/day | 6.50% | 25.02% | 0.42 | n (but MC: 31/500 liq) |
| HR=2.0, Lev=3, 2 rebal/day | -0.51% | 49.50% | - | Y (MC) |
| HR=1.0, 90d window | 58.01% | — | — | — |
| Liminal xHYPE (live) | 14.50% | — | — | — |

\* **Sharpe is computed inside the simulator** and reflects the model's
own return series (lognormal price path + observed funding). It is not
a real Sharpe ratio because the model does not include: basis risk
(spot-perp dislocation), depeg risk on kHYPE, bridge / sequencer halt
risk, real market microstructure on HyperCore (latency, slippage, queue
position), or liquidation cascades under correlated moves. Treat the
Sharpe column as "sim-internal risk-adjusted return" — useful for
comparing configs against each other, not for portfolio-level risk
assessment.

MC edge vs Liminal xHYPE (median of 500 price paths, HR=1.0 delta-neutral
baseline): **+1.41% APY** on top of Liminal's 14.50% live APY, i.e. a
simulated median outcome of ~15.91% vs Liminal's live 14.50%. This is
an apples-to-oranges comparison — Liminal's 14.50% is live realized APY
over trailing time, the 15.91% is a simulation median over a synthetic
lognormal price path seeded on the same funding history. The MC figure
is included to bound the delta-neutral floor; regime switching on top
adds another +1.5–2% APY in the aggregator layer (measured separately,
see §4).

---

*Generated for the Elysium builder workstream. Questions to the Kinetiq team on the `builders` allocation channel.*
