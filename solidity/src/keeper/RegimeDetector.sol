// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title RegimeDetector
 * @notice On-chain observer that reads HyperCore funding data via the
 *         Elysium market-data precompile and classifies the current
 *         funding regime.
 *
 * This contract is read-only: it stores state but never moves funds.
 * YieldAggregator reads `current()` to drive allocation changes.
 *
 * Precompile stub: the actual Elysium market-data precompile address
 * and ABI ship ~4 weeks post-mainnet (see docs/AGGREGATOR_SPEC.md §2).
 * Until then, this contract uses the `IMarketDataFeed` interface —
 * production deployment must override the constructor argument to point
 * at the real precompile.
 */
interface IMarketDataFeed {
    /** Funding rate (bps, signed via int64) for a given perp coin. */
    function fundingRateBps(string calldata coin) external view returns (int64);

    /** Realized vol over trailing hours, bps of 10000. */
    function realizedVolBps(string calldata coin, uint32 lookbackHrs)
        external view returns (uint256)
    ;

    /** Spot price of HYPE in USDC (6 decimals). */
    function spotPrice(string calldata coin) external view returns (uint256);

    /** Mark price of HYPE perp (6 decimals). */
    function perpMarkPrice(string calldata coin) external view returns (uint256);
}

/** Funding regime enumeration — matches docs/AGGREGATOR_SPEC.md §3.4. */
library RegimeId {
    uint8 constant FUNDING_STRONG = 0;
    uint8 constant FUNDING_WEAK = 1;
    uint8 constant FUNDING_NEG = 2;
    uint8 constant HIGH_VOL = 3;
}

contract RegimeDetector {
    using RegimeId for uint8;

    /// @dev thresholds are tunable via setThresholds() (governance).
    uint256 public constant BPS_DENOM = 10_000;

    struct RegimeSnapshot {
        uint8 regime;
        uint256 fundingApyBps_24h;
        uint256 hypeVolBps_24h;
        uint256 basisBps;
        uint64 observedAt;
    }

    struct Thresholds {
        uint256 strongApyBps;  // 8% = 800 bps
        uint256 weakApyBps;    // 3% = 300 bps
        uint256 highVolBps;    // 90% = 9000 bps
    }

    address public immutable marketDataFeed;
    address public immutable owner;
    Thresholds public thresholds;
    RegimeSnapshot public lastSnapshot;

    event RegimeUpdated(uint8 indexed regime, uint256 fundingApyBps, uint64 ts);
    event ThresholdsUpdated(uint256 strongApyBps, uint256 weakApyBps, uint256 highVolBps);

    modifier onlyOwner() { require(msg.sender == owner, "not owner"); _; }

    constructor(address _marketDataFeed) {
        require(_marketDataFeed != address(0), "zero feed");
        marketDataFeed = _marketDataFeed;
        owner = msg.sender;
        thresholds = Thresholds(800, 300, 9000);
    }

    /**
     * Change the regime classification thresholds.
     *
     * Owner-only. The original implementation was open to anyone, which
     * was a real griefing vector — a random caller could set
     * `strongApyBps = 0` and force every observation to classify as
     * FUNDING_STRONG, which pushes 60% of vault assets into perp
     * funding. Compromising thresholds would then silently steer
     * allocation without triggering the aggregator's role gate on
     * `requestAllocation`. Round-3 fix, 2026-09-23.
     */
    function setThresholds(Thresholds calldata t) external onlyOwner {
        require(t.strongApyBps >= t.weakApyBps, "bad threshold order");
        thresholds = t;
        emit ThresholdsUpdated(t.strongApyBps, t.weakApyBps, t.highVolBps);
    }

    /**
     * Compute current regime from market data and store it.
     * Emits RegimeUpdated only if the regime actually changed.
     */
    function observe() external {
        IMarketDataFeed feed = IMarketDataFeed(marketDataFeed);
        // The market data precompile returns hourly funding rate in bps
        // (int64). Annualise by multiplying by 24 * 365 = 8760.
        //
        // Round-9 hardening (finding #7): Solidity 0.8 does NOT
        // overflow-check signed `*` for non-constant-folded expressions,
        // so a hostile feed value `hourlyFundingBps > ~2.5e14` would
        // silently wrap around INT64_MAX. That could flip a positive
        // regime to FUNDING_NEG (or vice versa) without any revert,
        // steering allocation. We now saturate to INT64_MAX/MIN so a
        // hostile feed can only push the regime to an extreme — never
        // silently invert it.
        int64 hourlyFundingBps = feed.fundingRateBps("HYPE");
        int256 apyBpsInt = int256(hourlyFundingBps) * 8760;
        int64 apyBps;
        if (apyBpsInt > int256(type(int64).max)) {
            apyBps = type(int64).max;
        } else if (apyBpsInt < int256(type(int64).min)) {
            apyBps = type(int64).min;
        } else {
            apyBps = int64(apyBpsInt);
        }
        uint256 apyAbs = apyBps > 0 ? uint256(int256(apyBps)) : 0;
        int64 apySigned = apyBps;

        uint256 volBps = feed.realizedVolBps("HYPE", 24);

        // Basis: (perpMark - spot) / spot * 10000, in bps.
        //
        // Round-9 hardening (finding #8): the previous form
        // `(perp - spot) * BPS_DENOM / spot` underflowed on any
        // discount market (`perp < spot`), which Solidity 0.8 turns
        // into a revert — so `observe()` reverted on the most common
        // market state. We now handle the two cases in pure uint256
        // math: premium (perp >= spot) is computed directly, discount
        // (perp < spot) clamps to 0 to match the existing `uint256`
        // snapshot schema. A `signedBasisBps` field can be added later
        // without a storage migration because it would go at the end
        // of the struct.
        //
        // We still require spot != 0 to avoid a divide-by-zero panic
        // that Solidity would raise anyway, but we fail with a
        // recognisable revert string so a malformed feed is
        // distinguishable from an organic one.
        //
        // The numerator product is capped at uint256 max / BPS_DENOM
        // to prevent an overflow on absurd premiums — the threshold
        // corresponds to a price ratio of ~2^224× (perp is 2^224×
        // the spot), a magnitude no real market would ever see.
        uint256 perp = feed.perpMarkPrice("HYPE");
        uint256 spot = feed.spotPrice("HYPE");
        require(spot > 0, "zero spot");
        require(perp > 0, "zero perp");
        uint256 basisBps;
        if (perp >= spot) {
            uint256 diff = perp - spot;
            if (diff >= type(uint256).max / BPS_DENOM) {
                // diff * BPS_DENOM would overflow uint256. This means
                // the premium is larger than 2^224 * 10000 bps — a
                // value no real market would ever see. Cap to max
                // rather than silently wrap.
                basisBps = type(uint256).max;
            } else {
                basisBps = (diff * BPS_DENOM) / spot;
            }
        } else {
            // Discount market — clamp to 0 (see schema note above).
            basisBps = 0;
        }

        uint8 newRegime = computeRegime(apySigned, volBps);
        uint8 prevRegime = lastSnapshot.regime;
        lastSnapshot = RegimeSnapshot({
            regime: newRegime,
            fundingApyBps_24h: apyAbs,
            hypeVolBps_24h: volBps,
            basisBps: basisBps,
            observedAt: uint64(block.timestamp)
        });
        if (newRegime != prevRegime) {
            emit RegimeUpdated(newRegime, apyAbs, lastSnapshot.observedAt);
        }
    }

    function current() external view returns (RegimeSnapshot memory) {
        return lastSnapshot;
    }

    /** Compute regime without writing state (for tests). */
    function computeRegime(int64 apySigned, uint256 volBps) public view returns (uint8) {
        if (volBps >= thresholds.highVolBps) return RegimeId.HIGH_VOL;
        if (apySigned < 0) return RegimeId.FUNDING_NEG;
        if (apySigned > 0 && uint256(int256(apySigned)) >= thresholds.strongApyBps) return RegimeId.FUNDING_STRONG;
        if (apySigned > 0 && uint256(int256(apySigned)) >= thresholds.weakApyBps) return RegimeId.FUNDING_WEAK;
        return RegimeId.FUNDING_WEAK;
    }

    /** Allocation shift per regime, in basis points. */
    function weightsForRegime(uint8 regime) external pure returns (uint16[4] memory) {
        // [spot, khype, perpFunding, basisHedge]
        if (regime == RegimeId.FUNDING_STRONG) {
            return [uint16(0), uint16(1000), uint16(6000), uint16(3000)];
        } else if (regime == RegimeId.FUNDING_WEAK) {
            return [uint16(2000), uint16(2000), uint16(4000), uint16(2000)];
        } else if (regime == RegimeId.FUNDING_NEG) {
            return [uint16(4000), uint16(6000), uint16(0), uint16(0)];
        } else {
            return [uint16(5000), uint16(5000), uint16(0), uint16(0)];
        }
    }
}
