// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import "@forge-std/Test.sol";
import {HyperCoreTypes} from "../src/types.sol";
import {HyperCorePrecompileMock} from "../src/HyperCorePrecompileMock.sol";
import {HyperCoreFixture} from "../src/HyperCoreFixture.sol";
import {MarketDataFeedAdapter} from "../src/MarketDataFeedAdapter.sol";
import {IHyperCorePrecompile} from "../src/IHyperCorePrecompile.sol";
import {RegimeDetector} from "@hypeback-sol/keeper/RegimeDetector.sol";

/**
 * examples/using-the-harness.t.sol
 *
 * END-TO-END WALKTHROUGH. This file is the canonical "how do I use the
 * harness in my own test" example. It lives under `examples/` (not
 * `test/`) so it runs as part of `forge test` but reads as tutorial
 * code rather than a regression test.
 *
 * The scenario:
 *
 *   "I have a RegimeDetector that talks to a market-data feed. I want
 *    to test it without waiting for Kinetiq to publish the real
 *    precompile address on Elysium mainnet."
 *
 * The recipe:
 *
 *   1. Deploy a mock precompile (direct `new`, or via
 *      `HyperCoreFixture.deployFresh` / `deployDeterministic`).
 *   2. Prime the mock with the market state you want to test.
 *   3. Deploy `MarketDataFeedAdapter` pointing at the mock.
 *   4. Deploy your contract of interest (RegimeDetector here) with
 *      the adapter's address as the feed.
 *   5. Call `observe()` and assert on the regime.
 *
 * When Kinetiq publishes the real precompile at `0x...C0DE`, you
 * change step 3 to point at the real address - steps 1, 2, 4, 5 are
 * unchanged.
 *
 * NOTE ON COIN: `RegimeDetector.observe()` queries the feed for the
 * literal string `"HYPE"` (see solidity/src/keeper/RegimeDetector.sol
 * lines 114, 127, 151-152). The example primes data under "HYPE"
 * for the same reason.
 */
contract UsingTheHarnessExample is Test {
    // ---- 1. Deploy the fixture ----

    /// `new HyperCoreFixture()` is enough to get all three deploy
    /// helpers. `deployFresh` returns a unique address per call,
    /// `deployDeterministic` returns the same address every run.
    HyperCoreFixture fixture;

    /// The fixture is a thin wrapper - you could equally just do
    /// `new HyperCorePrecompileMock()` directly. The fixture is
    /// mainly here for the CREATE2 address and the snapshot loader.
    function setUp() public {
        fixture = new HyperCoreFixture();
    }

    /// The minimal example: prime one strong-funding tick, observe,
    /// assert FUNDING_STRONG.
    function test_example_MinimalSetup_primeObserveAssert() public {
        // 1. Deploy the mock directly. This is the simplest form -
        //    the mock implements the precompile interface, so we can
        //    hand it to the adapter.
        HyperCorePrecompileMock mock = new HyperCorePrecompileMock();

        // 2. Prime a single strong-funding tick.
        //    1e6-scaled = 20_000 -> adapter bps = 200 -> APY = 1,752,000.
        //    1,752,000 > 800 (strong threshold) -> FUNDING_STRONG.
        HyperCoreTypes.FundingSnapshot[] memory f =
            new HyperCoreTypes.FundingSnapshot[](1);
        f[0] = HyperCoreTypes.FundingSnapshot(
            20_000, int64(1_000_000), 1_700_000_000 + 3600
        );
        mock.setFunding("HYPE", f);

        // 3. Prime market data so spot & perp are non-zero.
        mock.setMarketData("HYPE", HyperCoreTypes.MarketData({
            spotPrice: 100_000_000,        // $100.00
            oraclePrice: 100_000_500,      // $100.000500 (tiny premium)
            timestamp: 1_700_000_000 + 3600
        }));

        // 4. Deploy the adapter, then the detector.
        MarketDataFeedAdapter adapter =
            new MarketDataFeedAdapter(address(mock), 3600);
        vm.prank(address(0x1111));
        RegimeDetector detector = new RegimeDetector(address(adapter));

        // 5. Observe and assert.
        detector.observe();
        RegimeDetector.RegimeSnapshot memory snap = detector.current();
        assertEq(uint8(snap.regime), 0, "FUNDING_STRONG");
        assertEq(snap.fundingApyBps_24h, 1_752_000, "annualised APY");
    }

    /// How to use the fixture's CREATE2 helper for an immutable feed
    /// address. Real test pattern:
    ///
    ///   address precompile; // computed before deploy
    ///   ... some contract with `immutable marketDataFeed`
    ///
    /// We compute the address first, deploy the mock there, then
    /// deploy the contract that needs it.
    function test_example_Create2_immutableFeedAddress() public {
        // Compute the address the mock will land at, given the
        // fixture is the deployer.
        address predicted =
            fixture.computeDeterministicAddress(address(fixture));

        // Deploy the mock at that address.
        address deployed = fixture.deployDeterministic();

        // The deployed address must match the prediction - this is
        // the whole point of CREATE2.
        assertEq(deployed, predicted, "CREATE2 deterministic");

        // Now we can use `predicted` as an immutable arg to any
        // contract we want to deploy next, without re-querying.
        MarketDataFeedAdapter adapter =
            new MarketDataFeedAdapter(predicted, 3600);

        // Sanity: the adapter is actually talking to the mock. We
        // cast back to the mock type to verify it's reachable and
        // empty.
        HyperCorePrecompileMock mock = HyperCorePrecompileMock(predicted);
        assertEq(mock.fundingCount("HYPE"), 0, "empty feed");
        assertEq(adapter.fundingRateBps("HYPE"), 0, "empty feed via adapter");
    }

    /// Full 24-hour realized-vol walkthrough: prime 24 hourly
    /// candles with a known pattern, then check the adapter's vol
    /// matches the expected value.
    function test_example_RealizedVol_24HourWalkthrough() public {
        HyperCorePrecompileMock mock = new HyperCorePrecompileMock();

        // 24 hourly candles, alternating 25% up / 25% down starting
        // at $100. This gives a well-defined realized vol that we
        // can verify against the expected value.
        uint64 T0 = 1_700_000_000;
        uint256 numHours = 24;
        HyperCoreTypes.Candle[] memory candles =
            new HyperCoreTypes.Candle[](numHours);
        int64 p = 100_000_000; // $100.00 in 1e6-scaled
        for (uint256 i = 0; i < numHours; i++) {
            int64 dir = (i % 2 == 0) ? int64(1) : int64(-1);
            int64 next = p + p * 25 * dir / 100;
            candles[i] = HyperCoreTypes.Candle({
                open: p,
                high: dir > 0 ? next : p,
                low: dir > 0 ? p : next,
                close: next,
                startTime: uint64(T0 + i * 3600),
                endTime: uint64(T0 + (i + 1) * 3600),
                volume: 1_000_000
            });
            p = next;
        }
        // Warp so the adapter's 24h lookback window covers these candles.
        vm.warp(T0 + numHours * 3600);
        mock.setCandles("HYPE", "1h", candles);

        MarketDataFeedAdapter adapter =
            new MarketDataFeedAdapter(address(mock), 3600);

        // The realized vol should be well above the 9,000 bps
        // HIGH_VOL threshold (the comment in AdapterIntegration.t.sol
        // shows the exact math: ~9,800 bps).
        uint256 vol = adapter.realizedVolBps("HYPE", 24);
        assertGt(vol, 9_000, "vol above HIGH_VOL threshold");
        emit log_named_uint("realizedVolBps", vol);
    }

    /// The "I want to test the real RegimeDetector against a hostile
    /// feed" pattern: prime funding at INT64_MAX to verify the
    /// saturation guard in RegimeDetector (round-9 hardening).
    ///
    /// What actually fires:
    ///   - The adapter does `rate / 100` on INT64_MAX, getting
    ///     INT64_MAX / 100 = 92,233,720,368,547,758. That fits in
    ///     int64, so the adapter's own saturation guard is a no-op
    ///     here. (The guard is for the case where the input could
    ///     already be larger than int64, which doesn't happen with
    ///     an int64 source.)
    ///   - The interesting hardening is in RegimeDetector.observe():
    ///     `apyBpsInt = hourlyBps * 8760` overflows int64 for any
    ///     hourlyBps > ~107 billion. RegimeDetector saturates to
    ///     INT64_MAX (not wraps to a negative value). The classifier
    ///     still sees a positive value -> FUNDING_STRONG, never
    ///     silently flips to FUNDING_NEG.
    function test_example_HostileFeed_saturationGuard() public {
        HyperCorePrecompileMock mock = new HyperCorePrecompileMock();

        // INT64_MAX as a 1e6-scaled rate. This is a hostile feeder
        // that wants to overflow RegimeDetector's `apyBpsInt * 8760`.
        HyperCoreTypes.FundingSnapshot[] memory f =
            new HyperCoreTypes.FundingSnapshot[](1);
        f[0] = HyperCoreTypes.FundingSnapshot(
            type(int64).max, int64(1), 1_700_000_000 + 3600
        );
        mock.setFunding("HYPE", f);
        mock.setMarketData("HYPE", HyperCoreTypes.MarketData({
            spotPrice: 100_000_000, oraclePrice: 100_000_000,
            timestamp: 1_700_000_000 + 3600
        }));

        MarketDataFeedAdapter adapter =
            new MarketDataFeedAdapter(address(mock), 3600);
        vm.prank(address(0x1111));
        RegimeDetector detector = new RegimeDetector(address(adapter));

        // The adapter divides by 100 (1e6-scaled -> bps). INT64_MAX
        // / 100 = 92,233,720,368,547,758 - a value that still fits
        // in int64, so the adapter returns it directly. The point is
        // that the adapter does NOT silently truncate to 0, and the
        // sign is preserved (positive).
        int64 bps = adapter.fundingRateBps("HYPE");
        assertEq(bps, int64(type(int64).max / 100),
                 "adapter: rate / 100, no overflow");
        assertGt(bps, 0, "sign preserved");

        // RegimeDetector then multiplies by 8760, which overflows
        // int64 - but it saturates to INT64_MAX (round-9 hardening),
        // never wraps to a negative value. So the classifier still
        // sees a positive value -> FUNDING_STRONG, never flips to
        // FUNDING_NEG. This is the silent-inversion bug the harness
        // exists to catch.
        detector.observe();
        assertEq(uint8(detector.current().regime), 0,
                 "still FUNDING_STRONG, not inverted");
    }
}
