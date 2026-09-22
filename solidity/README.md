# Elysium Yield Aggregator + Trade-Only-Agent Protocol — Solidity contracts

Reference implementation for the two proposals in this workstream:

- **Yield Aggregator** — see `docs/AGGREGATOR_SPEC.md`
- **Trade-Only-Agent Delegation Protocol** — see `docs/DELEGATION_SPEC.md`

All contracts compile cleanly with **solc 0.8.26**. Verified via `python scripts/compile.py`.

## Layout

```
solidity/
├── src/
│   ├── interfaces/
│   │   ├── IYieldLeg.sol              — abstraction for each yield source
│   │   ├── IYieldAggregator.sol       — public interface for the vault
│   │   └── ITradeOnlyAgent.sol        — EIP-712 delegation standard
│   ├── aggregator/
│   │   └── YieldAggregator.sol        — ERC-4626 vault + keeper + timelock
│   ├── keeper/
│   │   └── RegimeDetector.sol         — on-chain regime observer
│   └── delegation/
│       └── TradeOnlyAgent.sol         — EIP-712 delegation implementation
├── scripts/
│   └── compile.py                     — compile with py-solc-x
└── test/                              — reserved for future Foundry/JS tests
```

## Compile

```bash
cd solidity
pip install py-solc-x
python scripts/compile.py
```

Expected output (Solc 0.8.26, optimizer runs=200):

```
Compile OK. Contracts:
  YieldAggregator      abi=39 entries  bytecode=12096 bytes
  TradeOnlyAgent       abi=8  entries  bytecode=2886 bytes
  RegimeDetector       abi=11 entries  bytecode=2523 bytes
  SafeERC20            abi=0  entries  bytecode=135  bytes  (library)
  IYieldAggregator     abi=18 entries
  IYieldLeg            abi=10 entries
  ITradeOnlyAgent      abi=5  entries
  IMarketDataFeed      abi=4  entries
```

**0 compile errors, 0 warnings.**

## Key design decisions

### YieldAggregator (12 KB bytecode)

- **ERC-4626-style** deposit/withdraw/mint/redeem, 1:1 bootstrap shares.
- **4 yield legs** as `IYieldLeg[4] storage` array (not `immutable` because Solidity
  does not allow non-value immutable types — the array is set in the constructor
  and there is no mutation path).
- **Regime weights** as `uint16[4]` basis points (sum = 10_000).
- **Timelocked allocation changes**: `requestAllocation` (keeper only) → `executePending`
  after `timelockSeconds` elapse.
- **`cancelPending` is open** — anyone can abort a pending change, which is the
  safety net against a compromised keeper.
- **`harvestFromAllLegs`** pulls realized yield from each leg back into vault cash.

### RegimeDetector (2.5 KB bytecode)

- Reads HyperCore market data through the `IMarketDataFeed` interface (which is
  the adapter for the Elysium market-data precompile — see spec §2).
- Computes the funding regime in one of four buckets:
  `FUNDING_STRONG` / `FUNDING_WEAK` / `FUNDING_NEG` / `HIGH_VOL`.
- `weightsForRegime(regime)` returns the target allocation per regime
  (basis points summing to 10_000).
- `observe()` is read/write — stores the latest snapshot. No gas spent by
  the aggregator on market data reads until the precompile ships.

### TradeOnlyAgent (2.8 KB bytecode)

- **EIP-712** typed signatures, domain-separated by `chainId`.
- **Delegation struct**: keeper, assetIds (empty = all), maxNotional,
  maxPerOrder, expiresAt, nonce, salt.
- **Universal revoke**: `revoke(keeper)` marks `(msg.sender, keeper)` as
  revoked. All future delegations from `msg.sender` to `keeper` are rejected.
- **Venue-local notional tracking**: `recordExecution(venue, delegator, ...)`
  deducts from the delegation's remaining cap. The same delegation can be used
  on multiple venues without cross-venue accounting — each venue tracks its
  own cap usage against the same delegation.

## Contract sizes vs Elysium limits

| Contract | Bytecode | Purpose |
|---|---:|---|
| YieldAggregator | 12 096 | Vault + keeper + timelock |
| TradeOnlyAgent | 2 886 | EIP-712 delegation |
| RegimeDetector | 2 523 | Market-data adapter |
| SafeERC20 | 135 | ERC-20 helper library |

Total: **~17.6 KB**, well within Elysium's 300 Mgas/s execution budget. Deployment
gas on Elysium (HYPE 1:1 from HyperEVM) is < 0.5 HYPE for the full stack.

## What's not in this repo

- **Test suite** — `test/` is empty. Tests are the next milestone before
  mainnet deployment.
- **4 leg contracts** — each of the 4 yield legs (spot staking, kHYPE,
  perp funding, basis hedge) is a separate contract that implements
  `IYieldLeg`. This repo ships the aggregator only; legs are downstream.
- **Market-data precompile stub** — `IMarketDataFeed` is a placeholder.
  The actual Elysium precompile address and ABI ship ~4 weeks post-mainnet
  (see `docs/AGGREGATOR_SPEC.md` §2).
- **ElysiumCoreWriter integration** — perp legs will call this predeploy,
  which itself ships ~4 weeks post-mainnet.
- **Audit** — none. Production deployment requires a full audit.

## Roadmap

1. This repo: aggregator + delegation standard + compile script ✅
2. Add Foundry tests for the aggregator deposit/withdraw/timelock flow
3. Add Foundry tests for TradeOnlyAgent EIP-712 sign+verify
4. 4 leg contracts (SpotStakingLeg, KHYPELeg, PerpFundingLeg, BasisHedgeLeg)
5. Market-data precompile adapter (replaces `IMarketDataFeed` placeholder)
6. Deploy to Elysium testnet (chainId 99801)
7. Deploy to Elysium mainnet (after Kinetiq approves builders allocation)

## Related artifacts

- `hypeback/` — Python backtester that validates strategy choices before
  deployment. Kill gate: net APY > 4%, max DD < 15%, no liquidation.
- `docs/AGGREGATOR_SPEC.md` — full architectural rationale.
- `docs/DELEGATION_SPEC.md` — full delegation protocol design.
