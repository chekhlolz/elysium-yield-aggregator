// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@forge-std/Test.sol";
import "../src/legs/KHYPELeg.sol";
import "../src/legs/SpotStakingLeg.sol";
import "../src/legs/PerpFundingLeg.sol";
import "../src/legs/BasisHedgeLeg.sol";

/// Round-4 leg tests: cover the KI-3 (BasisHedgeLeg.allocateTo dust
/// guard) and KI-4 (setFixedApyBps refreshes latestApyBps) fixes.
contract LegsTest is Test {
    address constant OWNER  = address(0x1111);
    address constant ALICE  = address(0x2222);
    address constant TOKEN  = address(0xAAA1);   // dummy HYPE
    address constant POOL   = address(0xBB11);
    address constant WRITER = address(0xCC22);
    address constant TOA    = address(0xDD33);
    address constant FUND   = address(0xEE44);

    function setUp() public {
        // All tests run as OWNER (the deployer).
        vm.prank(OWNER);
    }

    function _deployKHYPE() internal returns (KHYPELeg) {
        // All optional integrations wired to non-zero addresses so the
        // leg's `address(x) == address(0)` checks are false and we
        // exercise the production paths.
        return new KHYPELeg(TOKEN, TOKEN, TOKEN, POOL, address(0), 1000);
    }

    function _deploySpot() internal returns (SpotStakingLeg) {
        return new SpotStakingLeg(TOKEN, TOKEN, TOKEN, POOL, address(0), 1000);
    }

    function _deployPerp() internal returns (PerpFundingLeg) {
        return new PerpFundingLeg(
            TOKEN, TOKEN, TOKEN, WRITER, TOA, address(0), FUND, TOKEN, 1000
        );
    }

    function _deployBasis() internal returns (BasisHedgeLeg) {
        return new BasisHedgeLeg(
            TOKEN, TOKEN, TOKEN, WRITER, TOA, address(0), TOKEN, 1000
        );
    }

    // ---- KI-4 (Round-4 fix): setFixedApyBps refreshes latestApyBps ----
    //
    // Each leg's expectedApy() reads `latestApyBps` when its oracle/funding
    // source is unwired (zero address). Before the fix, setFixedApyBps only
    // wrote `fixedApyBps`, so the cached `latestApyBps` stayed stale until
    // the next harvest/allocateTo. After the fix, expectedApy() reflects
    // the new value immediately when the oracle is unwired.

    function test_KI4_KHYPELeg_setFixedApyBps_refreshesExpectedApy() public {
        KHYPELeg leg = _deployKHYPE();
        assertEq(leg.expectedApy(), 1000, "initial fallback");

        vm.prank(OWNER);
        leg.setFixedApyBps(2000);

        // expectedApy must reflect the new value immediately (oracle
        // is unwired, so the fallback is authoritative).
        assertEq(leg.expectedApy(), 2000, "expectedApy stale after setFixedApyBps");
    }

    function test_KI4_SpotStakingLeg_setFixedApyBps_refreshesExpectedApy() public {
        SpotStakingLeg leg = _deploySpot();
        assertEq(leg.expectedApy(), 1000);
        vm.prank(OWNER);
        leg.setFixedApyBps(2500);
        assertEq(leg.expectedApy(), 2500, "expectedApy stale after setFixedApyBps");
    }

    function test_KI4_BasisHedgeLeg_setFixedApyBps_refreshesExpectedApy() public {
        BasisHedgeLeg leg = _deployBasis();
        assertEq(leg.expectedApy(), 1000);
        vm.prank(OWNER);
        leg.setFixedApyBps(1500);
        assertEq(leg.expectedApy(), 1500, "expectedApy stale after setFixedApyBps");
    }

    function test_KI4_PerpFundingLeg_setFixedApyBps_refreshesExpectedApy() public {
        PerpFundingLeg leg = _deployPerp();
        assertEq(leg.expectedApy(), 1000);
        vm.prank(OWNER);
        leg.setFixedApyBps(3000);
        assertEq(leg.expectedApy(), 3000, "expectedApy stale after setFixedApyBps");
    }

    function test_KI4_onlyOwner_canSetFixedApyBps() public {
        KHYPELeg leg = _deployKHYPE();
        vm.prank(ALICE);
        vm.expectRevert("not owner");
        leg.setFixedApyBps(500);
    }

    // ---- KI-3 (Round-4 fix): BasisHedgeLeg.allocateTo dust guard ----
    //
    // Before the fix, `allocateTo(1)` made spotPortion = 0, the
    // `if (spotPortion == 0) spotPortion = amount;` guard promoted it to
    // 1, and the perp side ended at 0 — the leg recorded 1 USDC of
    // allocation against a single-sided position. The fix rejects
    // amount < 2 with "dust".

    function test_KI3_BasisHedgeLeg_allocateTo_rejectsDust() public {
        BasisHedgeLeg leg = _deployBasis();
        vm.prank(OWNER);
        // Explicit bytes cast: 4-char literal "dust" is ambiguous
        // against Vm.expectRevert(bytes4), so we force the bytes overload.
        vm.expectRevert(bytes("dust"));
        leg.allocateTo(1);
    }

    function test_KI3_BasisHedgeLeg_allocateTo_zeroStillRejected() public {
        BasisHedgeLeg leg = _deployBasis();
        vm.prank(OWNER);
        // amount = 0 still trips the original "zero" guard, not "dust".
        vm.expectRevert(bytes("zero"));
        leg.allocateTo(0);
    }

    // ---- Regression: allocateTo non-owner reverts on all 4 legs ----

    function test_allocateTo_requiresOwner_KHYPE() public {
        KHYPELeg leg = _deployKHYPE();
        vm.prank(ALICE);
        vm.expectRevert("not owner");
        leg.allocateTo(100);
    }

    function test_allocateTo_requiresOwner_Spot() public {
        SpotStakingLeg leg = _deploySpot();
        vm.prank(ALICE);
        vm.expectRevert("not owner");
        leg.allocateTo(100);
    }

    function test_allocateTo_requiresOwner_Perp() public {
        PerpFundingLeg leg = _deployPerp();
        vm.prank(ALICE);
        vm.expectRevert("not owner");
        leg.allocateTo(100);
    }

    function test_allocateTo_requiresOwner_Basis() public {
        BasisHedgeLeg leg = _deployBasis();
        vm.prank(ALICE);
        vm.expectRevert("not owner");
        leg.allocateTo(100);
    }

    // ---- Regression: nonReentrant guard on all 4 legs ----
    //
    // The NonReentrant guard's reset-between-calls behaviour is already
    // covered by YieldAggregator.t.sol (test_deposit_reentrantGuardResets-
    // BetweenCalls, test_executePending_reentrantGuardResetsBetweenCalls),
    // which exercises the modifier through a real call path. Leg-level
    // reentrancy is harder to test in isolation because harvest() on
    // each leg touches external pools / writer / router that aren't
    // set up in this test contract — the calls would revert on the
    // mock addresses, not on the guard itself.

    // ---- Regression: name() returns the expected leg identifier ----

    function test_name_KHYPE() public {
        KHYPELeg leg = _deployKHYPE();
        assertEq(leg.name(), "KHYPELeg");
    }

    function test_name_Spot() public {
        SpotStakingLeg leg = _deploySpot();
        assertEq(leg.name(), "SpotStakingLeg");
    }

    function test_name_Perp() public {
        PerpFundingLeg leg = _deployPerp();
        assertEq(leg.name(), "PerpFundingLeg");
    }

    function test_name_Basis() public {
        BasisHedgeLeg leg = _deployBasis();
        assertEq(leg.name(), "BasisHedgeLeg");
    }
}
