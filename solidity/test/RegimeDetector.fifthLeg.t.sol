// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@forge-std/Test.sol";
import "../src/keeper/RegimeDetector.sol";

/**
 * @title RegimeDetector.fifthLeg
 * @notice Tests for the 5-leg weight vector introduced by task A3:
 * Liminal xHYPE becomes the 5th allocation bucket, drained from
 * kHYPE per the "xHYPE first" migration rule.
 *
 * Coverage:
 *   - weightsForRegime5 sums to 10_000 in every regime
 *   - xHYPE weight ≤ what kHYPE would have received in that regime
 *     (4-leg weightsForRegime[1])
 *   - kHYPE weight = (original 4-leg kHYPE weight) − (xHYPE weight)
 *     (xHYPE strictly drains kHYPE; other buckets unchanged)
 *   - Spot / perpFunding / basisHedge buckets are IDENTICAL between
 *     the 4-leg and 5-leg views (only kHYPE is diminished)
 *   - XHYPE_WEIGHT_BPS(regime) == weightsForRegime5(regime)[4]
 *   - Monotonic migration across regimes: as funding pressure
 *     strengthens, xHYPE weight monotonically decreases (because
 *     perp captures the marginal bps in strong-funding regimes)
 */
contract RegimeDetectorFifthLegTest is Test {
    RegimeDetector rd;

    function setUp() public {
        // MarketDataFeed argument is unused by the weights* helpers
        // (they're pure) so a non-zero placeholder is fine.
        address feed = address(0xC0FFEE);
        rd = new RegimeDetector(feed);
    }

    // ---- Sums ----

    function test_weightsForRegime5_strongSumsTo10000() public view {
        uint16[5] memory w = rd.weightsForRegime5(RegimeId.FUNDING_STRONG);
        assertEq(uint256(w[0]) + w[1] + w[2] + w[3] + w[4], 10_000);
    }

    function test_weightsForRegime5_weakSumsTo10000() public view {
        uint16[5] memory w = rd.weightsForRegime5(RegimeId.FUNDING_WEAK);
        assertEq(uint256(w[0]) + w[1] + w[2] + w[3] + w[4], 10_000);
    }

    function test_weightsForRegime5_negSumsTo10000() public view {
        uint16[5] memory w = rd.weightsForRegime5(RegimeId.FUNDING_NEG);
        assertEq(uint256(w[0]) + w[1] + w[2] + w[3] + w[4], 10_000);
    }

    function test_weightsForRegime5_highVolSumsTo10000() public view {
        uint16[5] memory w = rd.weightsForRegime5(RegimeId.HIGH_VOL);
        assertEq(uint256(w[0]) + w[1] + w[2] + w[3] + w[4], 10_000);
    }

    // ---- xHYPE ≤ original kHYPE (per-regime) ----

    function test_weightsForRegime5_xHypeNeverExceedsOriginalkHype_strong() public view {
        uint16[4] memory w4 = rd.weightsForRegime(RegimeId.FUNDING_STRONG);
        uint16[5] memory w5 = rd.weightsForRegime5(RegimeId.FUNDING_STRONG);
        assertLe(uint256(w5[4]), uint256(w4[1]));
    }

    function test_weightsForRegime5_xHypeNeverExceedsOriginalkHype_weak() public view {
        uint16[4] memory w4 = rd.weightsForRegime(RegimeId.FUNDING_WEAK);
        uint16[5] memory w5 = rd.weightsForRegime5(RegimeId.FUNDING_WEAK);
        assertLe(uint256(w5[4]), uint256(w4[1]));
    }

    function test_weightsForRegime5_xHypeNeverExceedsOriginalkHype_neg() public view {
        uint16[4] memory w4 = rd.weightsForRegime(RegimeId.FUNDING_NEG);
        uint16[5] memory w5 = rd.weightsForRegime5(RegimeId.FUNDING_NEG);
        assertLe(uint256(w5[4]), uint256(w4[1]));
    }

    function test_weightsForRegime5_xHypeNeverExceedsOriginalkHype_highVol() public view {
        uint16[4] memory w4 = rd.weightsForRegime(RegimeId.HIGH_VOL);
        uint16[5] memory w5 = rd.weightsForRegime5(RegimeId.HIGH_VOL);
        assertLe(uint256(w5[4]), uint256(w4[1]));
    }

    // ---- xHYPE strictly drains kHYPE ----

    function test_weightsForRegime5_kHypeShrinksByXHype_strong() public view {
        uint16[4] memory w4 = rd.weightsForRegime(RegimeId.FUNDING_STRONG);
        uint16[5] memory w5 = rd.weightsForRegime5(RegimeId.FUNDING_STRONG);
        // 4-leg kHYPE = 1000, 5-leg kHYPE = 400, xHYPE = 600.
        assertEq(uint256(w4[1]), uint256(w5[1]) + w5[4]);
    }

    function test_weightsForRegime5_kHypeShrinksByXHype_weak() public view {
        uint16[4] memory w4 = rd.weightsForRegime(RegimeId.FUNDING_WEAK);
        uint16[5] memory w5 = rd.weightsForRegime5(RegimeId.FUNDING_WEAK);
        // 4-leg kHYPE = 2000, 5-leg kHYPE = 800, xHYPE = 1200.
        assertEq(uint256(w4[1]), uint256(w5[1]) + w5[4]);
    }

    function test_weightsForRegime5_kHypeShrinksByXHype_neg() public view {
        uint16[4] memory w4 = rd.weightsForRegime(RegimeId.FUNDING_NEG);
        uint16[5] memory w5 = rd.weightsForRegime5(RegimeId.FUNDING_NEG);
        // 4-leg kHYPE = 6000, 5-leg kHYPE = 2400, xHYPE = 3600.
        assertEq(uint256(w4[1]), uint256(w5[1]) + w5[4]);
    }

    function test_weightsForRegime5_kHypeShrinksByXHype_highVol() public view {
        uint16[4] memory w4 = rd.weightsForRegime(RegimeId.HIGH_VOL);
        uint16[5] memory w5 = rd.weightsForRegime5(RegimeId.HIGH_VOL);
        // 4-leg kHYPE = 5000, 5-leg kHYPE = 2000, xHYPE = 3000.
        assertEq(uint256(w4[1]), uint256(w5[1]) + w5[4]);
    }

    // ---- Spot / perp / basis buckets UNCHANGED across 4→5 leg ----

    function test_weightsForRegime5_otherBucketsUnchanged_strong() public view {
        uint16[4] memory w4 = rd.weightsForRegime(RegimeId.FUNDING_STRONG);
        uint16[5] memory w5 = rd.weightsForRegime5(RegimeId.FUNDING_STRONG);
        assertEq(w5[0], w4[0]); // spot
        assertEq(w5[2], w4[2]); // perpFunding
        assertEq(w5[3], w4[3]); // basisHedge
    }

    function test_weightsForRegime5_otherBucketsUnchanged_weak() public view {
        uint16[4] memory w4 = rd.weightsForRegime(RegimeId.FUNDING_WEAK);
        uint16[5] memory w5 = rd.weightsForRegime5(RegimeId.FUNDING_WEAK);
        assertEq(w5[0], w4[0]);
        assertEq(w5[2], w4[2]);
        assertEq(w5[3], w4[3]);
    }

    function test_weightsForRegime5_otherBucketsUnchanged_neg() public view {
        uint16[4] memory w4 = rd.weightsForRegime(RegimeId.FUNDING_NEG);
        uint16[5] memory w5 = rd.weightsForRegime5(RegimeId.FUNDING_NEG);
        assertEq(w5[0], w4[0]);
        assertEq(w5[2], w4[2]);
        assertEq(w5[3], w4[3]);
    }

    function test_weightsForRegime5_otherBucketsUnchanged_highVol() public view {
        uint16[4] memory w4 = rd.weightsForRegime(RegimeId.HIGH_VOL);
        uint16[5] memory w5 = rd.weightsForRegime5(RegimeId.HIGH_VOL);
        assertEq(w5[0], w4[0]);
        assertEq(w5[2], w4[2]);
        assertEq(w5[3], w4[3]);
    }

    // ---- XHYPE_WEIGHT_BPS accessor matches the 5-tuple ----

    function test_XHYPEWeightBps_matchesWeights5thSlot_strong() public view {
        uint16[5] memory w = rd.weightsForRegime5(RegimeId.FUNDING_STRONG);
        assertEq(uint256(rd.XHYPE_WEIGHT_BPS(RegimeId.FUNDING_STRONG)), uint256(w[4]));
    }

    function test_XHYPEWeightBps_matchesWeights5thSlot_weak() public view {
        uint16[5] memory w = rd.weightsForRegime5(RegimeId.FUNDING_WEAK);
        assertEq(uint256(rd.XHYPE_WEIGHT_BPS(RegimeId.FUNDING_WEAK)), uint256(w[4]));
    }

    function test_XHYPEWeightBps_matchesWeights5thSlot_neg() public view {
        uint16[5] memory w = rd.weightsForRegime5(RegimeId.FUNDING_NEG);
        assertEq(uint256(rd.XHYPE_WEIGHT_BPS(RegimeId.FUNDING_NEG)), uint256(w[4]));
    }

    function test_XHYPEWeightBps_matchesWeights5thSlot_highVol() public view {
        uint16[5] memory w = rd.weightsForRegime5(RegimeId.HIGH_VOL);
        assertEq(uint256(rd.XHYPE_WEIGHT_BPS(RegimeId.HIGH_VOL)), uint256(w[4]));
    }

    // ---- Exact expected vectors (regression guards) ----

    function test_weightsForRegime5_strongExactVector() public view {
        uint16[5] memory w = rd.weightsForRegime5(RegimeId.FUNDING_STRONG);
        assertEq(uint256(w[0]), 0);
        assertEq(uint256(w[1]), 400);
        assertEq(uint256(w[2]), 6000);
        assertEq(uint256(w[3]), 3000);
        assertEq(uint256(w[4]), 600);
    }

    function test_weightsForRegime5_weakExactVector() public view {
        uint16[5] memory w = rd.weightsForRegime5(RegimeId.FUNDING_WEAK);
        assertEq(uint256(w[0]), 2000);
        assertEq(uint256(w[1]), 800);
        assertEq(uint256(w[2]), 4000);
        assertEq(uint256(w[3]), 2000);
        assertEq(uint256(w[4]), 1200);
    }

    function test_weightsForRegime5_negExactVector() public view {
        uint16[5] memory w = rd.weightsForRegime5(RegimeId.FUNDING_NEG);
        assertEq(uint256(w[0]), 4000);
        assertEq(uint256(w[1]), 2400);
        assertEq(uint256(w[2]), 0);
        assertEq(uint256(w[3]), 0);
        assertEq(uint256(w[4]), 3600);
    }

    function test_weightsForRegime5_highVolExactVector() public view {
        uint16[5] memory w = rd.weightsForRegime5(RegimeId.HIGH_VOL);
        assertEq(uint256(w[0]), 5000);
        assertEq(uint256(w[1]), 2000);
        assertEq(uint256(w[2]), 0);
        assertEq(uint256(w[3]), 0);
        assertEq(uint256(w[4]), 3000);
    }

    // ---- Monotonic migration ----

    /// Ordering rule: as funding pressure moves from STRONG → WEAK →
    /// NEG, the perpFunding weight drops and the xHYPE weight
    /// increases monotonically (because HYPE yield replaces perp
    /// carry once funding turns negative). HIGH_VOL is orthogonal to
    /// funding pressure and is checked separately.
    function test_xHypeWeightMonotonic_acrossFundingRegimes() public view {
        uint16 strong = rd.XHYPE_WEIGHT_BPS(RegimeId.FUNDING_STRONG);
        uint16 weak = rd.XHYPE_WEIGHT_BPS(RegimeId.FUNDING_WEAK);
        uint16 neg = rd.XHYPE_WEIGHT_BPS(RegimeId.FUNDING_NEG);

        // 600 → 1200 → 3600: strictly monotonic increasing as funding
        // pressure moves from strong → weak → negative.
        assertLt(strong, weak);
        assertLt(weak, neg);
    }

    /// Perp weight is monotonic DECREASING as funding pressure
    /// moves STRONG → WEAK → NEG (perp carry fades as funding turns
    /// negative; xHYPE picks up the marginal bps).
    function test_perpWeightMonotonic_acrossFundingRegimes() public view {
        uint16[5] memory wStrong = rd.weightsForRegime5(RegimeId.FUNDING_STRONG);
        uint16[5] memory wWeak = rd.weightsForRegime5(RegimeId.FUNDING_WEAK);
        uint16[5] memory wNeg = rd.weightsForRegime5(RegimeId.FUNDING_NEG);

        assertGt(wStrong[2], wWeak[2]);
        assertGt(wWeak[2], wNeg[2]);
        assertEq(wNeg[2], 0);
    }

    /// xHYPE weight strictly DECREASES from WEAK to STRONG (perp
    /// captures more of the marginal bps when funding is strong).
    function test_xHypeWeight_decreasesWhenFundingStrengthens() public view {
        uint16 strong = rd.XHYPE_WEIGHT_BPS(RegimeId.FUNDING_STRONG);
        uint16 weak = rd.XHYPE_WEIGHT_BPS(RegimeId.FUNDING_WEAK);
        assertLt(strong, weak);
    }

    /// HIGH_VOL is defensible-only: both perp and basis go to 0, but
    /// the xHYPE allocation still exists (never collapses to 0).
    function test_xHypeWeight_survivesHighVol() public view {
        uint16 highVol = rd.XHYPE_WEIGHT_BPS(RegimeId.HIGH_VOL);
        assertGt(highVol, 0);
    }

    /// Sanity: every regime yields xHYPE > 0 (the whole point of A3
    /// is that xHYPE is the default HYPE vehicle, so any regime
    /// without xHYPE would be a bug).
    function test_xHypeWeight_positiveInEveryRegime() public view {
        assertGt(rd.XHYPE_WEIGHT_BPS(RegimeId.FUNDING_STRONG), 0);
        assertGt(rd.XHYPE_WEIGHT_BPS(RegimeId.FUNDING_WEAK), 0);
        assertGt(rd.XHYPE_WEIGHT_BPS(RegimeId.FUNDING_NEG), 0);
        assertGt(rd.XHYPE_WEIGHT_BPS(RegimeId.HIGH_VOL), 0);
    }

    // ---- Regression: 4-leg weights unchanged (backwards compat) ----

    function test_weightsForRegime_legacy4LegUnchanged_strong() public view {
        uint16[4] memory w = rd.weightsForRegime(RegimeId.FUNDING_STRONG);
        assertEq(uint256(w[0]), 0);
        assertEq(uint256(w[1]), 1000);
        assertEq(uint256(w[2]), 6000);
        assertEq(uint256(w[3]), 3000);
    }

    function test_weightsForRegime_legacy4LegUnchanged_weak() public view {
        uint16[4] memory w = rd.weightsForRegime(RegimeId.FUNDING_WEAK);
        assertEq(uint256(w[0]), 2000);
        assertEq(uint256(w[1]), 2000);
        assertEq(uint256(w[2]), 4000);
        assertEq(uint256(w[3]), 2000);
    }

    function test_weightsForRegime_legacy4LegUnchanged_neg() public view {
        uint16[4] memory w = rd.weightsForRegime(RegimeId.FUNDING_NEG);
        assertEq(uint256(w[0]), 4000);
        assertEq(uint256(w[1]), 6000);
        assertEq(uint256(w[2]), 0);
        assertEq(uint256(w[3]), 0);
    }

    function test_weightsForRegime_legacy4LegUnchanged_highVol() public view {
        uint16[4] memory w = rd.weightsForRegime(RegimeId.HIGH_VOL);
        assertEq(uint256(w[0]), 5000);
        assertEq(uint256(w[1]), 5000);
        assertEq(uint256(w[2]), 0);
        assertEq(uint256(w[3]), 0);
    }
}
