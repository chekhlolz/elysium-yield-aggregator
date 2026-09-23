# hypeback

**HYPE delta-neutral vault backtester + Yield Aggregator simulator** — a dev
tool for strategy research on HyperCore funding + kHYPE staking yield, and
the reference implementation for the Elysium builder workstream (Kinetiq).

Two things live here:

1. **The backtester** (`hypeback/`) — simulates delta-hedged HYPE vaults over
   real HyperCore funding history (Dec 2024 → Sep 2026, 15,750 hourly records)
   with a lognormal HYPE price path. Includes a kill-gate pre-commit check.
2. **The aggregator reference** (`solidity/`) — a Solidity skeleton for the
   ERC-4626 YieldAggregator that would live on Elysium, plus an on-chain
   simulator (`hypeback/aggregator.py`) that validates the alpha claim.

This is a research artifact, not an audited production system.

---

## Install

Python 3.10+, no third-party deps for the backtester (stdlib only). Data is
bundled.

```bash
cd hypeback
python -m hypeback sanity    # 0.02s — invariant checks
```

For the Solidity toolchain (compile + verify + deploy), also install:

```bash
pip install py-solc-x web3 eth-abi eth-utils
```

## Usage

### CLI

```bash
# single deterministic backtest
python -m hypeback run --hr 1.0 --lev 3 --vol 0.70 --staking 0.0189 --seed 42

# monte carlo over 500 price paths
python -m hypeback mc --hr 1.0 --lev 3 --paths 500

# sensitivity grid HR × Lev × rebalance
python -m hypeback sweep --hrs 1.0 1.5 2.0 --levs 2 3 5 --rebals 6 12 24

# kill-gate check (exit 0 = pass, 1 = fail)
python -m hypeback gate --hr 1.0 --lev 3

# regime-driven aggregator simulation — validates the +3-5% alpha claim
python -m hypeback agg                          # single seed
python -m hypeback agg --seeds 30                # aggregate over 30 seeds
python -m hypeback agg --rebal 24 --json         # hourly rebalance, JSON out
python -m hypeback agg --candles data/hype_candles_1h.json  # use real spot candles

# fetch live funding / candles from HyperCore
python -m hypeback fetch --coin HYPE --hours 8760
python -m hypeback fetch --coin HYPE --candles --candles-out data/candles.json

# local web UI with charts
python -m hypeback serve --port 8760
# → http://127.0.0.1:8760
```

### Parameters (engine)

| flag | default | meaning |
|---|---|---|
| `--hr` | 1.5 | hedge ratio (perp notional / spot value) |
| `--lev` | 3.0 | perp leverage |
| `--vol` | 0.70 | HYPE annualized volatility |
| `--staking` | 0.0189 | staking APY (kHYPE base) |
| `--capital` | 100000 | initial capital USD |
| `--rebal` | 12 | rebalance interval, hours |
| `--seed` | 42 | price-path seed |
| `--window` | all | restrict funding history to last N hours |

### Kill gate

`net APY > 4% annualized AND max DD < 15% AND no liquidation`. This is the
pre-commit gate for the aggregator product: anything that fails the gate is
not deployable, regardless of APY.

### Aggregator simulation

`python -m hypeback agg` runs the regime-driven aggregator against a static
benchmark. The output includes:

- **Alpha** = aggregator net APY − static net APY.
- **Regime breakdown** (hours in FUNDING_STRONG / WEAK / NEG / HIGH_VOL).
- **Rebalance count** and fees paid.

**Current empirical finding (2026-09-22, 15 seeds, 2024-12 → 2026-09)**:
median alpha **+2.10% APY**, aggregator net APY **11.96%** vs static **9.85%**.
Positive but below the +3-5% claim in `docs/AGGREGATOR_SPEC.md`. See
`docs/ROADMAP.md §2.2` for what would close the gap.

## Data

- `data/hype_funding_full.json` — 15,750 hourly funding-rate records,
  `2024-12-05 → 2026-09-22 UTC`, fetched from HyperCore's `/info` endpoint.
  To refetch: `python -m hypeback fetch --coin HYPE --hours 17520`.

## Solidity

Contracts live in `solidity/src/`. Compile + verify + dry-run deploy:

```bash
cd solidity
python scripts/compile.py                    # build all contracts
python scripts/verify.py                     # ABI + EIP-712 + events
python scripts/deploy.py --dry-run \
  --leg-addr 0x1111111111111111111111111111111111111111 \
  --leg-addr 0x2222222222222222222222222222222222222222 \
  --leg-addr 0x3333333333333333333333333333333333333333 \
  --leg-addr 0x4444444444444444444444444444444444444444
```

Real deploy:

```bash
export RPC_URL=<Elysium testnet RPC>  # published by Kinetiq at launch
export DEPLOYER_PK=0x...
python scripts/deploy.py --leg-addr <leg1> --leg-addr <leg2> \
  --leg-addr <leg3> --leg-addr <leg4>
```

Real deploy refuses any chain ID other than the internal dry-run
placeholder (see `ELYSIUM_TESTNET_CHAIN_ID` in
`solidity/scripts/deploy.py`, used only for local `MockProvider` tests)
without `--yes-i-mean-it` AND an explicit `--chain-id`. It also
explicitly refuses chainId 999, which is **HyperEVM's** mainnet ID,
not Elysium's — Elysium's own mainnet and testnet chain IDs are **TBA**
and will be published by Kinetiq at launch. The placeholder exists so
the deploy script has something to dry-run against before the real
IDs land. Manifests land at `solidity/output/deployments/`.

Contracts (21 total, 0 errors, 2 warnings). The four `IYieldLeg` impl
contracts (KHYPELeg, SpotStakingLeg, PerpFundingLeg, BasisHedgeLeg)
landed this week — see `docs/ROADMAP.md §2.1`:

| File | Bytes | ABI entries |
|---|---|---|
| `src/aggregator/YieldAggregator.sol` | 11,055 | 46 |
| `src/delegation/TradeOnlyAgent.sol` | 3,103 | 8 |
| `src/keeper/RegimeDetector.sol` | 2,884 | 13 |
| `src/legs/KHYPELeg.sol` | 7,743 | 28 |
| `src/legs/SpotStakingLeg.sol` | 7,767 | 29 |
| `src/legs/PerpFundingLeg.sol` | 9,961 | 34 |
| `src/legs/BasisHedgeLeg.sol` | 9,821 | 35 |
| `src/interfaces/IYieldAggregator.sol` | 0 | 27 |
| `src/interfaces/ITradeOnlyAgent.sol` | 0 | 5 |
| `src/interfaces/IYieldLeg.sol` | 0 | 10 |
| `src/interfaces/IERC20.sol` | 0 | 5 |
| `src/interfaces/IERC20Router.sol` | 0 | 3 |
| `src/interfaces/IElysiumCoreWriter.sol` | 0 | 2 |
| `src/interfaces/IFundingSource.sol` | 0 | 2 |
| `src/interfaces/IPriceOracle.sol` | 0 | 2 |
| `src/interfaces/IStakingPool.sol` | 0 | 9 |

Total: 48,578 bytes across all contracts (including the `SafeERC20`
library, `RegimeId` enum, and the minimal `IERC20Minimal` facade).

The four `IYieldLeg` implementations are the actual yield venues the
aggregator routes capital through: `KHYPELeg` wraps the kHYPE
liquid-staking token on HyperCore (yield accrues via the pool's
exchange rate), `SpotStakingLeg` wraps direct HYPE staking on HyperEVM
with a 24h unbonding hint, `PerpFundingLeg` runs a long-spot / short-
perp book on HyperCore HYPE-USD perp to capture the funding rate (flipped
to the short side), and `BasisHedgeLeg` runs the same long-spot /
short-perp shape at HR = 1.0 but targets basis carry instead of funding.
All four route through mock-friendly dependency interfaces
(`IERC20Router`, `IStakingPool`, `IElysiumCoreWriter`, `IPriceOracle`,
`IFundingSource`), so a test rig can inject stub venues without touching
HyperCore directly. Pre-production TODOs (router address, live oracle
wiring, `HYPE_ASSET_ID` confirmation, per-intent EIP-712 signatures,
mark-to-market oracle for BasisHedgeLeg unrealised PnL) live as inline
`// TODO:` comments and are catalogued in `docs/ROADMAP.md §5`.

## Docs

- `docs/AGGREGATOR_SPEC.md` — Yield Aggregator architectural spec.
- `docs/DELEGATION_SPEC.md` — Trade-Only-Agent delegation protocol.
- `docs/KINETIQ_EMAIL_DRAFT.md` — draft message to the Kinetiq builders channel.
- `docs/ROADMAP.md` — what's built vs deferred, milestones, what's not-doing.

## License

MIT. Not investment advice. Numbers are simulation outputs from a synthetic
lognormal price path — real vaults will diverge.

## Workstream context

- Elysium is an Arbitrum Orbit L2 by [Kinetiq](https://kinetiq.xyz), settling
  to HyperEVM. Mainnet pre-launch as of Sep 2026.
- HyperCore market-data read precompile + ElysiumCoreWriter predeploy ship
  ~4 weeks post-mainnet.
- This backtester is the pre-deployment gate: no aggregator goes live on
  Elysium without first clearing the kill gate here.
