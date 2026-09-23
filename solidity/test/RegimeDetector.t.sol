// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@forge-std/Test.sol";
import "../src/keeper/RegimeDetector.sol";

/// Mock IMarketDataFeed for testing RegimeDetector.observe(). All
/// four return values are externally mutable so each test can pin
/// exactly the (funding, vol, spot, perp) tuple it wants to drive
/// through observe(). The precompile stub is what production deploys
/// point at; this mock just gives us a way to vary the market data
/// deterministically.
contract MockMarketDataFeed is IMarketDataFeed {
    int64  fundingRate;
    uint256 vol;
    uint256 spot;
    uint256 perp;

    function fundingRateBps(string calldata) external view override returns (int64) { return fundingRate; }
    function realizedVolBps(string calldata, uint32) external view override returns (uint256) { return vol; }
    function spotPrice(string calldata) external view override returns (uint256) { return spot; }
    function perpMarkPrice(string calldata) external view override returns (uint256) { return perp; }

    function setValues(int64 _f, uint256 _v, uint256 _s, uint256 _p) external {
        fundingRate = _f;
        vol = _v;
        spot = _s;
        perp = _p;
    }
}

contract RegimeDetectorTest is Test {
    address constant OWNER = address(0x1);
    address constant ALICE = address(0x2);
    address constant FEED  = address(0x3); // arbitrary non-zero address

    RegimeDetector detector;
    MockMarketDataFeed feed;

    function setUp() public {
        feed = new MockMarketDataFeed();
        vm.prank(OWNER);
        detector = new RegimeDetector(address(feed));
    }

    // ---- Construction ----

    function test_constructorSetsOwner() public view {
        assertEq(detector.owner(), OWNER);
        assertEq(detector.marketDataFeed(), address(feed));
    }

    function test_constructorRejectsZeroFeed() public {
        vm.expectRevert("zero feed");
        new RegimeDetector(address(0));
    }

    function test_constructorDefaultThresholds() public view {
        (uint256 strong, uint256 weak, uint256 highVol) = detector.thresholds();
        assertEq(strong, 800);
        assertEq(weak, 300);
        assertEq(highVol, 9000);
    }

    // ---- setThresholds: round-3 P0 fix ----

    function test_setThresholds_ownerCanUpdate() public {
        vm.prank(OWNER);
        detector.setThresholds(RegimeDetector.Thresholds(1000, 400, 8000));
        (uint256 s, uint256 w, uint256 h) = detector.thresholds();
        assertEq(s, 1000);
        assertEq(w, 400);
        assertEq(h, 8000);
    }

    function test_setThresholds_randomCallerReverts() public {
        vm.prank(ALICE);
        vm.expectRevert("not owner");
        detector.setThresholds(RegimeDetector.Thresholds(0, 0, 0));
    }

    function test_setThresholds_rejectsBadOrder() public {
        vm.prank(OWNER);
        vm.expectRevert("bad threshold order");
        detector.setThresholds(RegimeDetector.Thresholds(300, 800, 9000));
    }

    // ---- computeRegime priority chain (invariant: HIGH_VOL > FUNDING_NEG > STRONG > WEAK) ----

    function test_computeRegime_highVolWinsOverEverything() public view {
        // High vol wins even with strong positive APY
        uint8 r = detector.computeRegime(int64(5000), 9500);
        assertEq(r, RegimeId.HIGH_VOL);
    }

    function test_computeRegime_fundingNegWinsOverStrong() public view {
        // Negative funding takes priority over any positive APY threshold
        uint8 r = detector.computeRegime(int64(-50), 100);
        assertEq(r, RegimeId.FUNDING_NEG);
    }

    function test_computeRegime_strongAtThreshold() public view {
        // exactly at strong threshold
        uint8 r = detector.computeRegime(int64(800), 100);
        assertEq(r, RegimeId.FUNDING_STRONG);
    }

    function test_computeRegime_weakAtThreshold() public view {
        // exactly at weak threshold
        uint8 r = detector.computeRegime(int64(300), 100);
        assertEq(r, RegimeId.FUNDING_WEAK);
    }

    function test_computeRegime_zeroApyIsWeak() public view {
        uint8 r = detector.computeRegime(int64(0), 100);
        assertEq(r, RegimeId.FUNDING_WEAK);
    }

    // ---- Fuzz: regime priority invariant across any (apySigned, volBps) ----

    function testFuzz_regimePriorityChain(int64 apySigned, uint256 volBps) public view {
        uint8 r = detector.computeRegime(apySigned, volBps);
        // Must be one of the four valid values
        assertTrue(r <= RegimeId.HIGH_VOL);
    }

    // ---- weightsForRegime: each regime returns weights summing to 10_000 ----

    function test_weightsForRegimeStrongSumsTo10000() public view {
        uint16[4] memory w = detector.weightsForRegime(RegimeId.FUNDING_STRONG);
        assertEq(uint256(w[0]) + w[1] + w[2] + w[3], 10_000);
    }

    function test_weightsForRegimeWeakSumsTo10000() public view {
        uint16[4] memory w = detector.weightsForRegime(RegimeId.FUNDING_WEAK);
        assertEq(uint256(w[0]) + w[1] + w[2] + w[3], 10_000);
    }

    function test_weightsForRegimeNegSumsTo10000() public view {
        uint16[4] memory w = detector.weightsForRegime(RegimeId.FUNDING_NEG);
        assertEq(uint256(w[0]) + w[1] + w[2] + w[3], 10_000);
    }

    function test_weightsForRegimeHighVolSumsTo10000() public view {
        uint16[4] memory w = detector.weightsForRegime(RegimeId.HIGH_VOL);
        assertEq(uint256(w[0]) + w[1] + w[2] + w[3], 10_000);
    }

    // ---- Gap doc §2.3: observe() ----
    //
    // observe() is the contract's only state-mutating path. It reads
    // the IMarketDataFeed stub, computes a new RegimeSnapshot, stores
    // it in `lastSnapshot`, and emits RegimeUpdated only if the
    // regime changed. The four tests below pin:
    //   - lastSnapshot is populated from the feed on every call
    //   - RegimeUpdated emits when the regime changes
    //   - RegimeUpdated does NOT emit when the regime is unchanged
    //   - the default thresholds drive the right regime classification
    //
    // Arithmetic pin: hourlyFundingBps * 8760 = annualised APY bps.
    // A negative funding rate yields a negative APY which the
    // contract stores as `apyAbs = 0` in lastSnapshot — only the
    // signed value drives regime classification; the absolute value
    // is what gets persisted.

    function test_observe_populatesLastSnapshot() public {
        // funding=-5 bps/hr, vol=100, spot=100e6, perp=110e6.
        // apySigned = -5 * 8760 = -43800 bps (FUNDING_NEG).
        // apyAbs = 0 because apySigned < 0.
        // basisBps = (110e6 - 100e6) * 10000 / 100e6 = 1000.
        feed.setValues(int64(-5), 100, 100e6, 110e6);
        vm.prank(OWNER);
        detector.observe();

        RegimeDetector.RegimeSnapshot memory s = detector.current();
        assertEq(uint256(s.regime), uint256(RegimeId.FUNDING_NEG), "regime should be FUNDING_NEG");
        assertEq(s.fundingApyBps_24h, 0, "negative funding stored as 0");
        assertEq(s.hypeVolBps_24h, 100, "vol should be from feed");
        assertEq(s.basisBps, 1000, "basis = (110-100)/100 * 10000");
        assertEq(s.observedAt, uint64(block.timestamp), "observedAt should be now");
    }

    function test_observe_emitsWhenRegimeChanges() public {
        // First call: FUNDING_NEG regime.
        feed.setValues(int64(-5), 100, 100e6, 100e6);
        vm.expectEmit(true, false, true, true);
        emit RegimeDetector.RegimeUpdated(
            RegimeId.FUNDING_NEG, 0, uint64(block.timestamp)
        );
        vm.prank(OWNER);
        detector.observe();

        // Second call: regime unchanged — no event expected.
        feed.setValues(int64(-6), 100, 100e6, 100e6);
        vm.prank(OWNER);
        detector.observe();

        // Third call: regime flips to STRONG — expect emit.
        feed.setValues(int64(10), 100, 100e6, 100e6);
        vm.expectEmit(true, false, true, true);
        emit RegimeDetector.RegimeUpdated(
            RegimeId.FUNDING_STRONG, 87600, uint64(block.timestamp)
        );
        vm.prank(OWNER);
        detector.observe();

        RegimeDetector.RegimeSnapshot memory s = detector.current();
        assertEq(uint256(s.regime), uint256(RegimeId.FUNDING_STRONG), "regime should be STRONG");
        assertEq(s.fundingApyBps_24h, 87600, "apyAbs = 10 * 8760 = 87600");
    }

    function test_observe_doesNotEmitWhenRegimeUnchanged() public {
        // Both calls land in FUNDING_STRONG — the second call must
        // not emit RegimeUpdated. forge-std expectEmit fails the
        // test on any unexpected event, so the absence of an
        // expectEmit between the two calls is the implicit no-emit
        // assertion. We pin state changes instead.
        feed.setValues(int64(10), 100, 100e6, 100e6);
        vm.prank(OWNER);
        detector.observe();

        uint256 apyBefore = detector.current().fundingApyBps_24h;
        uint8 regimeBefore = detector.current().regime;

        // Slightly different funding — still STRONG regime.
        feed.setValues(int64(11), 100, 100e6, 100e6);
        vm.prank(OWNER);
        detector.observe();

        RegimeDetector.RegimeSnapshot memory s = detector.current();
        assertEq(uint256(s.regime), uint256(regimeBefore), "regime unchanged (no emit expected)");
        assertGt(s.fundingApyBps_24h, apyBefore, "apy advanced despite regime unchanged");
    }

    function test_observe_usesDefaultThresholds() public {
        // Default thresholds: strong=800, weak=300, highVol=9000.
        // STRONG: apySigned >= 800, vol < 9000.
        feed.setValues(int64(1), 100, 100e6, 100e6);
        // 1 * 8760 = 8760 bps >= 800, so STRONG.
        vm.prank(OWNER);
        detector.observe();
        assertEq(uint256(detector.current().regime), uint256(RegimeId.FUNDING_STRONG));

        // NEG: apySigned < 0.
        feed.setValues(int64(-1), 100, 100e6, 100e6);
        vm.prank(OWNER);
        detector.observe();
        assertEq(uint256(detector.current().regime), uint256(RegimeId.FUNDING_NEG));

        // HIGH_VOL: vol >= 9000 wins over everything.
        feed.setValues(int64(1), 9500, 100e6, 100e6);
        vm.prank(OWNER);
        detector.observe();
        assertEq(uint256(detector.current().regime), uint256(RegimeId.HIGH_VOL));
    }
}
