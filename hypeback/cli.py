"""hypeback — HYPE delta-neutral vault backtester.

A dev tool for strategy research on HyperCore funding + kHYPE staking yield,
part of the Elysium builder workstream (Kinetiq ecosystem).

Commands:
    python -m hypeback run     [--hr 1.0] [--lev 3.0] [--vol 0.7] ...
    python -m hypeback mc      [--paths 500] ...
    python -m hypeback sweep
    python -m hypeback gate
    python -m hypeback serve   [--port 8760]   # local web UI
"""

import argparse
import json
import sys

from . import engine


def _overrides_from_args(args):
    ov = {}
    if args.hr is not None:
        ov["hr_target"] = args.hr
    if args.lev is not None:
        ov["lev"] = args.lev
    if args.vol is not None:
        ov["vol_annual"] = args.vol
    if args.staking is not None:
        ov["staking_apy"] = args.staking
    if args.capital is not None:
        ov["initial_capital"] = args.capital
    if args.rebal is not None:
        ov["rebalance_interval_hours"] = args.rebal
    if args.seed is not None:
        ov["seed"] = args.seed
    return ov


def _print_result(r):
    p = r["params"]
    print(f"Config: HR={p['hr_target']}  Lev={p['lev']}  "
          f"rebal={p['rebalance_interval_hours']}h  vol={p['vol_annual']:.0%}  "
          f"staking={p['staking_apy']:.2%}  seed={p['seed']}")
    print(f"Period: {r['years']:.2f} years")
    print(f"Final equity:         ${r['final_equity']:>12,.2f}")
    print(f"Net APY (compounded): {r['net_apy']*100:>7.2f}%")
    print(f"Max drawdown:         {r['max_drawdown']*100:>7.2f}%")
    print(f"Sharpe (annualized):  {r['sharpe']:>7.2f}")
    print(f"Liquidated:           {r['liquidated']}")
    print(f"  Funding PnL:        ${r['funding_pnl']:>10,.2f}")
    print(f"  Staking PnL:        ${r['staking_pnl']:>10,.2f}")
    print(f"  Fees paid:          ${r['fees_paid']:>10,.2f}  ({r['trades']} rebalances)")


def cmd_run(args):
    r = engine.run_backtest(overrides=_overrides_from_args(args),
                            window_hours=args.window, return_curve=True)
    _print_result(r)
    g = engine.kill_gate(r)
    print(f"Kill gate: APY {'PASS' if g['apy_pass'] else 'FAIL'}  "
          f"DD {'PASS' if g['dd_pass'] else 'FAIL'}  "
          f"LIQ {'PASS' if g['liq_pass'] else 'FAIL'}  "
          f"-> {'PASS' if g['passed'] else 'FAIL'}")
    if args.json:
        r["start_time"] = str(r.get("start_time"))
        print(json.dumps({k: v for k, v in r.items() if k != "equity_curve"},
                         indent=2, default=str))
    if args.curve_out:
        with open(args.curve_out, "w") as f:
            json.dump(r["equity_curve"], f)
        print(f"Equity curve saved: {args.curve_out} ({len(r['equity_curve'])} points)")


def cmd_mc(args):
    mc = engine.monte_carlo(num_paths=args.paths, seed=args.mc_seed,
                            overrides=_overrides_from_args(args),
                            window_hours=args.window)
    print(f"Monte Carlo: {mc['n_paths']} paths")
    print(f"Liquidations:        {mc['liquidations']}/{mc['n_paths']}")
    print(f"Net APY median:      {mc['apy_median']*100:>7.2f}%")
    print(f"Net APY mean:        {mc['apy_mean']*100:>7.2f}%")
    print(f"Net APY p10 / p90:   {mc['apy_p10']*100:.2f}% / {mc['apy_p90']*100:.2f}%")
    print(f"Net APY min / max:   {mc['apy_min']*100:.2f}% / {mc['apy_max']*100:.2f}%")
    print(f"Max DD median:       {mc['max_dd_median']*100:>7.2f}%")
    print(f"Max DD p90 / worst:  {mc['max_dd_p90']*100:.2f}% / {mc['max_dd_max']*100:.2f}%")
    print(f"Sharpe median:       {mc['sharpe_median']:>7.2f}")
    if args.json:
        print(json.dumps({k: v for k, v in mc.items()
                          if k not in ("apy_samples", "dd_samples")}, indent=2))
    if args.samples_out:
        with open(args.samples_out, "w") as f:
            json.dump({"apy": mc["apy_samples"], "dd": mc["dd_samples"]}, f)
        print(f"Samples saved: {args.samples_out}")


def cmd_sweep(args):
    print(f"{'HR':>4} {'Lev':>5} {'rebal_h':>7}  {'netAPY':>8}  {'maxDD':>7}  "
          f"{'sharpe':>7}  {'fees':>10}  {'liq':>3}  gate")
    for hr in args.hrs:
        for lev in args.levs:
            for rebal in args.rebals:
                r = engine.run_backtest(overrides={
                    "hr_target": hr, "lev": lev,
                    "rebalance_interval_hours": rebal,
                    "seed": args.seed,
                })
                g = engine.kill_gate(r)
                print(f"{hr:>4} {lev:>5} {rebal:>6}h  "
                      f"{r['net_apy']*100:>7.2f}%  "
                      f"{r['max_drawdown']*100:>6.2f}%  "
                      f"{r['sharpe']:>7.2f}  "
                      f"${r['fees_paid']:>9,.0f}  "
                      f"{'Y' if r['liquidated'] else 'n'}  "
                      f"{'PASS' if g['passed'] else 'fail'}")


def cmd_gate(args):
    r = engine.run_backtest(overrides=_overrides_from_args(args))
    g = engine.kill_gate(r)
    _print_result(r)
    verdict = "PASS — proceed" if g["passed"] else "FAIL — do not build"
    print(f"\nKILL GATE: {verdict}")
    sys.exit(0 if g["passed"] else 1)


def cmd_sanity(args):
    ok = engine.sanity_check()
    sys.exit(0 if ok else 1)


def cmd_fetch(args):
    from .hypercore import HyperCoreClient
    import os as _os
    import json as _json
    c = HyperCoreClient(base_url=args.base_url) if args.base_url else HyperCoreClient()
    data_dir = _os.path.join(_os.path.dirname(_os.path.dirname(_os.path.abspath(__file__))), "data")
    out_funding = args.out or _os.path.join(data_dir, "hype_funding_full.json")
    recs = c.funding_history(coin=args.coin, hours=args.hours)
    _os.makedirs(_os.path.dirname(out_funding), exist_ok=True)
    with open(out_funding, "w") as f:
        _json.dump(recs, f)
    print(f"Funding: {len(recs)} records -> {out_funding}")
    if args.candles:
        candles_out = args.candles_out or _os.path.join(data_dir, "hype_candles_1h.json")
        candles = c.spot_candles(coin=args.coin, interval="1h", hours=args.hours)
        _os.makedirs(_os.path.dirname(candles_out), exist_ok=True)
        with open(candles_out, "w") as f:
            _json.dump(candles, f)
        print(f"Candles: {len(candles)} records -> {candles_out}")


def cmd_agg(args):
    from .aggregator import (run_aggregator_simulation,
                             multi_seed_aggregator_simulation,
                             SimParams, _load_candles)
    p_kwargs = {}
    if args.rebal is not None:
        p_kwargs["rebalance_hours"] = args.rebal
    if args.vol is not None:
        p_kwargs["vol_annual"] = args.vol
    if args.capital is not None:
        p_kwargs["initial_capital"] = args.capital
    if args.xhype_drag is not None:
        p_kwargs["xhype_vol_drag_factor"] = args.xhype_drag
    p = SimParams(**p_kwargs)

    candles = _load_candles(args.candles) if args.candles else None
    if args.candles and args.seeds != 1:
        print("NOTE: --candles is only honored with --seeds 1; ignoring for multi-seed run.")

    if args.seeds == 1:
        r = run_aggregator_simulation(params=p, window_hours=args.window,
                                      candles=candles)
        print(f"Config: capital=${p.initial_capital:,.0f}  vol={p.vol_annual:.0%}  "
              f"rebal={p.rebalance_hours}h  xHYPE drag={p.xhype_vol_drag_factor:.4f}  "
              f"seed={p.seed}  price_path={r.get('price_path_type', 'lognormal')}")
        print(f"Period: {r['years']:.2f} years ({r['hours']} hours)")
        print(f"Aggregator equity:    ${r['aggregator_equity']:>12,.2f}")
        print(f"Static equity:        ${r['static_equity']:>12,.2f}")
        print(f"Aggregator net APY:   {r['aggregator_net_apy']*100:>7.2f}%")
        print(f"Static net APY:       {r['static_net_apy']*100:>7.2f}%")
        print(f"ALPHA (agg - static): {r['alpha_apy']*100:>+7.2f}%")
        print(f"Max drawdown:         {r['max_drawdown']*100:>7.2f}%")
        print(f"Fees paid:            ${r['fees_paid']:>10,.2f}  ({r['trades']} rebalances)")
        print(f"Regime switches:      {r['regime_switches']}")
        print(f"Regime hours:         {r['regime_counts']}")
        print()
        alpha_pct = r["alpha_apy"] * 100
        if alpha_pct >= 3.0:
            verdict = "PASS — alpha claim holds (≥3%)"
        elif alpha_pct >= 0.0:
            verdict = "WEAK — positive but below 3%"
        else:
            verdict = "FAIL — alpha is negative"
        print(f"ALPHA VERDICT: {verdict}")
        if args.json:
            print(json.dumps(r, indent=2, default=str))
    else:
        m = multi_seed_aggregator_simulation(num_seeds=args.seeds, params=p)
        print(f"Multi-seed aggregation over {m['n_seeds']} seeds")
        print(f"Alpha mean:       {m['alpha_mean']*100:>+7.2f}%")
        print(f"Alpha median:     {m['alpha_median']*100:>+7.2f}%")
        print(f"Alpha p10 / p90:  {m['alpha_p10']*100:>+7.2f}% / {m['alpha_p90']*100:>+7.2f}%")
        print(f"Alpha min / max:  {m['alpha_min']*100:>+7.2f}% / {m['alpha_max']*100:>+7.2f}%")
        print(f"Positive alpha:   {m['positive_alpha_pct']*100:.0f}% of seeds")
        print(f"Aggregator APY:   {m['aggregator_apy_mean']*100:>7.2f}%")
        print(f"Static APY:       {m['static_apy_mean']*100:>7.2f}%")
        print(f"Max DD median:    {m['max_dd_median']*100:>7.2f}%")
        print(f"Max DD worst:     {m['max_dd_max']*100:>7.2f}%")
        mean_alpha_pct = m["alpha_mean"] * 100
        if mean_alpha_pct >= 3.0 and m["positive_alpha_pct"] > 0.9:
            verdict = "PASS — alpha claim holds (≥3% in ≥90% of seeds)"
        elif mean_alpha_pct >= 0.0:
            verdict = "WEAK — positive but below 3%"
        else:
            verdict = "FAIL — alpha is negative on average"
        print(f"ALPHA VERDICT: {verdict}")
        if args.json:
            print(json.dumps(m, indent=2, default=str))


def main(argv=None):
    ap = argparse.ArgumentParser(prog="hypeback",
                                 description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    def add_common(p):
        p.add_argument("--hr", type=float, help="hedge ratio target (perp/spot)")
        p.add_argument("--lev", type=float, help="perp leverage")
        p.add_argument("--vol", type=float, help="HYPE annualized vol, e.g. 0.7")
        p.add_argument("--staking", type=float, help="staking APY, e.g. 0.0189")
        p.add_argument("--capital", type=float, help="initial capital USD")
        p.add_argument("--rebal", type=int, help="rebalance interval, hours")
        p.add_argument("--seed", type=int, help="price path seed")
        p.add_argument("--window", type=int, help="use only last N hours of funding history")

    p = sub.add_parser("run", help="single deterministic backtest")
    add_common(p)
    p.add_argument("--json", action="store_true")
    p.add_argument("--curve-out", help="save equity curve JSON")
    p.set_defaults(func=cmd_run)

    p = sub.add_parser("mc", help="Monte Carlo over price paths")
    add_common(p)
    p.add_argument("--paths", type=int, default=500)
    p.add_argument("--mc-seed", type=int, default=1000)
    p.add_argument("--json", action="store_true")
    p.add_argument("--samples-out", help="save APY/DD samples JSON")
    p.set_defaults(func=cmd_mc)

    p = sub.add_parser("sweep", help="sensitivity grid HR x Lev x rebalance")
    add_common(p)
    p.add_argument("--hrs", type=float, nargs="+", default=[0.5, 1.0, 1.5, 2.0, 3.0])
    p.add_argument("--levs", type=float, nargs="+", default=[1.5, 2.0, 3.0, 5.0])
    p.add_argument("--rebals", type=int, nargs="+", default=[6, 12, 24])
    p.set_defaults(func=cmd_sweep)

    p = sub.add_parser("gate", help="run kill-gate check (exit code 0/1)")
    add_common(p)
    p.set_defaults(func=cmd_gate)

    p = sub.add_parser("sanity", help="verify delta-neutral accounting invariants")
    p.set_defaults(func=cmd_sanity)

    p = sub.add_parser("agg", help="regime-driven aggregator simulation (alpha vs static)")
    p.add_argument("--seeds", type=int, default=1, help="number of seeds to aggregate (1 = single)")
    p.add_argument("--rebal", type=int, default=None, help="rebalance interval hours (default 168)")
    p.add_argument("--vol", type=float, default=None, help="annualized vol, e.g. 0.7")
    p.add_argument("--capital", type=float, default=None, help="initial capital USD")
    p.add_argument("--xhype-drag", type=float, default=None, help="xHYPE vol-drag factor (fraction of |hourly ret|)")
    p.add_argument("--window", type=int, default=None, help="use only last N hours of funding history")
    p.add_argument("--candles", default=None, metavar="PATH",
                   help="load spot candles from a JSON file (produced by `fetch --candles`) "
                        "and use them as the price path")
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_agg)

    p = sub.add_parser("serve", help="local web UI (charts)")
    p.add_argument("--port", type=int, default=8760)
    from .webserver import serve as _serve
    p.set_defaults(func=lambda a: _serve(a.port))

    p = sub.add_parser("fetch", help="fetch live funding/candles from HyperCore")
    p.add_argument("--coin", default="HYPE")
    p.add_argument("--hours", type=int, default=24 * 365 * 2,
                   help="hours of funding history to fetch (default ~2 years)")
    p.add_argument("--out", default=None,
                   help="output path (default: data/hype_funding_full.json)")
    p.add_argument("--candles", action="store_true",
                   help="also fetch spot candles to data/hype_candles_1h.json")
    p.add_argument("--candles-out", default=None)
    p.add_argument("--base-url", default=None, help="override HyperCore API base URL")
    p.set_defaults(func=cmd_fetch)

    args = ap.parse_args(argv)
    args.func(args)


if __name__ == "__main__":
    main()
