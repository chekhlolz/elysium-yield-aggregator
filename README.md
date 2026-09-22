# hypeback

**HYPE delta-neutral vault backtester** — a developer tool for strategy research on HyperCore funding + kHYPE staking yield.

Built as the warm-up artifact for the [Elysium](https://elysium.kinetiq.xyz) builder workstream (Kinetiq ecosystem). The on-chain aggregator product (idea 1 of the roadmap) is the next vertical; this repo is the dev tool that validates strategy choices before any capital is deployed.

---

## What it does

Simulates a delta-hedged HYPE vault over real HyperCore funding history (Dec 2024 → Sep 2026, 15,750 hourly records) with a lognormal HYPE price path:

- **Long spot** (HYPE, optionally kHYPE with staking yield)
- **Short perp** (HyperCore HYPE-USDC), sized at hedge ratio HR = perp_notional / spot_value
- **Position accounting (v4, sanity-verified)**:
  ```
  equity = spot_value + cash_all + funding_pnl - fee_paid - perp_pnl
  ```
  where `cash_all = free_cash + perp_margin` and `perp_pnl = perp_notional - init_perp_notional`. Margin stays fixed between rebalances; it is collateral, not a position.
- **Rebalance** on hedge-ratio drift with maker/taker slippage + priority fee
- **Maintenance margin** and liquidation checks against the HyperCore tier-1 rate (0.5% of notional)

Sanity checks (in `python -m hypeback sanity`) verify:
- HR=1.0 is truly delta-neutral (equity invariant to a ±5% price move)
- HR=1.5 has net short delta of −33.3% of capital, as expected

## Install

Python 3.10+, no third-party deps (stdlib only). Data is bundled.

```bash
cd hypeback
python -m hypeback sanity     # 0.02s — invariant checks
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

# local web UI with charts
python -m hypeback serve --port 8760
# → http://127.0.0.1:8760
```

### Parameters

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

`net APY > 4% annualized AND max DD < 15% AND no liquidation`. This is the pre-commit gate for the aggregator product: anything that fails the gate is not deployable, regardless of APY.

## Data

- `data/hype_funding_full.json` — 15,750 hourly funding-rate records, `2024-12-05 → 2026-09-22 UTC`, fetched from the HyperCore `/info` endpoint.

To refetch: see `elysium_research/fetch_candles.py` (workstream repo, not part of this artifact).

## Roadmap

1. ~~Backtest engine + CLI + web UI~~ — this repo
2. **Yield Aggregator Router** — production product, dynamic allocation across 4 yield sources (HYPE staking, kHYPE, perp funding, basis). See `docs/AGGREGATOR_SPEC.md` for the architectural spec.
3. **Trade-Only-Agent Delegation Protocol** — on-chain standard for scoped trade delegation, the primitive ElysiumCoreWriter will sit on top of.

## License

MIT. Not investment advice. Numbers are simulation outputs from a synthetic lognormal price path — real vaults will diverge.

## Workstream context

- Elysium is an Arbitrum Orbit L2 by [Kinetiq](https://kinetiq.xyz), settling to HyperEVM. Mainnet pre-launch as of Sep 2026.
- HyperCore market-data read precompile + ElysiumCoreWriter predeploy ship ~4 weeks post-mainnet.
- This backtester is the pre-deployment gate: no aggregator goes live on Elysium without first clearing the kill gate here.
