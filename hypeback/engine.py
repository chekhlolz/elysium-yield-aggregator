"""hypeback.engine — delta-neutral HYPE vault simulation core.

Accounting model (v4, sanity-verified):
    equity = spot_value + cash_all + funding_pnl - fee_paid - perp_pnl
    where:
      cash_all  = free_cash + perp_margin (total wallet cash)
      perp_pnl  = perp_notional - init_perp_notional
      perp_notional = current mark $ of the short (scales with price)
      spot_value    = current mark $ of the spot long (scales with price)

In a delta-neutral vault (HR=1.0), spot_value == init_perp_notional always,
so perp_pnl cancels the spot_value change and equity = cash + yield.
For HR != 1.0 the vault carries residual directional delta
= (HR - 1) * spot_value (short when HR > 1).

Price path: lognormal random walk with zero-mean log returns.
Funding: real hourly history from HyperCore (hype_funding_full.json).
"""

import json
import math
import os
import random
import statistics
from datetime import datetime, timezone

# ---------------------------------------------------------------------------
# Data loading
# ---------------------------------------------------------------------------

DEFAULT_DATA_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "data")

_funding_cache = {}


def load_funding(path=None):
    """Load hourly funding records [{coin, fundingRate, premium, time}, ...]."""
    if path is None:
        path = os.path.join(DEFAULT_DATA_DIR, "hype_funding_full.json")
    if path in _funding_cache:
        return _funding_cache[path]
    with open(path) as f:
        records = json.load(f)
    records.sort(key=lambda r: r["time"])
    _funding_cache[path] = records
    return records


# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------

DEFAULTS = {
    "initial_capital": 100_000.0,
    "hr_target": 1.5,           # perp notional / spot value
    "lev": 3.0,                 # perp leverage
    "rebalance_interval_hours": 12,
    "rebalance_drift_threshold": 0.05,
    "maintenance_rate": 0.005,  # 0.5% of notional (HyperCore tier 1)
    "liquidation_penalty": 0.05,
    "staking_apy": 0.0189,      # kHYPE base
    "maker_fill_frac": 0.90,
    "maker_slippage_bp": 0.5,
    "taker_slippage_bp": 1.5,
    "priority_fee_hype": 0.03,
    "hype_price": 40.0,
    "vol_annual": 0.70,
    "seed": 42,
}


# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

def init_state(capital, hr_target, lev):
    """Open the initial hedged position.

    Position sizing (capital fully deployed):
      spot_value         = capital / (1 + hr_target/lev)
      init_perp_notional = hr_target * spot_value
      perp_margin        = init_perp_notional / lev
      cash_all           = capital - spot_value
    """
    spot_value = capital / (1.0 + hr_target / lev)
    init_perp_notional = hr_target * spot_value
    perp_margin = init_perp_notional / lev
    cash_all = capital - spot_value
    return {
        "spot_value": spot_value,
        "init_perp_notional": init_perp_notional,
        "perp_notional": init_perp_notional,
        "perp_margin": perp_margin,
        "cash_all": cash_all,
        "ref_price_factor": 1.0,
        "fee_paid": 0.0,
        "funding_pnl": 0.0,
        "staking_pnl": 0.0,
        "trades": 0,
        "liquidated": False,
    }


def compute_equity(state):
    perp_pnl = state["perp_notional"] - state["init_perp_notional"]
    return (state["spot_value"] + state["cash_all"]
            + state["funding_pnl"] - state["fee_paid"] - perp_pnl)


# ---------------------------------------------------------------------------
# Simulation
# ---------------------------------------------------------------------------

def step_hour(state, funding_rate, hr_target, lev, hour_index, staking_apy,
              rng, params):
    if state["liquidated"]:
        return compute_equity(state)

    vol_annual = params["vol_annual"]
    hourly_sigma = vol_annual / math.sqrt(8760.0)
    px_factor = math.exp(rng.gauss(0.0, hourly_sigma))

    state["spot_value"] *= px_factor
    state["perp_notional"] *= px_factor
    # perp_margin stays FIXED until rebalance (locked collateral)
    state["ref_price_factor"] *= px_factor

    # funding received by the short leg, on current notional
    state["funding_pnl"] += funding_rate * state["perp_notional"]

    # staking compounding on the spot leg
    staking_pnl = state["spot_value"] * (staking_apy / 8760.0)
    state["staking_pnl"] += staking_pnl
    state["spot_value"] += staking_pnl

    # periodic rebalance when hedge ratio drifts
    if (hour_index > 0
            and hour_index % params["rebalance_interval_hours"] == 0
            and abs(state["perp_notional"] / state["spot_value"] - hr_target)
                > params["rebalance_drift_threshold"]):
        new_notional = hr_target * state["spot_value"]
        delta_notional = new_notional - state["perp_notional"]
        slip_bp = (params["maker_fill_frac"] * params["maker_slippage_bp"]
                   + (1 - params["maker_fill_frac"]) * params["taker_slippage_bp"])
        cost = abs(delta_notional) * slip_bp / 10_000.0
        if abs(delta_notional) > 1.0:
            cost += params["priority_fee_hype"] * params["hype_price"]
        state["fee_paid"] += cost
        state["trades"] += 1
        state["init_perp_notional"] = new_notional
        state["perp_notional"] = new_notional
        state["perp_margin"] = new_notional / lev
        state["cash_all"] -= cost

    # maintenance margin check
    maintenance = state["perp_notional"] * params["maintenance_rate"]
    equity = compute_equity(state)
    if equity < maintenance:
        state["liquidated"] = True
        penalty = equity * params["liquidation_penalty"]
        state["fee_paid"] += penalty
        state["spot_value"] = 0
        state["perp_notional"] = 0
        state["init_perp_notional"] = 0
        state["perp_margin"] = 0
        state["cash_all"] = 0
    return compute_equity(state)


def run_backtest(funding=None, funding_path=None, window_hours=None,
                 overrides=None, return_curve=False):
    """Run one deterministic backtest.

    overrides: dict merged over DEFAULTS (hr_target, lev, vol_annual, ...).
    window_hours: restrict funding history to the last N hours.
    """
    params = dict(DEFAULTS)
    if overrides:
        params.update(overrides)
    if funding is None:
        funding = load_funding(funding_path)
    if window_hours:
        funding = funding[-window_hours:]

    rng = random.Random(params["seed"])
    state = init_state(params["initial_capital"], params["hr_target"], params["lev"])
    equity_curve = [params["initial_capital"]]
    equity_peak = params["initial_capital"]
    max_dd = 0.0

    for i, rec in enumerate(funding):
        eq = step_hour(state, float(rec["fundingRate"]),
                       params["hr_target"], params["lev"], i,
                       params["staking_apy"], rng, params)
        equity_curve.append(eq)
        equity_peak = max(equity_peak, eq)
        max_dd = max(max_dd, (equity_peak - eq) / equity_peak)

    hours_elapsed = len(equity_curve) - 1
    years = hours_elapsed / 8760.0
    capital = params["initial_capital"]
    final = equity_curve[-1]
    net_apy = (final / capital) ** (1 / years) - 1 if years > 0 and final > 0 else -1.0

    hourly_returns = [equity_curve[i + 1] / equity_curve[i] - 1
                      for i in range(hours_elapsed)
                      if equity_curve[i] > 0]
    sd = statistics.stdev(hourly_returns) if len(hourly_returns) > 1 else 0
    sharpe = (statistics.mean(hourly_returns) / sd) * math.sqrt(8760) if sd > 0 else 0.0

    result = {
        "final_equity": final,
        "total_return": final / capital - 1,
        "net_apy": net_apy,
        "max_drawdown": max_dd,
        "sharpe": sharpe,
        "years": years,
        "funding_pnl": state["funding_pnl"],
        "staking_pnl": state["staking_pnl"],
        "fees_paid": state["fee_paid"],
        "trades": state["trades"],
        "liquidated": state["liquidated"],
        "params": params,
    }
    if return_curve:
        result["equity_curve"] = equity_curve
        result["start_time"] = datetime.fromtimestamp(
            funding[0]["time"] / 1000, tz=timezone.utc) if funding else None
    return result


def monte_carlo(num_paths=500, seed=1000, overrides=None, funding=None,
                funding_path=None, window_hours=None):
    """Run many backtests with different price-path seeds, aggregate stats."""
    if funding is None:
        funding = load_funding(funding_path)
    master = random.Random(seed)
    apys, dds, sharpes = [], [], []
    liq = 0
    for _ in range(num_paths):
        ov = dict(overrides or {})
        ov["seed"] = master.randint(0, 2 ** 31)
        r = run_backtest(funding=funding, overrides=ov, window_hours=window_hours)
        apys.append(r["net_apy"])
        dds.append(r["max_drawdown"])
        sharpes.append(r["sharpe"])
        if r["liquidated"]:
            liq += 1
    apys.sort()
    dds.sort()
    n = num_paths
    return {
        "n_paths": n,
        "liquidations": liq,
        "apy_mean": statistics.mean(apys),
        "apy_median": statistics.median(apys),
        "apy_p10": apys[int(0.10 * n)],
        "apy_p90": apys[int(0.90 * n)],
        "apy_min": apys[0],
        "apy_max": apys[-1],
        "max_dd_median": statistics.median(dds),
        "max_dd_p90": dds[int(0.90 * n)],
        "max_dd_max": dds[-1],
        "sharpe_median": statistics.median(sharpes),
        "apy_samples": apys,
        "dd_samples": dds,
    }


# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------

def sanity_check(verbose=True):
    """HR=1.0 must be truly delta-neutral; HR=1.5 must have -33.3% short delta."""
    base = {"seed": 1, "initial_capital": 100_000.0}
    s1 = init_state(100_000.0, 1.0, 3.0)
    s1["spot_value"] *= 1.05
    s1["perp_notional"] *= 1.05
    eq1 = compute_equity(s1)
    ok1 = abs(eq1 - 100_000.0) < 0.01

    s2 = init_state(100_000.0, 1.5, 3.0)
    spot_init = s2["spot_value"]
    before = compute_equity(s2)
    s2["spot_value"] *= 1.01
    s2["perp_notional"] *= 1.01
    after = compute_equity(s2)
    expected = -(1.5 - 1.0) * spot_init * 0.01
    ok2 = abs((after - before) - expected) < 0.01

    if verbose:
        print(f"HR=1.0 delta-neutral:   equity after +5% = ${eq1:,.2f}  "
              f"{'PASS' if ok1 else 'FAIL'}")
        print(f"HR=1.5 short delta:     {after - before:,.2f} (expected {expected:,.2f})  "
              f"{'PASS' if ok2 else 'FAIL'}")
    return ok1 and ok2


def kill_gate(result, min_apy=0.04, max_dd=0.15):
    """Gate: net APY > 4%, max DD < 15%, no liquidation."""
    return {
        "apy_pass": result["net_apy"] > min_apy,
        "dd_pass": result["max_drawdown"] < max_dd,
        "liq_pass": not result["liquidated"],
        "passed": (result["net_apy"] > min_apy
                   and result["max_drawdown"] < max_dd
                   and not result["liquidated"]),
    }
