# Elysium Yield Aggregator + Trade-Only-Agent Protocol — Solidity contracts

Reference implementation for the two proposals in this workstream:

- **Yield Aggregator** — see `docs/AGGREGATOR_SPEC.md`
- **Trade-Only-Agent Delegation Protocol** — see `docs/DELEGATION_SPEC.md`

All contracts compile cleanly with **solc 0.8.26**. Verified via
`python scripts/compile.py` (or the recursive `python scripts/build.py`).
Independent drift check: `python check_repo.py .` at the repo root.

## Layout

```
solidity/
├── src/
│   ├── interfaces/
│   │   ├── IYieldLeg.sol              — abstraction for each yield source
│   │   ├── IYieldAggregator.sol       — public interface for the vault
│   │   ├── ITradeOnlyAgent.sol        — EIP-712 delegation standard
│   │   ├── IERC20.sol                 — minimal ERC-20 + SafeERC20 lib
│   │   ├── IERC20Router.sol           — spot-router stub (router address set by deployer)
│   │   ├── IStakingPool.sol           — HyperEVM direct staking pool
│   │   ├── IElysiumCoreWriter.sol     — perp-intent writer stub
│   │   ├── IPriceOracle.sol           — live price source (oracle wiring TODO)
│   │   └── IFundingSource.sol         — live funding-rate source
│   ├── aggregator/
│   │   └── YieldAggregator.sol        — ERC-4626 vault + keeper + timelock
│   ├── keeper/
│   │   └── RegimeDetector.sol         — on-chain regime observer
│   ├── delegation/
│   │   └── TradeOnlyAgent.sol         — EIP-712 delegation implementation
│   └── legs/
│       ├── KHYPELeg.sol               — kHYPE LST on HyperCore
│       ├── SpotStakingLeg.sol         — HYPE staking on HyperEVM
│       ├── PerpFundingLeg.sol         — long spot + short perp (funding)
│       └── BasisHedgeLeg.sol          — HR=1.0 delta-neutral basis
├── scripts/
│   ├── compile.py                     — compile with py-solc-x (recursive discovery)
│   ├── build.py                       — alt compile entrypoint
│   ├── verify.py                      — ABI + EIP-712 + event verifier
│   └── deploy.py                      — deploy harness (dry-run + mock-testable)
├── tests/
│   ├── mock_provider.py               — MockProvider for deploy.py tests
│   └── test_deploy.py                 — 4 unittest tests (skip if web3 missing)
└── output/                            — gitignored deploy manifests
```

## Compile

```bash
cd solidity
pip install py-solc-x
python scripts/compile.py
```

Fresh build stats (source of truth; regenerate with `python scripts/compile.py`):

```
contract                  abi  deployed B  creation B
YieldAggregator            46       10979       12151
TradeOnlyAgent              8        2811        2839
RegimeDetector             13        2650        2926
KHYPELeg                   26        6918        7495
SpotStakingLeg             27        6926        7503
PerpFundingLeg             32        7140        7775
BasisHedgeLeg              33        6988        7576
SafeERC20                   0          85         135  (library)
RegimeId                    0          85         135  (enum)
IYieldAggregator           27           0           0
IYieldLeg                  10           0           0
ITradeOnlyAgent             5           0           0
IERC20Minimal               5           0           0
IERC20Router                3           0           0
IStakingPool                9           0           0
IElysiumCoreWriter          2           0           0
IPriceOracle                2           0           0
IFundingSource              2           0           0
IMarketDataFeed             4           0           0
```

**0 compile errors, 2 warnings** (the two warnings are
`previewMint`/`previewRedeem` colliding with the `shares(address)`
getter inside `YieldAggregator.sol` — pre-existing and cosmetic; the
preview methods are required by ERC-4626).

## Key design decisions

### YieldAggregator (12.2 KB creation bytecode, 11.0 KB deployed)

- **ERC-4626** canonical surface: `deposit` / `mint` / `withdraw` /
  `redeem` / `previewDeposit` / `previewMint` / `previewWithdraw` /
  `previewRedeem` / `convertToShares` / `convertToAssets`. 1:1
  bootstrap shares.
- **4 yield legs** as `IYieldLeg[4] public immutable legs` (state var;
  the constructor param is `_legsParams` to avoid shadowing). `legsView()`
  returns `address[4]`; `legAt(uint256 i)` for indexed access.
- **Regime weights** as `uint16[4]` basis points (sum = 10 000).
- **Timelocked allocation changes**: `requestAllocation` (keeper only) →
  `executePending` (open, after `timelockSeconds` elapse). Default
  timelock is 86 400 s = 24 h. See spec §3.5 for the two-speed framing
  (slow weights loop, fast execution within weights).
- **`cancelPending` is owner-or-keeper only.** Originally open to anyone
  as a keeper-compromise safety net; that turned out to be a griefing
  vector — a bot could cancel every legitimate rebalance on 100–200 ms
  blocks and freeze the keeper's workflow. Recovery for a compromised
  keeper: owner calls `setPaused(true)` then `setKeeper(newKeeper)`.
- **`harvestFromAllLegs`** is keeper-gated and pulls realized yield from
  each leg back into vault cash.

### RegimeDetector (2.7 KB bytecode)

- Reads HyperCore market data through the `IMarketDataFeed` interface
  (the adapter for the Elysium market-data precompile — see spec §2).
- Computes the funding regime in one of four buckets:
  `FUNDING_STRONG` / `FUNDING_WEAK` / `FUNDING_NEG` / `HIGH_VOL`.
- `weightsForRegime(regime)` returns the target allocation per regime
  (basis points summing to 10 000).
- `observe()` is read/write — stores the latest snapshot. No gas spent
  by the aggregator on market data reads until the precompile ships.

### TradeOnlyAgent (2.8 KB bytecode)

- **EIP-712** typed signatures, domain-separated by `chainId`.
- **Delegation struct**: keeper, assetIds (empty = all), maxNotional,
  maxPerOrder, expiresAt, nonce, salt.
- **`expiresAt == 0` means "no expiry"** — the verifier short-circuits
  on the canonical `d.expiresAt == 0` form (kept on one line for audit
  grep). See the verifier check `S3` in `check_repo.py`.
- **Universal revoke**: `revoke(keeper)` marks `(msg.sender, keeper)`
  as revoked. Every venue that calls `isValidDelegation` consults the
  same flag. One revocation call invalidates the keeper on every venue.
- **Venue-local notional tracking**: `recordExecution(venue, delegator,
  ...)` deducts from the delegation's remaining cap, keyed by
  (venue, delegator, keeper, nonce). A single delegation used on N
  venues has an effective ceiling of N × `maxNotional`. This is a
  known limitation of universal revoke — see spec §9.

### The four legs (`src/legs/`)

Each implements `IYieldLeg` (`name`, `expectedApy`, `apyHistory`,
`allocateTo`, `harvest`, `reduceFrom`, `currentValue`) and talks to a
mock-friendly dependency interface. See `docs/ROADMAP.md §5` for the
10 inline `// TODO:` items that need to be closed before mainnet.

| Leg | Underlying | Venue interface |
|---|---|---|
| `KHYPELeg` | kHYPE LST on HyperCore | `IERC20Router` + `IPriceOracle` |
| `SpotStakingLeg` | HYPE staking on HyperEVM | `IStakingPool` |
| `PerpFundingLeg` | Long spot + short perp | `IERC20Router` + `IElysiumCoreWriter` + `IFundingSource` |
| `BasisHedgeLeg` | HR=1.0 delta-neutral | Same as `PerpFundingLeg` |

## Contract sizes vs Elysium limits

| Contract | Creation B | Deployed B | Purpose |
|---|---:|---:|---|
| YieldAggregator | 12 151 | 10 979 | Vault + keeper + timelock |
| TradeOnlyAgent | 2 839 | 2 811 | EIP-712 delegation |
| RegimeDetector | 2 926 | 2 650 | Market-data adapter |
| KHYPELeg | 7 495 | 6 918 | kHYPE LST leg |
| SpotStakingLeg | 7 503 | 6 926 | Spot-staking leg |
| PerpFundingLeg | 7 775 | 7 140 | Perp-funding leg |
| BasisHedgeLeg | 7 576 | 6 988 | Basis-hedge leg |

Total: **~46.5 KB** across all contracts (including the `SafeERC20`
library and `RegimeId` enum). Per-contract, the largest is
`YieldAggregator` at 12.4 KB creation — well under the 24 KB EVM
contract-size cap. The "300 Mgas/s execution budget" figure in the
Elysium docs is a throughput claim, not a size limit, so it is not
the right comparison here.

Deployment gas on Elysium (HYPE 1:1 from HyperEVM) is estimated at
< 1.5 HYPE for the full 7-contract stack.

## What's not in this repo

- **Audit** — none. Production deployment requires a full audit.
- **Market-data precompile address** — `IMarketDataFeed` is a placeholder.
  The actual Elysium precompile address and ABI ship ~4 weeks
  post-mainnet (see `docs/AGGREGATOR_SPEC.md` §2).
- **ElysiumCoreWriter predeploy address** — `IElysiumCoreWriter` is a
  stub; the actual predeploy ships ~4 weeks post-mainnet.
- **Live oracles** — `IPriceOracle` and `IFundingSource` are stubs.
  Legs currently use `fixedApyBps` config fallbacks; wiring live
  sources is tracked in `docs/ROADMAP.md §5`.
- **Elysium mainnet chain ID** — published by Kinetiq at mainnet
  launch; the testnet chain ID is also TBA. `deploy.py` uses an
  internal placeholder as a dry-run default only and refuses
  deploys to any other ID without `--yes-i-mean-it` + explicit
  `--chain-id`. ChainId 999 (HyperEVM mainnet) is refused outright.

## Roadmap

1. This repo: aggregator + delegation standard + 4 legs + compile/verify/deploy scripts ✅
2. Add Foundry tests for the aggregator deposit/withdraw/timelock flow
3. Add Foundry tests for TradeOnlyAgent EIP-712 sign+verify
4. Wire live oracles (`IPriceOracle`, `IFundingSource`) into the legs
5. Market-data precompile adapter (replaces `IMarketDataFeed` placeholder)
6. Deploy to Elysium testnet (chain ID per official Kinetiq docs)
7. Deploy to Elysium mainnet (after Kinetiq approves builders allocation)

## Related artifacts

- `hypeback/` — Python backtester that validates strategy choices before
  deployment. Kill gate: net APY > 4%, max DD < 15%, no liquidation.
- `docs/AGGREGATOR_SPEC.md` — full architectural rationale.
- `docs/DELEGATION_SPEC.md` — full delegation protocol design.
- `docs/ROADMAP.md` — what's built vs deferred, milestones, in-code TODOs.
- `check_repo.py` (repo root) — independent verifier: docs inventory,
  fresh compile, ERC-4626 surface, expiresAt short-circuit, README
  stats drift.
