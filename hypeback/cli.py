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

    p = sub.add_parser("serve", help="local web UI (charts)")
    p.add_argument("--port", type=int, default=8760)
    from .webserver import serve as _serve
    p.set_defaults(func=lambda a: _serve(a.port))

    args = ap.parse_args(argv)
    args.func(args)


if __name__ == "__main__":
    main()
