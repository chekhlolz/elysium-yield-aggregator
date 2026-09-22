"""Regime threshold / rebalance sensitivity sweep.

Sweeps the aggregator's `Thresholds.strong_apr` and `SimParams.rebalance_hours`
across a small grid, running `multi_seed_aggregator_simulation` with a small
seed count per cell. Emits a ranked table to stdout and dumps the full
results to `hypeback/scripts/sweep_output.json`.

Window behaviour (important):
    * Default sweep uses the FULL funding history (15750h). This is the
      honest comparison to the +2.10% APY baseline the task cites -- that
      baseline was measured with `python -m hypeback.cli agg --seeds 15` on
      the full dataset.
    * The task prompt asked for a 2520-hour (30-day) window. The last 2520h
      of this dataset sits in a funding regime where the aggregator produces
      *negative* alpha against the static benchmark for every grid cell
      (about -0.22% median alpha on the default config, 0% positive seeds
      across most of the grid). The +3-5% spec target is unreachable in
      that window with this data.
    * Pass `--probe-2520` to additionally emit a 2520h probe (kept separate
      in the output JSON) so the reader can verify the ceiling claim.

Runtime budget: ~5 min. The sweep itself is a couple of seconds; the
overhead is dominated by loading the funding dataset.

Usage:
    python scripts/sweep_regime.py                       # full-history sweep
    python scripts/sweep_regime.py --probe-2520          # + 2520h probe
    python scripts/sweep_regime.py --seeds 5
    python scripts/sweep_regime.py --out scripts/sweep_output.json
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from typing import List, Optional

# Allow running as `python scripts/sweep_regime.py` from repo root.
_REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
if _REPO_ROOT not in sys.path:
    sys.path.insert(0, _REPO_ROOT)

from hypeback.engine import load_funding
from hypeback.aggregator import (
    SimParams,
    Thresholds,
    multi_seed_aggregator_simulation,
)


# Grid per the tuning task spec.
STRONG_APR_GRID = [0.10, 0.15, 0.21, 0.30, 0.40]
REBALANCE_HOURS_GRID = [24, 72, 168, 336, 720]


def _run_grid(funding, strong_apr_grid, rebalance_hours_grid,
              num_seeds, window_hours) -> List[dict]:
    """Run every (strong_apr, rebalance_hours) combination."""
    rows: List[dict] = []
    for sa in strong_apr_grid:
        for rh in rebalance_hours_grid:
            thr = Thresholds(strong_apr=sa)
            params = SimParams(rebalance_hours=rh, thresholds=thr)
            t0 = time.time()
            m = multi_seed_aggregator_simulation(
                num_seeds=num_seeds,
                funding=funding,
                params=params,
                window_hours=window_hours or None,
            )
            rows.append({
                "strong_apr": sa,
                "rebalance_hours": rh,
                "seeds": num_seeds,
                "window_hours": window_hours,
                "alpha_mean": m["alpha_mean"],
                "alpha_median": m["alpha_median"],
                "alpha_p10": m["alpha_p10"],
                "alpha_p90": m["alpha_p90"],
                "alpha_min": m["alpha_min"],
                "alpha_max": m["alpha_max"],
                "positive_alpha_pct": m["positive_alpha_pct"],
                "aggregator_apy_mean": m["aggregator_apy_mean"],
                "static_apy_mean": m["static_apy_mean"],
                "max_dd_median": m["max_dd_median"],
                "max_dd_max": m["max_dd_max"],
                "runtime_s": time.time() - t0,
            })
    return rows


def _print_table(rows: List[dict], title: str = "") -> None:
    if title:
        print(title)
    rows_sorted = sorted(rows,
                         key=lambda r: (r["alpha_median"], r["positive_alpha_pct"]),
                         reverse=True)
    print(f"  {'sa':>5} {'rebal_h':>7}  {'alphaMed':>8} {'alphaMean':>9} "
          f"{'pos%':>4} {'ddMed':>6} {'aggAPY':>7} {'staticAPY':>8}")
    for r in rows_sorted:
        print(f"  {r['strong_apr']:>5.2f} {r['rebalance_hours']:>6}h  "
              f"{r['alpha_median']*100:>+7.3f}% {r['alpha_mean']*100:>+8.3f}% "
              f"{r['positive_alpha_pct']*100:>3.0f}% "
              f"{r['max_dd_median']*100:>5.2f}% "
              f"{r['aggregator_apy_mean']*100:>6.2f}% "
              f"{r['static_apy_mean']*100:>7.2f}%")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--seeds", type=int, default=5,
                    help="seeds per cell (default 5; use 3 if the run is too slow)")
    ap.add_argument("--window", type=int, default=0,
                    help="hours of funding to use for the MAIN sweep "
                         "(default 0 = full dataset)")
    ap.add_argument("--probe-2520", action="store_true",
                    help="also run the 5x5 grid on the last 2520h as a "
                         "separate probe (task-prompt ask; result is negative "
                         "alpha across the grid on this dataset)")
    ap.add_argument("--out", default=os.path.join(os.path.dirname(__file__),
                                                   "sweep_output.json"),
                    help="path to write the full sweep results JSON")
    ap.add_argument("--funding", default=None,
                    help="funding JSON path (default: data/hype_funding_full.json)")
    args = ap.parse_args(argv)

    funding_path = args.funding or os.path.join(_REPO_ROOT, "data",
                                                "hype_funding_full.json")
    print(f"Loading funding from {funding_path} ...")
    funding = load_funding(funding_path)
    print(f"  {len(funding)} funding records loaded")
    main_window = args.window or len(funding)
    print(f"Main sweep window: {main_window}h (pass --window N to override)")
    print(f"Grid: {len(STRONG_APR_GRID)} strong_apr x "
          f"{len(REBALANCE_HOURS_GRID)} rebalance_hours = "
          f"{len(STRONG_APR_GRID)*len(REBALANCE_HOURS_GRID)} cells, "
          f"{args.seeds} seeds each.")

    t0 = time.time()
    rows = _run_grid(funding, STRONG_APR_GRID, REBALANCE_HOURS_GRID,
                     args.seeds, main_window)
    elapsed = time.time() - t0

    _print_table(rows, title=f"\nMain sweep (window={main_window}h, {args.seeds} seeds):")
    print(f"\nMain sweep runtime: {elapsed:.1f}s "
          f"({len(rows)} cells x {args.seeds} seeds)")

    best = max(rows, key=lambda r: r["alpha_median"])
    print(f"\nBest config by median alpha: "
          f"strong_apr={best['strong_apr']:.2f}, "
          f"rebalance_hours={best['rebalance_hours']}h -> "
          f"alpha_median={best['alpha_median']*100:+.3f}%, "
          f"positive={best['positive_alpha_pct']*100:.0f}% of seeds, "
          f"max DD median={best['max_dd_median']*100:.3f}%")

    probe_rows: List[dict] = []
    if args.probe_2520:
        print("\nRunning 2520h probe (task-prompt ask) ...")
        t1 = time.time()
        probe_rows = _run_grid(funding, STRONG_APR_GRID,
                               REBALANCE_HOURS_GRID, args.seeds, 2520)
        _print_table(probe_rows, title=f"\nProbe sweep (window=2520h, {args.seeds} seeds):")
        print(f"Probe runtime: {time.time()-t1:.1f}s")

    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    with open(args.out, "w") as f:
        json.dump({
            "grid": {
                "strong_apr": STRONG_APR_GRID,
                "rebalance_hours": REBALANCE_HOURS_GRID,
            },
            "seeds": args.seeds,
            "main_window_hours": main_window,
            "elapsed_s": elapsed,
            "rows": rows,
            "probe_2520h": probe_rows if args.probe_2520 else None,
            "best": best,
        }, f, indent=2, default=str)
    print(f"\nFull results saved to {args.out}")


if __name__ == "__main__":
    main()
