// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {HyperCoreTypes} from "./types.sol";
import {IHyperCorePrecompile} from "./IHyperCorePrecompile.sol";

/**
 * @title HyperCoreSnapshotMock
 * @notice A REPLAY-ONLY mock of the precompile, built for reproducibility.
 *
 * Motivation:
 *   `HyperCorePrecompileMock` is stateful — tests call setCandles /
 *   setFunding / setMarketData during execution. That is convenient for
 *   ad-hoc unit tests but makes it easy to write flaky tests that only
 *   pass when setUp() runs in a specific order. `HyperCoreSnapshotMock`
 *   inverts that: you hand it a frozen snapshot in the constructor, and
 *   from then on it is READ-ONLY.
 *
 *   Use cases:
 *     1. Regression tests that must produce identical output year over
 *        year — build the snapshot once from a checked-in JSON file and
 *        the test is fully deterministic regardless of the current time.
 *     2. `fork`-style tests where you want a known-good market state
 *        without paying for an HTTP call to Hyperliquid each run.
 *     3. Fuzz harnesses that need a fixed corpus.
 *
 * Snapshot data is passed as `SnapshotInput` structs (below) — one per
 * coin. Each input bundles all candles (across intervals), all funding
 * ticks, and the latest market data.
 *
 * ORDERING: `candleSnapshot` and `fundingSnapshot` return data in
 * storage order. Callers SHOULD pass candles and funding entries
 * sorted ascending by `startTime` / `timestamp`. This matches what the
 * stateful mock produces and what the real precompile will return.
 * Sorting is a constructor-time concern because Solidity cannot
 * enumerate storage keys to discover the coin set — the caller (or a
 * fixture generator script) is responsible for ordering the inputs.
 *
 * `advanceBy`: shifts the effective "now" forward by a fixed number of
 * seconds. Only affects `marketData().timestamp`. Useful when a test
 * compares `marketData().timestamp` against `block.timestamp` (e.g. in
 * a RegimeDetector that records `observedAt`). Ignored for candles and
 * funding.
 */

interface SnapshotInput {
    struct CandleEntry {
        string coin;
        string interval;
        HyperCoreTypes.Candle candle;
    }

    struct FundingEntry {
        string coin;
        HyperCoreTypes.FundingSnapshot tick;
    }

    struct MarketEntry {
        string coin;
        HyperCoreTypes.MarketData data;
    }
}

contract HyperCoreSnapshotMock is IHyperCorePrecompile {
    // Coin || interval -> candles (sorted ascending by startTime).
    mapping(bytes32 => HyperCoreTypes.Candle[]) internal _candles;
    // Coin -> funding ticks (sorted ascending by timestamp).
    mapping(bytes32 => HyperCoreTypes.FundingSnapshot[]) internal _funding;
    // Coin -> market data snapshot.
    mapping(bytes32 => HyperCoreTypes.MarketData) internal _marketData;

    uint256 internal _advanceSeconds;

    uint256 public immutable candleCount;
    uint256 public immutable fundingCount;
    uint256 public immutable marketCount;

    event SnapshotLoaded(
        uint256 indexed candles,
        uint256 indexed funding,
        uint256 indexed marketData
    );

    constructor(
        SnapshotInput.CandleEntry[] memory candles,
        SnapshotInput.FundingEntry[] memory funding,
        SnapshotInput.MarketEntry[] memory market
    ) {
        candleCount = candles.length;
        fundingCount = funding.length;
        marketCount = market.length;

        // --- Candles: push each entry in input order. We don't
        // pre-allocate because Solidity 0.8.26 doesn't support
        // array-of-structs-of-structs memory → storage copies.
        for (uint256 i = 0; i < candles.length; i++) {
            SnapshotInput.CandleEntry memory e = candles[i];
            bytes32 k = keccak256(abi.encodePacked(e.coin, "||", e.interval));
            HyperCoreTypes.Candle memory c = e.candle;
            _candles[k].push(HyperCoreTypes.Candle({
                open: c.open, high: c.high,
                low: c.low, close: c.close,
                startTime: c.startTime, endTime: c.endTime,
                volume: c.volume
            }));
        }

        // --- Funding: same pattern ---
        for (uint256 i = 0; i < funding.length; i++) {
            SnapshotInput.FundingEntry memory e = funding[i];
            bytes32 k = bytes32(bytes(e.coin));
            HyperCoreTypes.FundingSnapshot memory t = e.tick;
            _funding[k].push(HyperCoreTypes.FundingSnapshot({
                fundingRate: t.fundingRate,
                oi: t.oi,
                timestamp: t.timestamp
            }));
        }

        // --- Market data: single snapshot per coin; last write wins. ---
        for (uint256 i = 0; i < market.length; i++) {
            SnapshotInput.MarketEntry memory e = market[i];
            HyperCoreTypes.MarketData memory m = e.data;
            _marketData[bytes32(bytes(e.coin))] = HyperCoreTypes.MarketData({
                spotPrice: m.spotPrice,
                oraclePrice: m.oraclePrice,
                timestamp: m.timestamp
            });
        }

        emit SnapshotLoaded(candleCount, fundingCount, marketCount);
    }

    // ---- precompile interface ----

    function candleSnapshot(
        string calldata coin,
        string calldata interval,
        uint256 startTime,
        uint256 endTime
    ) external view override returns (HyperCoreTypes.Candle[] memory) {
        bytes32 k = keccak256(abi.encodePacked(coin, "||", interval));
        HyperCoreTypes.Candle[] storage all = _candles[k];
        if (all.length == 0) return new HyperCoreTypes.Candle[](0);
        HyperCoreTypes.Candle[] memory out = new HyperCoreTypes.Candle[](all.length);
        uint256 j = 0;
        for (uint256 i = 0; i < all.length; i++) {
            uint256 t0 = uint256(all[i].startTime);
            uint256 t1 = uint256(all[i].endTime);
            if (t0 >= startTime && t1 <= endTime) {
                out[j] = HyperCoreTypes.Candle({
                    open: all[i].open, high: all[i].high,
                    low: all[i].low, close: all[i].close,
                    startTime: all[i].startTime,
                    endTime: all[i].endTime,
                    volume: all[i].volume
                });
                j++;
            }
        }
        if (j == all.length) return out;
        HyperCoreTypes.Candle[] memory trimmed = new HyperCoreTypes.Candle[](j);
        for (uint256 i = 0; i < j; i++) trimmed[i] = out[i];
        return trimmed;
    }

    function fundingSnapshot(
        string calldata coin,
        uint256 count
    ) external view override returns (HyperCoreTypes.FundingSnapshot[] memory) {
        bytes32 k = bytes32(bytes(coin));
        HyperCoreTypes.FundingSnapshot[] storage all = _funding[k];
        if (all.length == 0 || count == 0) {
            return new HyperCoreTypes.FundingSnapshot[](0);
        }
        uint256 take = count < all.length ? count : all.length;
        HyperCoreTypes.FundingSnapshot[] memory out =
            new HyperCoreTypes.FundingSnapshot[](take);
        uint256 start = all.length - take;
        for (uint256 i = 0; i < take; i++) {
            HyperCoreTypes.FundingSnapshot storage src = all[start + i];
            out[i] = HyperCoreTypes.FundingSnapshot({
                fundingRate: src.fundingRate,
                oi: src.oi,
                timestamp: src.timestamp
            });
        }
        return out;
    }

    function marketData(string calldata coin)
        external view override returns (HyperCoreTypes.MarketData memory)
    {
        bytes32 k = bytes32(bytes(coin));
        HyperCoreTypes.MarketData storage m = _marketData[k];
        return HyperCoreTypes.MarketData({
            spotPrice: m.spotPrice,
            oraclePrice: m.oraclePrice,
            timestamp: uint64(uint256(m.timestamp) + _advanceSeconds)
        });
    }

    // ---- time-shift helpers ----

    /// Shift the effective "now" forward by `secs` seconds. Only
    /// affects `marketData().timestamp`; candles and funding are
    /// unaffected. Use to test RegimeDetector against a known
    /// observed-at value.
    function advanceBy(uint256 secs) external {
        _advanceSeconds += secs;
    }

    /// Current time-shift applied to `marketData().timestamp`.
    function currentAdvance() external view returns (uint256) {
        return _advanceSeconds;
    }

    /// Test-only introspection: has any data been loaded for `coin`?
    function hasCoin(string calldata coin) external view returns (bool) {
        bytes32 k = bytes32(bytes(coin));
        return _marketData[k].timestamp != 0
            || _funding[k].length > 0;
    }

    /// Test-only introspection: candle count for a (coin, interval).
    function candlesCount(string calldata coin, string calldata interval)
        external view returns (uint256)
    {
        return _candles[keccak256(abi.encodePacked(coin, "||", interval))].length;
    }

    /// Test-only introspection: funding tick count for a coin.
    function fundingCountForCoin(string calldata coin)
        external view returns (uint256)
    {
        return _funding[bytes32(bytes(coin))].length;
    }
}
