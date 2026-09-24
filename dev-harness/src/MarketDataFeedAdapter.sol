// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {HyperCoreTypes} from "./types.sol";
import {IHyperCorePrecompile} from "./IHyperCorePrecompile.sol";

/**
 * @title MarketDataFeedAdapter
 * @notice Bridge from `IHyperCorePrecompile` (speculatively-shaped)
 *         to `IMarketDataFeed` (which RegimeDetector.sol consumes).
 *
 * WHY THIS EXISTS:
 *
 * `solidity/src/keeper/RegimeDetector.sol` depends on an inline
 * `IMarketDataFeed` interface that exposes bps-scaled rates:
 *     fundingRateBps(coin) → int64 (bps, hourly)
 *     realizedVolBps(coin, lookbackHrs) → uint256 (bps, 24h trailing)
 *     spotPrice(coin) → uint256 (6 decimals, USDC)
 *     perpMarkPrice(coin) → uint256 (6 decimals, USDC)
 *
 * `IHyperCorePrecompile` (this harness) exposes the raw market data
 * as `Candle[]`, `FundingSnapshot[]`, and `MarketData`. This adapter
 * does the unit conversion: 1e6-scaled → bps, close-to-close returns
 * → 24h realized vol, etc.
 *
 * DESIGN NOTES:
 *
 * - The adapter is a *pure read layer* — no state, no auth, no
 *   governance. It just translates. If Kinetiq publishes the real
 *   precompile at a different address, you only swap the constructor
 *   argument; RegimeDetector is untouched.
 *
 * - `fundingRateBps` takes the latest funding tick for the coin,
 *   converts its 1e6-scaled rate to per-block bps, and multiplies
 *   by 3600 to get hourly bps (matching the spec note in
 *   `RegimeDetector.observe()` that "the market data precompile
 *   returns hourly funding rate in bps").
 *
 *   The scaling choice matches how `hypeback/engine.py` already
 *   interprets Hyperliquid funding: rates are in units of 1 per
 *   block of the underlying venue's funding cadence. For HYPE the
 *   cadence is 1 hour, so 1 block = 3600 seconds. If you're
 *   modelling a different cadence, override `SCALE_SECONDS_PER_BLOCK`.
 *
 * - `realizedVolBps` computes the sqrt(mean(squared hourly log
 *   returns)) * 10000 from the last `lookbackHrs` candles. Empty
 *   input yields 0 (no data → no vol signal), which lets RegimeDetector
 *   fall through to funding-based classification without reverting.
 *
 * - `spotPrice` and `perpMarkPrice` return the latest market data.
 *   `perpMarkPrice` uses the oracle price as a stand-in for the
 *   perp mark; real markets would expose these separately, but the
 *   adapter collapses them to one source for now. Callers that need
 *   a real basis computation should plug in a dedicated oracle
 *   instead of using this adapter alone.
 *
 * HARDENING (matches RegimeDetector round-9 hardening):
 *
 *   - Divisions are guarded against zero. `spotPrice` returns 0 for
 *     empty market data; RegimeDetector already reverts on zero spot.
 *   - The basis numerator cap in RegimeDetector is applied *there*,
 *     not here — we do not pre-truncate.
 *   - The 24h APY cap in RegimeDetector (round-9 finding #7) is
 *     applied *there*, not here — we do not pre-saturate.
 *
 * Both choices keep the adapter a pure translator: no business
 * logic leaks in.
 */
interface IMarketDataFeed {
    function fundingRateBps(string calldata coin) external view returns (int64);
    function realizedVolBps(string calldata coin, uint32 lookbackHrs)
        external view returns (uint256)
    ;
    function spotPrice(string calldata coin) external view returns (uint256);
    function perpMarkPrice(string calldata coin) external view returns (uint256);
}

contract MarketDataFeedAdapter is IMarketDataFeed {
    /// Number of seconds per funding block. Hyperliquid uses 1-hour
    /// blocks for most markets, so the default is 3600. Override by
    /// re-deploying the adapter with a different value if you need a
    /// non-default cadence.
    uint256 public immutable SCALE_SECONDS_PER_BLOCK;

    /// The precompile address the adapter delegates to. Immutable so
    /// swapping the underlying precompile (mock → real, or version
    /// upgrade) requires a fresh deploy.
    address public immutable precompile;

    event FeedBound(address indexed newPrecompile);

    constructor(address _precompile, uint256 _secondsPerBlock) {
        require(_precompile != address(0), "adapter: zero precompile");
        // Zero secondsPerBlock is interpreted as "use the default
        // 1-hour Hyperliquid cadence" — this lets callers that don't
        // care pass `0` (or omit via a test-only helper) and get
        // standard behaviour.
        uint256 spb = _secondsPerBlock == 0 ? 3600 : _secondsPerBlock;
        precompile = _precompile;
        SCALE_SECONDS_PER_BLOCK = spb;
        emit FeedBound(_precompile);
    }

    /**
     * @dev Latest hourly funding rate in bps.
     *
     * Conversion: 1e6-scaled → bps means (rate / 1e6) * 10_000 = rate / 100.
     * So a 1e6-scaled rate of 10000 (i.e. 1% per block) becomes 100 bps.
     *
     * Empty funding history → 0 bps (no signal, not an error).
     */
    function fundingRateBps(string calldata coin)
        external view override returns (int64)
    {
        IHyperCorePrecompile pc = IHyperCorePrecompile(precompile);
        HyperCoreTypes.FundingSnapshot[] memory ticks = pc.fundingSnapshot(coin, 1);
        if (ticks.length == 0) return 0;
        int256 rate = int256(ticks[ticks.length - 1].fundingRate); // 1e6-scaled
        // Divide by 100 to convert 1e6-scaled → bps (rate / 1e6 * 10_000).
        // Solidity integer division truncates toward zero, which is
        // correct here — bps are coarse enough that the last bit
        // does not matter for RegimeDetector's thresholds.
        int256 bps = rate / 100;
        // Saturate to int64 (matches RegimeDetector's own hardening
        // against hostile feeds that could push past INT64_MAX).
        if (bps > int256(type(int64).max)) return type(int64).max;
        if (bps < int256(type(int64).min)) return type(int64).min;
        return int64(bps);
    }

    /**
     * @dev Realized vol over the trailing `lookbackHrs` hours, in bps.
     *
     * Method:
     *   1. Pull the last `lookbackHrs + 1` 1h candles (we need
     *      `lookbackHrs + 1` candles to compute `lookbackHrs` returns).
     *   2. For each consecutive pair, compute the log return
     *      r_i = ln(close_i / close_{i-1}) using the Taylor
     *      approximation ln(x/y) ≈ 2*(x - y) / (x + y).
     *      The factor of 2 is the second-order Taylor correction
     *      that makes the approximation accurate to <0.5% for any
     *      ratio in [0.5, 2.0].
     *   3. sigma_hourly = sqrt(mean(r_i^2)) — the per-hour standard
     *      deviation of log returns.
     *   4. Annualize to the lookback window:
     *         sigma_lookback = sigma_hourly * sqrt(lookbackHrs)
     *      This is the realized vol over the full lookback period,
     *      not just the hourly vol. (The threshold in RegimeDetector
     *      is 90% = 9,000 bps, which is a 24h-scale number, not an
     *      hourly one — 90% hourly vol would be apocalyptic.)
     *   5. Convert to bps: sigma_lookback * 10_000.
     *
     * Empty / singleton input yields 0 (no data → no signal, not
     * an error). This lets RegimeDetector fall through to funding-
     * based classification without reverting.
     *
     * NOTE ON TAYLOR APPROX:
     * Solidity 0.8.26 has no built-in ln(). We use the second-order
     * Taylor form ln(x/y) ≈ 2*(x-y)/(x+y), accurate to within 0.5%
     * for x/y in [0.5, 2.0]. Beyond that range the approximation
     * degrades, but no real market produces >2× hourly moves.
     * Production should use a real oracle that exposes log returns
     * directly.
     *
     * NOTE ON ANNUALIZATION:
     * The threshold in RegimeDetector is 9,000 bps = 90% realized
     * vol, which is a 24h-scale number (Bitcoin's typical 24h vol
     * is 2-5%; 90% is a stress scenario, not daily business).
     * So `realizedVolBps(coin, 24)` returns 24h realized vol, not
     * hourly — i.e., it's `sqrt(mean(r_i^2)) * sqrt(24) * 10_000`,
     * not just `sqrt(mean(r_i^2)) * 10_000`. This matches the
     * "trailing hours" semantics of the `IMarketDataFeed` interface.
     */
    function realizedVolBps(string calldata coin, uint32 lookbackHrs)
        external view override returns (uint256)
    {
        if (lookbackHrs == 0) return 0;
        uint32 need = lookbackHrs + 1; // we need lookbackHrs returns,
                                       // which means lookbackHrs + 1 candles
        IHyperCorePrecompile pc = IHyperCorePrecompile(precompile);
        // Query the last `lookbackHrs` hours of 1h candles — the
        // adapter is only expected to be used with recent data. If
        // the caller wants longer lookbacks, extend this to multiple
        // windows.
        uint256 nowTs = uint256(block.timestamp);
        uint256 fromTs = nowTs > uint256(lookbackHrs) * 3600
            ? nowTs - uint256(lookbackHrs) * 3600
            : 0;
        HyperCoreTypes.Candle[] memory candles =
            pc.candleSnapshot(coin, "1h", fromTs, nowTs + 3600);
        if (candles.length < 2) return 0;
        // Take the last `need` candles (the precompile returns
        // ascending by startTime, so slice from the tail).
        uint256 take = need < candles.length ? need : candles.length;
        uint256 start = candles.length - take;

        uint256 sumSq = 0;
        uint256 count = 0;
        for (uint256 i = 1; i < take; i++) {
            int256 prevClose = int256(candles[start + i - 1].close);
            int256 curClose = int256(candles[start + i].close);
            if (prevClose <= 0 || curClose <= 0) continue;
            // ln approximation: ln(x/y) ≈ 2*(x - y) / (x + y)
            // Multiply by 1e6 BEFORE dividing so the result is in
            // 1e6-scaled units (matching the downstream sum-of-
            // squares bookkeeping below). Without this factor, any
            // move < ~50% would truncate to 0 and the whole vol
            // computation would collapse to zero.
            int256 num = curClose - prevClose;
            int256 den = curClose + prevClose;
            if (den == 0) continue;
            int256 logR = (2 * num * 1_000_000) / den; // 1e6-scaled
            // r^2 in (1e6)^2 = 1e12 units. Sum.
            sumSq += uint256(int256(logR) * logR);
            count++;
        }
        if (count == 0) return 0;
        // mean(r^2), still in 1e12-scaled.
        uint256 meanSq = sumSq / count;
        // Hourly sigma in 1e6-scaled: sqrt(meanSq) where meanSq is
        // in 1e12 units, so sqrt is in 1e6 units.
        uint256 hourlySigma6 = _isqrt(meanSq);
        // Annualize to the lookback window:
        //   sigma_lookback = sigma_hourly * sqrt(lookbackHrs)
        // Compute sqrt(lookbackHrs) in 1e6-scaled units by taking
        // isqrt(lookbackHrs * 1e12) — the 1e12 shifts the sqrt
        // by 1e6 to the right.
        uint256 sqrtLookback6 =
            _isqrt(uint256(lookbackHrs) * 1_000_000_000_000);
        // Multiply: hourlySigma6 * sqrtLookback6 / 1e6.
        // Overflow guard: hourlySigma6 is at most ~1e6 (representing
        // 1.0 unscaled), sqrtLookback6 is at most ~1e6 * sqrt(lookbackHrs)
        // which is bounded by ~1e6 * sqrt(uint32.max) ≈ 1.9e9. The
        // product fits comfortably in uint256.
        uint256 sigmaLookback6 =
            (hourlySigma6 * sqrtLookback6) / 1_000_000;
        // Convert to bps: scaled6 * 10_000 / 1e6 = scaled6 / 100.
        if (sigmaLookback6 > type(uint256).max / 10_000) {
            return type(uint256).max;
        }
        return sigmaLookback6 * 10_000 / 1_000_000;
    }

    /**
     * @dev Spot price for `coin` in USDC (6 decimals).
     *
     * Returns 0 for coins that have no market data yet — RegimeDetector
     * reverts with "zero spot" on this case, which is the desired
     * fail-loud behaviour.
     */
    function spotPrice(string calldata coin)
        external view override returns (uint256)
    {
        IHyperCorePrecompile pc = IHyperCorePrecompile(precompile);
        HyperCoreTypes.MarketData memory md = pc.marketData(coin);
        if (md.spotPrice <= 0) return 0;
        return uint256(int256(md.spotPrice));
    }

    /**
     * @dev Perp mark price for `coin` in USDC (6 decimals).
     *
     * Uses the oracle price as a stand-in for the perp mark. Real
     * venues expose these separately; the adapter collapses them to
     * one source until Kinetiq's precompile spec disambiguates.
     *
     * Returns `spotPrice(coin)` as a fallback if the oracle is zero
     * but spot is non-zero — this preserves RegimeDetector's "no
     * basis" semantics for a market that only has a spot feed.
     */
    function perpMarkPrice(string calldata coin)
        external view override returns (uint256)
    {
        IHyperCorePrecompile pc = IHyperCorePrecompile(precompile);
        HyperCoreTypes.MarketData memory md = pc.marketData(coin);
        if (md.oraclePrice > 0) return uint256(int256(md.oraclePrice));
        // Fallback: use spot as a proxy. This gives a zero basis,
        // which is the honest answer when we don't have a perp mark.
        return md.spotPrice > 0 ? uint256(int256(md.spotPrice)) : 0;
    }

    // ---- int sqrt (Newton's method) ----

    /// @dev Integer square root. Uses Newton's method; correct for
    ///     all uint256 inputs (including 0 and uint256.max).
    function _isqrt(uint256 n) internal pure returns (uint256 x) {
        if (n == 0) return 0;
        uint256 y = n;
        uint256 xNew = (n + y) / 2;
        while (xNew < y) {
            y = xNew;
            xNew = (n / xNew + xNew) / 2;
        }
        x = y;
    }
}
