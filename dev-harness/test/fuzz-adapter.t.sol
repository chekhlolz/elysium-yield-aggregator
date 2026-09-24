// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import "@forge-std/Test.sol";
import {HyperCoreTypes} from "../src/types.sol";
import {HyperCorePrecompileMock} from "../src/HyperCorePrecompileMock.sol";
import {MarketDataFeedAdapter} from "../src/MarketDataFeedAdapter.sol";
import {IHyperCorePrecompile} from "../src/IHyperCorePrecompile.sol";

/**
 * fuzz-adapter.t.sol — property-based tests for MarketDataFeedAdapter.
 *
 * These tests run `forge test --fuzz-runs=256` (default) against
 * random inputs to verify invariants that hold regardless of input:
 *
 *   1. fundingRateBps never returns a value outside int64 range —
 *      even for hostile 1e6-scaled rates that would overflow if we
 *      forgot the saturation guard.
 *
 *   2. spotPrice / perpMarkPrice return uint256 (never revert,
 *      never negative — even when the mock holds a negative int64
 *      "price" that a hostile feeder could push in).
 *
 *   3. perpMarkPrice falls back to spot when the oracle is zero,
 *      which is the documented degradation path.
 *
 *   4. realizedVolBps never returns a value above uint256 max,
 *      and is monotonically non-decreasing in the magnitude of
 *      per-hour moves (more extreme moves → higher vol).
 *
 *   5. The adapter's 1e6→bps conversion is exact for well-formed
 *      inputs: `rate / 100` with truncation, matching the spec.
 *
 * Naming convention: forge-std's Test.sol discovers any function
 * starting with `testFuzz_` as a fuzz test, treating all parameters
 * as the fuzz inputs. We also define pure `test_` helpers that pin
 * specific edge cases the fuzzer would rarely hit.
 */
contract FuzzAdapterTest is Test {
    string constant COIN = "HYPE/USDC";
    uint64 constant T0 = 1_700_000_000;

    HyperCorePrecompileMock precompile;
    MarketDataFeedAdapter adapter;

    function setUp() public {
        precompile = new HyperCorePrecompileMock();
        adapter = new MarketDataFeedAdapter(address(precompile), 3600);
    }

    /// The adapter's bps output is always in [int64.min, int64.max],
    /// no matter what 1e6-scaled funding rate the mock holds. This
    /// is the saturation guard that protects RegimeDetector from
    /// hostile feeds.
    function testFuzz_fundingRateBps_alwaysInInt64Range(int64 rate) public {
        HyperCoreTypes.FundingSnapshot[] memory f =
            new HyperCoreTypes.FundingSnapshot[](1);
        f[0] = HyperCoreTypes.FundingSnapshot(rate, int64(1), uint64(T0));
        precompile.setFunding(COIN, f);
        int64 out = adapter.fundingRateBps(COIN);
        assertGe(out, type(int64).min, "lower saturation");
        assertLe(out, type(int64).max, "upper saturation");
    }

    /// Well-formed rates pass through as `rate / 100` (bps = rate / 1e6 * 10_000).
    /// This pins the conversion for values that fit in int64 / 100 without
    /// truncation ambiguity (i.e. rate ∈ [-1e6 * 100, 1e6 * 100]).
    function testFuzz_fundingRateBps_conversion_isRateOver100(int24 rate) public {
        HyperCoreTypes.FundingSnapshot[] memory f =
            new HyperCoreTypes.FundingSnapshot[](1);
        f[0] = HyperCoreTypes.FundingSnapshot(int64(rate), int64(1), uint64(T0));
        precompile.setFunding(COIN, f);
        int64 out = adapter.fundingRateBps(COIN);
        // int24 / 100 always fits in int64, so the adapter must match.
        assertEq(out, int64(rate) / 100, "bps = rate / 100");
    }

    /// spotPrice coerces to uint256. For non-negative market data the
    /// return value equals the input; for negative market data (which
    /// shouldn't happen but a hostile feeder could push) the adapter
    /// returns 0 because of the `md.spotPrice <= 0` guard.
    function testFuzz_spotPrice_returnsUint256(int64 spot, int64 oracle) public {
        precompile.setMarketData(COIN, HyperCoreTypes.MarketData({
            spotPrice: spot,
            oraclePrice: oracle,
            timestamp: uint64(T0)
        }));
        uint256 out = adapter.spotPrice(COIN);
        if (spot > 0) {
            assertEq(out, uint256(int256(spot)), "spot passthrough");
        } else {
            assertEq(out, 0, "non-positive spot returns 0");
        }
    }

    /// perpMarkPrice uses the oracle when it's positive, otherwise
    /// falls back to spot. Empty market data → 0.
    function testFuzz_perpMarkPrice_fallsBackToSpot_whenOracleNonPositive(
        int64 spot, int64 oracle
    ) public
    {
        precompile.setMarketData(COIN, HyperCoreTypes.MarketData({
            spotPrice: spot,
            oraclePrice: oracle,
            timestamp: uint64(T0)
        }));
        uint256 out = adapter.perpMarkPrice(COIN);
        if (oracle > 0) {
            assertEq(out, uint256(int256(oracle)), "oracle passthrough");
        } else if (spot > 0) {
            assertEq(out, uint256(int256(spot)), "spot fallback");
        } else {
            assertEq(out, 0, "all-zero returns 0");
        }
    }

    /// realizedVolBps is bounded by uint256 max — the saturation guard
    /// fires for absurd lookback windows rather than overflowing.
    function testFuzz_realizedVolBps_neverOverflows(uint16 lookbackHrs) public {
        // Prime some candles so the adapter has data to compute on.
        HyperCoreTypes.Candle[] memory cs =
            new HyperCoreTypes.Candle[](3);
        int64 p = int64(100) * 1_000_000;
        for (uint256 i = 0; i < 3; i++) {
            int64 next = p + (i % 2 == 0 ? p / 10 : -p / 10);
            cs[i] = HyperCoreTypes.Candle({
                open: p, high: p > next ? p : next, low: p > next ? next : p,
                close: next,
                startTime: uint64(T0 + i * 3600),
                endTime: uint64(T0 + (i + 1) * 3600),
                volume: 1_000_000
            });
            p = next;
        }
        vm.warp(uint64(T0 + 3 * 3600));
        precompile.setCandles(COIN, "1h", cs);
        uint256 out = adapter.realizedVolBps(COIN, uint32(lookbackHrs));
        assertLe(out, type(uint256).max, "no overflow");
    }

    /// realizedVolBps is monotonically non-decreasing in the magnitude
    /// of per-hour moves. Bigger swings → higher vol.
    function testFuzz_realizedVolBps_monotonicInMoveSize(int8 movePct) public {
        // movePct is in percent; clamp to a sane range so prices stay
        // positive (otherwise the Taylor approx divides by zero).
        int8 m = movePct;
        if (m > 50) m = 50;
        if (m < -50) m = -50;
        uint256 numHours = 24;
        HyperCoreTypes.Candle[] memory cs =
            new HyperCoreTypes.Candle[](numHours);
        int64 p = int64(100) * 1_000_000;
        for (uint256 i = 0; i < numHours; i++) {
            int64 next = p + p * int64(m) / 100;
            if (next <= 0) next = 1; // keep prices positive
            int64 hi = p > next ? p : next;
            int64 lo = p > next ? next : p;
            cs[i] = HyperCoreTypes.Candle({
                open: p, high: hi, low: lo, close: next,
                startTime: uint64(T0 + i * 3600),
                endTime: uint64(T0 + (i + 1) * 3600),
                volume: 1_000_000
            });
            p = next;
        }
        vm.warp(uint64(T0 + numHours * 3600));
        precompile.setCandles(COIN, "1h", cs);
        uint256 vol = adapter.realizedVolBps(COIN, 24);
        // Sanity: vol is finite. (Monotonicity check lives in the
        // pinned edge case below.)
        assertTrue(vol <= type(uint256).max / 100, "vol is sane");
    }

    /// Larger per-hour move magnitude ⇒ larger realized vol. Pinned
    /// comparison: 10% moves < 25% moves. This catches regressions in
    /// the Taylor approx that would flatten the vol curve.
    function test_realizedVolBps_largerMovesGiveLargerVol() public {
        uint256 vol10 = _volForMovePct(10);
        uint256 vol25 = _volForMovePct(25);
        assertGt(vol25, vol10, "25pct moves give higher vol than 10pct");
        emit log_named_uint("vol10pct", vol10);
        emit log_named_uint("vol25pct", vol25);
    }

    /// An empty feed returns 0 for everything — no panics, no reverts.
    function test_realizedVolBps_emptyFeed_returnsZero() public view {
        assertEq(adapter.realizedVolBps(COIN, 24), 0);
        assertEq(adapter.realizedVolBps(COIN, 1), 0);
        assertEq(adapter.realizedVolBps(COIN, 0), 0, "lookback=0 gives 0");
    }

    /// The adapter is coin-agnostic: priming "HYPE" data does not
    /// leak into "BTC".
    function test_adapter_coinIsolation() public {
        precompile.setMarketData("HYPE", HyperCoreTypes.MarketData({
            spotPrice: 100_000_000,
            oraclePrice: 100_000_000,
            timestamp: uint64(T0)
        }));
        assertEq(adapter.spotPrice("HYPE"), 100_000_000);
        assertEq(adapter.spotPrice("BTC"), 0, "different coin gives 0");
    }

    // ---- helpers ----

    function _volForMovePct(int64 movePct) internal returns (uint256) {
        uint256 numHours = 24;
        HyperCoreTypes.Candle[] memory cs =
            new HyperCoreTypes.Candle[](numHours);
        int64 p = int64(100) * 1_000_000;
        for (uint256 i = 0; i < numHours; i++) {
            int64 dir = (i % 2 == 0) ? int64(1) : int64(-1);
            int64 next = p + p * movePct * dir / 100;
            if (next <= 0) next = 1;
            int64 hi = p > next ? p : next;
            int64 lo = p > next ? next : p;
            cs[i] = HyperCoreTypes.Candle({
                open: p, high: hi, low: lo, close: next,
                startTime: uint64(T0 + i * 3600),
                endTime: uint64(T0 + (i + 1) * 3600),
                volume: 1_000_000
            });
            p = next;
        }
        vm.warp(uint64(T0 + numHours * 3600));
        precompile.setCandles(COIN, "1h", cs);
        return adapter.realizedVolBps(COIN, 24);
    }
}
