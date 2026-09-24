// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

/**
 * @title HyperCoreTypes
 * @notice Shared struct definitions for the HyperCore market-data precompile.
 *
 * Value conventions:
 *   - Prices (open/high/low/close/spot/oracle) are scaled by 1e6, matching
 *     Hyperliquid's `spot_candles` wire format (6-decimal).
 *   - Funding rates (fundingRate) are int64, also scaled by 1e6. A value of
 *     1_000_000 therefore represents a 100% rate. Downstream consumers that
 *     want annualised bps (as RegimeDetector expects) need to rescale.
 *   - Volumes are int64 for symmetry with the Hyperliquid wire format
 *     (`v` = base volume). Real markets could produce values larger than
 *     int64 in principle but this is not a concern for the mock; callers
 *     should clamp before pushing data into a fixture.
 *   - Timestamps are unix SECONDS (not milliseconds). This matches the
 *     Elysium precompile spec note in hypeback/hypercore.py ("startTime:
 *     unix seconds"). The Hyperliquid HTTP API uses milliseconds; the
 *     adapter and fixture generators normalise to seconds at the boundary.
 */
library HyperCoreTypes {
    /// Single OHLCV bar. See doc block at top for scaling conventions.
    struct Candle {
        int64  open;
        int64  high;
        int64  low;
        int64  close;
        uint64 startTime; // unix seconds
        uint64 endTime;   // unix seconds
        int64  volume;
    }

    /// One funding tick. `fundingRate` and `oi` are int64-scaled (1e6).
    struct FundingSnapshot {
        int64  fundingRate;
        int64  oi;
        uint64 timestamp; // unix seconds
    }

    /// Latest market data for a coin. Prices are int64 (1e6-scaled).
    struct MarketData {
        int64  spotPrice;
        int64  oraclePrice;
        uint64 timestamp; // unix seconds
    }
}
