"""hypeback.aggregator — regime-driven aggregator simulation.

Purpose:
    Validate the "+3-5% APY alpha vs a static benchmark" claim in
    docs/AGGREGATOR_SPEC.md and docs/KINETIQ_EMAIL_DRAFT.md.

The aggregator holds four legs and rebalances weights across regimes:

    Leg 0 — kHYPE staking           ~1.89% APY  (base rate, stable)
    Leg 1 — xHYPE (Liminal, perp)   ~14.50% APY (commodity, volatile)
    Leg 2 — Perp funding (short)     hourly, regime-dependent
    Leg 3 — Basis hedge              small steady yield, volatility dampener

Regime detector (matches src/keeper/RegimeDetector.sol):
    FUNDING_STRONG   : mean funding > +0.00005/hr (~21% APR short-side)
    FUNDING_WEAK     : mean funding between 0 and +0.00005/hr
    FUNDING_NEG      : mean funding < 0 (shorts pay)
    HIGH_VOL         : rolling stdev of price returns > 3x baseline

Each regime has a target weight vector. The sim rebalances every
`rebalance_hours` and pays realistic slippage + keeper costs.

Compare against a static benchmark that never rebalances. Alpha =
aggregator APY - static APY. If the alpha claim holds, aggregator should
be meaningfully higher in the FUNDING_STRONG regime and no worse in
FUNDING_NEG.
"""

from __future__ import annotations

import json
import math
import random
import statistics
from dataclasses import dataclass, field
from typing import List, Dict, Optional, Tuple

from .engine import (load_funding, DEFAULTS, PricePath,
                     LognormalPricePath, CandlePricePath)


# ---------------------------------------------------------------------------
# Regime detection (mirror of RegimeDetector.sol)
# ---------------------------------------------------------------------------

REGIME_BASE      = 0  # FUNDING_WEAK
REGIME_STRONG    = 1  # FUNDING_STRONG
REGIME_NEGATIVE  = 2  # FUNDING_NEG
REGIME_HIGH_VOL  = 3  # HIGH_VOL (overrides)

REGIME_NAMES = {
    REGIME_BASE:      "FUNDING_WEAK",
    REGIME_STRONG:    "FUNDING_STRONG",
    REGIME_NEGATIVE:  "FUNDING_NEG",
    REGIME_HIGH_VOL:  "HIGH_VOL",
}

# Default threshold config (basis points, in APR-equivalent form).
@dataclass
class Thresholds:
    strong_apr: float = 0.21       # funding APR > 21% -> STRONG
    weak_apr: float = 0.00         # funding APR > 0% -> WEAK
    vol_multiplier: float = 3.0    # stdev > 3x baseline -> HIGH_VOL
    lookback_hours: int = 24       # rolling window for detection


# Target allocation per regime. Each list sums to 10_000 bps.
# Order matches aggregator's leg order: [kHYPE, xHYPE, perp, basis].
REGIME_WEIGHTS_BPS: Dict[int, Tuple[int, int, int, int]] = {
    REGIME_BASE:     (2000, 6000, 1500,  500),  # xHYPE heavy, some perp
    REGIME_STRONG:   (1000, 3000, 5500,  500),  # perp funding dominant
    REGIME_NEGATIVE: (5000, 4000,   0,  1000),  # no perp (would pay funding)
    REGIME_HIGH_VOL: (6000, 2000,   0,  2000),  # de-risk: kHYPE + basis
}


def classify_regime(
    recent_funding_rates: List[float],
    price_returns: List[float],
    baseline_vol: float,
    thr: Thresholds,
) -> int:
    """Pick the current regime from rolling stats."""
    if not price_returns:
        return REGIME_BASE
    vol = statistics.stdev(price_returns) if len(price_returns) > 1 else 0.0
    if baseline_vol > 0 and vol > thr.vol_multiplier * baseline_vol:
        return REGIME_HIGH_VOL

    if not recent_funding_rates:
        return REGIME_BASE
    mean_hourly = statistics.mean(recent_funding_rates)
    apr = mean_hourly * 8760.0
    if apr < thr.weak_apr:
        return REGIME_NEGATIVE
    if apr > thr.strong_apr:
        return REGIME_STRONG
    return REGIME_BASE


def _mean_recent(funding_rates: List[float], hours: int) -> float:
    """Mean of the last `hours` funding rates, scaled to APR."""
    if not funding_rates:
        return 0.0
    window = funding_rates[-hours:]
    return statistics.mean(window)


# ---------------------------------------------------------------------------
# Aggregator state
# ---------------------------------------------------------------------------

@dataclass
class Leg:
    name: str
    base_apy: float                  # annualized, used when no other signal
    value: float = 0.0               # current USD value held
    alloc_bps: int = 0               # current weight in bps

    def hour_yield(self, funding_rate: Optional[float] = None) -> float:
        if self.name == "perp" and funding_rate is not None:
            # For a short perp, funding received = +funding_rate on notional.
            return funding_rate * self.value
        if self.name == "basis":
            # Basis hedge: assume a small positive basis ~0.5% APR.
            return self.value * (0.005 / 8760.0)
        return self.value * self.base_apy / 8760.0


@dataclass
class AggregatorState:
    legs: List[Leg] = field(default_factory=list)
    equity: float = 100_000.0
    fee_paid: float = 0.0
    total_yield: float = 0.0
    trades: int = 0
    regime: int = REGIME_BASE
    regime_history: List[Tuple[int, int]] = field(default_factory=list)  # (hour, regime)


def _init_legs(capital: float, weights_bps: Tuple[int, int, int, int]) -> List[Leg]:
    legs = [
        Leg("kHYPE", base_apy=0.0189),
        Leg("xHYPE", base_apy=0.1450),
        Leg("perp",  base_apy=0.0),
        Leg("basis", base_apy=0.005),
    ]
    for leg, w in zip(legs, weights_bps):
        leg.alloc_bps = w
        leg.value = capital * (w / 10_000.0)
    return legs


def _rebalance(state: AggregatorState, new_weights_bps: Tuple[int, int, int, int],
               fee_bp: float, priority_fee_usd: float) -> None:
    """Apply new weights to legs. Costs slippage + keeper fee per trade.

    Cost accounting: the fee is charged ONCE out of leg values (taken
    from the leg receiving the biggest flow), NOT added to a separate
    cumulative counter. Equity = sum(leg.value), so fees show up as
    reduced leg balances automatically.
    """
    old_bps = tuple(l.alloc_bps for l in state.legs)
    if old_bps == new_weights_bps:
        return

    new_bps = sum(new_weights_bps)
    assert new_bps == 10_000, f"weights don't sum to 10_000 (got {new_bps})"

    total_cost = 0.0
    portions = []
    for leg, new_w, old_w in zip(state.legs, new_weights_bps, old_bps):
        delta = new_w - old_w
        portion = state.equity * (delta / 10_000.0)
        portions.append(portion)
        total_cost += abs(portion) * (fee_bp / 10_000.0) + priority_fee_usd

    # Charge cost from the biggest-inflow leg (or from leg 0 if no inflow).
    inflow_idx = max(range(len(state.legs)), key=lambda i: portions[i])
    if portions[inflow_idx] <= 0:
        inflow_idx = 0
    state.legs[inflow_idx].value -= total_cost

    for leg, new_w, portion in zip(state.legs, new_weights_bps, portions):
        leg.value += portion
        leg.alloc_bps = new_w

    state.equity = sum(l.value for l in state.legs)
    state.fee_paid += total_cost
    state.trades += 1


# ---------------------------------------------------------------------------
# Simulation
# ---------------------------------------------------------------------------

@dataclass
class SimParams:
    initial_capital: float = 100_000.0
    vol_annual: float = 0.70
    staking_apy: float = 0.0189
    xhype_apy: float = 0.1450
    xhype_vol_drag_factor: float = 0.001  # ~100% annual drag at 70% vol — matches xHYPE's 14% APY net
    basis_apy: float = 0.005
    rebalance_hours: int = 168
    rebalance_fee_bp: float = 5.0     # 5 bps slippage per trade
    priority_fee_usd: float = 1.20    # ~0.03 HYPE at $40
    seed: int = 42
    lookback_hours: int = 24
    # Optional override of the Thresholds object used for regime detection.
    # When None the sim builds `Thresholds(lookback_hours=lookback_hours)`
    # with all other fields at their class defaults (backward-compatible).
    thresholds: Optional["Thresholds"] = None


def _load_candles(path: str) -> List[dict]:
    """Load a candle JSON file produced by `python -m hypeback fetch --candles`."""
    with open(path) as f:
        data = json.load(f)
    if isinstance(data, dict):
        # Tolerate {"candles": [...]} wrappers.
        data = data.get("candles", [])
    if not isinstance(data, list):
        raise ValueError(f"candle file {path} must contain a list of candle dicts")
    return data


def run_aggregator_simulation(
    funding_path: Optional[str] = None,
    params: Optional[SimParams] = None,
    funding: Optional[List[dict]] = None,
    return_curve: bool = False,
    window_hours: Optional[int] = None,
    price_path: Optional[PricePath] = None,
    candles: Optional[List[dict]] = None,
) -> Dict:
    """Simulate the aggregator with regime-driven reallocation.

    Returns a dict with final equity, net APY, max DD, alpha vs static,
    regime breakdown, fee total, and (optionally) equity curve.

    Price path sources (highest priority wins):
        price_path : a pre-built PricePath instance (LognormalPricePath,
                     CandlePricePath, or any subclass exposing .returns).
        candles    : a list of spot-candle dicts from HyperCoreClient;
                     wrapped in CandlePricePath automatically.
        (default)  : lognormal random walk driven by SimParams.vol_annual
                     and SimParams.seed.

    When a candle path is supplied, the simulation length is truncated to
    min(len(funding), len(candles)) so the price and funding series stay
    aligned hour-for-hour.
    """
    p = params or SimParams()
    if funding is None:
        funding = load_funding(funding_path)
    if window_hours:
        funding = funding[-window_hours:]

    # Build the price path.
    if price_path is None:
        if candles is not None:
            price_path = CandlePricePath(candles)
        else:
            price_path = LognormalPricePath(
                n_hours=len(funding),
                vol_annual=p.vol_annual,
                seed=p.seed,
            )

    # Align simulation length to the shorter of funding and price path.
    n = min(len(funding), len(price_path))
    if n == 0:
        result = {
            "years": 0.0, "hours": 0,
            "initial_capital": p.initial_capital,
            "aggregator_equity": p.initial_capital,
            "static_equity": p.initial_capital,
            "aggregator_net_apy": 0.0, "static_net_apy": 0.0, "alpha_apy": 0.0,
            "max_drawdown": 0.0, "fees_paid": 0.0, "trades": 0,
            "regime_counts": {}, "regime_switches": 0,
            "total_yield_accrued": 0.0, "static_total_yield": 0.0,
            "price_path_type": type(price_path).__name__,
            "params": p.__dict__,
        }
        return result
    funding = funding[:n]

    # Hourly simple returns. Prefer the path's own returns; if the path is
    # shorter than the funding window we top up with a lognormal walk so
    # the two series stay hour-aligned.
    path_returns = list(price_path.returns)
    if len(path_returns) >= n:
        hourly_returns: List[float] = path_returns[:n]
    else:
        rng = random.Random(p.seed + 1)
        hourly_sigma = p.vol_annual / math.sqrt(8760.0)
        hourly_returns = path_returns + [
            math.exp(rng.gauss(0, hourly_sigma)) - 1.0
            for _ in range(n - len(path_returns))
        ]

    # Static benchmark: same initial weights as the aggregator's default
    # REGIME_BASE allocation, never rebalanced.
    static_weights = REGIME_WEIGHTS_BPS[REGIME_BASE]
    static_state = AggregatorState(
        legs=_init_legs(p.initial_capital, static_weights),
        equity=p.initial_capital,
    )
    aggregator_state = AggregatorState(
        legs=_init_legs(p.initial_capital, static_weights),
        equity=p.initial_capital,
    )

    # Baseline vol: empirical stdev of the first `lookback_hours` returns
    # (falls back to 0.0 if the window is too short).
    window_ret = hourly_returns[:p.lookback_hours]
    baseline_vol = statistics.stdev(window_ret) if len(window_ret) > 1 else 0.0

    equity_curve = [p.initial_capital]
    equity_peak = p.initial_capital
    max_dd = 0.0

    lookback_rates: List[float] = []
    lookback_returns: List[float] = []

    for i in range(n):
        funding_rate = float(funding[i]["fundingRate"])
        px_ret = hourly_returns[i]

        # Yield accrues on each leg independently. Perp funding is signed.
        for state in (aggregator_state, static_state):
            yield_total = 0.0
            for leg in state.legs:
                y = leg.hour_yield(funding_rate)
                yield_total += y
                leg.value += y
            state.total_yield += yield_total
            # Volatility drag: apply a small vol-loss to xHYPE-style
            # levered legs (rough approximation of funding whipsaws).
            xhype_leg = state.legs[1]
            xhype_drag = abs(px_ret) * xhype_leg.value * p.xhype_vol_drag_factor
            xhype_leg.value -= xhype_drag
            state.total_yield -= xhype_drag

        # Recompute equity (fees already deducted from leg values in _rebalance).
        for state in (aggregator_state, static_state):
            state.equity = sum(l.value for l in state.legs)

        # Regime detection (using rolling lookback).
        lookback_rates.append(funding_rate)
        lookback_returns.append(px_ret)
        if len(lookback_rates) > p.lookback_hours:
            lookback_rates.pop(0)
            lookback_returns.pop(0)

        if i > 0 and i % p.rebalance_hours == 0:
            thr = p.thresholds or Thresholds(lookback_hours=p.lookback_hours)
            new_regime = classify_regime(lookback_rates, lookback_returns,
                                         baseline_vol, thr)
            if new_regime != aggregator_state.regime:
                aggregator_state.regime_history.append((i, new_regime))
                aggregator_state.regime = new_regime
                new_w = REGIME_WEIGHTS_BPS[new_regime]
                _rebalance(aggregator_state, new_w,
                           p.rebalance_fee_bp, p.priority_fee_usd)

        equity_curve.append(aggregator_state.equity)
        equity_peak = max(equity_peak, aggregator_state.equity)
        dd = (equity_peak - aggregator_state.equity) / equity_peak
        max_dd = max(max_dd, dd)

    # ---- Static benchmark metrics ----
    static_state.equity = sum(l.value for l in static_state.legs) - static_state.fee_paid
    years = n / 8760.0
    aggregator_apy = ((aggregator_state.equity / p.initial_capital)
                      ** (1 / years) - 1) if years > 0 else 0.0
    static_apy = ((static_state.equity / p.initial_capital)
                  ** (1 / years) - 1) if years > 0 else 0.0
    alpha_apy = aggregator_apy - static_apy

    # Regime tally.
    regime_counts: Dict[int, int] = {}
    for i in range(n):
        if i == 0:
            regime_counts[REGIME_BASE] = regime_counts.get(REGIME_BASE, 0) + 1
            continue
        active = REGIME_BASE
        for hr_idx, reg in aggregator_state.regime_history:
            if hr_idx <= i:
                active = reg
        regime_counts[active] = regime_counts.get(active, 0) + 1

    result = {
        "years": years,
        "hours": n,
        "initial_capital": p.initial_capital,
        "aggregator_equity": aggregator_state.equity,
        "static_equity": static_state.equity,
        "aggregator_net_apy": aggregator_apy,
        "static_net_apy": static_apy,
        "alpha_apy": alpha_apy,
        "max_drawdown": max_dd,
        "fees_paid": aggregator_state.fee_paid,
        "trades": aggregator_state.trades,
        "regime_counts": {REGIME_NAMES[k]: v for k, v in sorted(regime_counts.items())},
        "regime_switches": len(aggregator_state.regime_history),
        "total_yield_accrued": aggregator_state.total_yield,
        "static_total_yield": static_state.total_yield,
        "price_path_type": type(price_path).__name__,
        "params": p.__dict__,
    }
    if return_curve:
        result["equity_curve"] = equity_curve
        result["static_equity_curve"] = [
            static_state.equity  # static state evolves alongside
        ] * len(equity_curve)
    return result


def multi_seed_aggregator_simulation(
    num_seeds: int = 30,
    funding_path: Optional[str] = None,
    funding: Optional[List[dict]] = None,
    params: Optional[SimParams] = None,
    window_hours: Optional[int] = None,
) -> Dict:
    """Aggregate alpha over many seeds to answer: is alpha statistically real?"""
    if funding is None:
        funding = load_funding(funding_path)
    if window_hours:
        funding = funding[-window_hours:]
    alphas: List[float] = []
    aggregator_apys: List[float] = []
    static_apys: List[float] = []
    dds: List[float] = []
    for i in range(num_seeds):
        base = params or SimParams()
        p = SimParams(**{**base.__dict__, "seed": 1000 + i})
        r = run_aggregator_simulation(funding=funding, params=p)
        alphas.append(r["alpha_apy"])
        aggregator_apys.append(r["aggregator_net_apy"])
        static_apys.append(r["static_net_apy"])
        dds.append(r["max_drawdown"])
    alphas.sort()
    n = len(alphas)
    return {
        "n_seeds": n,
        "alpha_mean": statistics.mean(alphas),
        "alpha_median": statistics.median(alphas),
        "alpha_p10": alphas[int(0.10 * n)],
        "alpha_p90": alphas[int(0.90 * n)],
        "alpha_min": alphas[0],
        "alpha_max": alphas[-1],
        "positive_alpha_pct": sum(1 for a in alphas if a > 0) / n,
        "aggregator_apy_mean": statistics.mean(aggregator_apys),
        "static_apy_mean": statistics.mean(static_apys),
        "max_dd_median": statistics.median(dds),
        "max_dd_max": max(dds),
    }
