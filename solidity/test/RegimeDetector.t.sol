// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@forge-std/Test.sol";
import "../src/keeper/RegimeDetector.sol";

contract RegimeDetectorTest is Test {
    address constant OWNER = address(0x1);
    address constant ALICE = address(0x2);
    address constant FEED  = address(0x3); // arbitrary non-zero address

    RegimeDetector detector;

    function setUp() public {
        vm.prank(OWNER);
        detector = new RegimeDetector(FEED);
    }

    // ---- Construction ----

    function test_constructorSetsOwner() public view {
        assertEq(detector.owner(), OWNER);
        assertEq(detector.marketDataFeed(), FEED);
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
}
