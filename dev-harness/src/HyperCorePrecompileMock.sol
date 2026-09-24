// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {HyperCoreTypes} from "./types.sol";
import {IHyperCorePrecompile} from "./IHyperCorePrecompile.sol";

/**
 * @title HyperCorePrecompileMock
 * @notice State-manipulable mock of the HyperCore market-data precompile.
 *
 * Usage in a test:
 *     HyperCorePrecompileMock pc = new HyperCorePrecompileMock();
 *
 *     HyperCoreTypes.Candle[] memory candles = new HyperCoreTypes.Candle[](2);
 *     candles[0] = HyperCoreTypes.Candle(int64(100e6), int64(110e6),
 *             int64(90e6), int64(105e6), 1_700_000_000, 1_700_000_060, int64(500));
 *     candles[1] = HyperCoreTypes.Candle(int64(105e6), int64(120e6),
 *             int64(100e6), int64(115e6), 1_700_000_060, 1_700_000_120, int64(700));
 *     pc.setCandles("HYPE/USDC", "1h", candles);
 *
 *     HyperCoreTypes.Candle[] memory back =
 *         pc.candleSnapshot("HYPE/USDC", "1h", 0, type(uint256).max);
 *     assertEq(back.length, 2);
 *
 * Key properties:
 *   - Data is keyed by (coin, interval) for candles, coin for funding
 *     and market data. Different coins never cross-contaminate.
 *   - `candleSnapshot` respects the [startTime, endTime] window and
 *     returns only candles whose startTime is in-range. Sorting is
 *     ascending by startTime, matching real precompile behaviour.
 *   - `fundingSnapshot` returns the LAST `count` records (most recent
 *     `count` first, sorted ascending by timestamp).
 *   - `marketData` returns a zero-value for coins that were never
 *     primed, so callers can distinguish "empty" from "reverted".
 *   - `resetCoin` clears everything for one coin — useful in `setUp()`.
 *
 * IMPLEMENTATION NOTES:
 *   Solidity 0.8.26 does not support implicit memory→storage copies
 *   of arrays of structs. We therefore push each element individually
 *   into the storage array and sort in storage via swap-based
 *   insertion sort. The helper `_cMem(...)` / `_fMem(...)` functions
 *   return fresh memory copies so storage slots stay well-defined.
 */
contract HyperCorePrecompileMock is IHyperCorePrecompile {
    // Coin || interval -> candles (stored ascending by startTime).
    mapping(bytes32 => HyperCoreTypes.Candle[]) internal _candles;
    // Coin -> funding ticks (stored ascending by timestamp).
    mapping(bytes32 => HyperCoreTypes.FundingSnapshot[]) internal _funding;
    // Coin -> market data snapshot.
    mapping(bytes32 => HyperCoreTypes.MarketData) internal _marketData;
    // Track whether marketData has been set at all for a coin so the
    // zero-value sentinel is distinguishable from "set but zero".
    mapping(bytes32 => bool) internal _hasMarketData;

    // ---- test setup (external) ----

    function setCandles(
        string calldata coin,
        string calldata interval,
        HyperCoreTypes.Candle[] calldata data
    ) external {
        bytes32 k = _key(coin, interval);
        delete _candles[k];
        for (uint256 i = 0; i < data.length; i++) {
            HyperCoreTypes.Candle calldata d = data[i];
            _candles[k].push(HyperCoreTypes.Candle({
                open: d.open, high: d.high, low: d.low, close: d.close,
                startTime: d.startTime, endTime: d.endTime, volume: d.volume
            }));
        }
        _insertionSortCandleStorage(_candles[k]);
    }

    function setFunding(
        string calldata coin,
        HyperCoreTypes.FundingSnapshot[] calldata data
    ) external {
        bytes32 k = _coinKey(coin);
        delete _funding[k];
        for (uint256 i = 0; i < data.length; i++) {
            HyperCoreTypes.FundingSnapshot calldata s = data[i];
            _funding[k].push(HyperCoreTypes.FundingSnapshot({
                fundingRate: s.fundingRate, oi: s.oi, timestamp: s.timestamp
            }));
        }
        _insertionSortFundingStorage(_funding[k]);
    }

    function setMarketData(string calldata coin, HyperCoreTypes.MarketData calldata d)
        external
    {
        bytes32 k = _coinKey(coin);
        _marketData[k] = HyperCoreTypes.MarketData({
            spotPrice: d.spotPrice,
            oraclePrice: d.oraclePrice,
            timestamp: d.timestamp
        });
        _hasMarketData[k] = true;
    }

    /// Convenience: prime funding + market data from a single candles
    /// fixture — useful when you only want to hand-write candles.
    /// Each candle produces one funding tick at `startTime` with the
    /// current close as the oracle/spot price.
    function setCandlesAndDeriveFunding(
        string calldata coin,
        string calldata interval,
        HyperCoreTypes.Candle[] calldata data
    ) external {
        bytes32 ck = _key(coin, interval);
        delete _candles[ck];
        for (uint256 i = 0; i < data.length; i++) {
            HyperCoreTypes.Candle calldata d = data[i];
            _candles[ck].push(HyperCoreTypes.Candle({
                open: d.open, high: d.high, low: d.low, close: d.close,
                startTime: d.startTime, endTime: d.endTime, volume: d.volume
            }));
        }
        _insertionSortCandleStorage(_candles[ck]);

        bytes32 fk = _coinKey(coin);
        delete _funding[fk];
        for (uint256 i = 0; i < data.length; i++) {
            _funding[fk].push(HyperCoreTypes.FundingSnapshot({
                fundingRate: data[i].close,
                oi: data[i].volume,
                timestamp: data[i].startTime
            }));
        }
        _insertionSortFundingStorage(_funding[fk]);

        if (data.length > 0) {
            HyperCoreTypes.Candle calldata last = data[data.length - 1];
            _marketData[fk] = HyperCoreTypes.MarketData({
                spotPrice: last.close,
                oraclePrice: last.close,
                timestamp: last.endTime
            });
            _hasMarketData[fk] = true;
        }
    }

    function resetCoin(string calldata coin) external {
        bytes32 ck = _coinKey(coin);
        delete _funding[ck];
        delete _marketData[ck];
        delete _hasMarketData[ck];
        string[] memory intervals = new string[](7);
        intervals[0] = "1m";
        intervals[1] = "5m";
        intervals[2] = "15m";
        intervals[3] = "1h";
        intervals[4] = "4h";
        intervals[5] = "1d";
        intervals[6] = "1w";
        for (uint256 i = 0; i < intervals.length; i++) {
            bytes32 ivk = keccak256(abi.encodePacked(coin, "||", intervals[i]));
            delete _candles[ivk];
        }
    }

    // ---- precompile interface impl ----

    function candleSnapshot(
        string calldata coin,
        string calldata interval,
        uint256 startTime,
        uint256 endTime
    ) external view override returns (HyperCoreTypes.Candle[] memory) {
        bytes32 k = _key(coin, interval);
        HyperCoreTypes.Candle[] storage all = _candles[k];
        if (all.length == 0) return new HyperCoreTypes.Candle[](0);
        uint256 n = 0;
        for (uint256 i = 0; i < all.length; i++) {
            // Match on startTime being within [startTime, endTime] —
            // this is the standard convention: "give me candles that
            // start in this window". Using startTime+endTime would
            // require the candle to be fully inside the window, which
            // is stricter than callers typically expect.
            uint256 t0 = uint256(all[i].startTime);
            if (t0 >= startTime && t0 <= endTime) n++;
        }
        HyperCoreTypes.Candle[] memory out = new HyperCoreTypes.Candle[](n);
        uint256 j = 0;
        for (uint256 i = 0; i < all.length; i++) {
            uint256 t0 = uint256(all[i].startTime);
            if (t0 >= startTime && t0 <= endTime) {
                out[j] = _cMem(all[i]);
                j++;
            }
        }
        return out;
    }

    function fundingSnapshot(
        string calldata coin,
        uint256 count
    ) external view override returns (HyperCoreTypes.FundingSnapshot[] memory) {
        bytes32 k = _coinKey(coin);
        HyperCoreTypes.FundingSnapshot[] storage all = _funding[k];
        if (all.length == 0 || count == 0) {
            return new HyperCoreTypes.FundingSnapshot[](0);
        }
        uint256 take = count < all.length ? count : all.length;
        HyperCoreTypes.FundingSnapshot[] memory out =
            new HyperCoreTypes.FundingSnapshot[](take);
        uint256 start = all.length - take;
        for (uint256 i = 0; i < take; i++) out[i] = _fMem(all[start + i]);
        return out;
    }

    function marketData(string calldata coin)
        external view override returns (HyperCoreTypes.MarketData memory)
    {
        bytes32 k = _coinKey(coin);
        HyperCoreTypes.MarketData storage m = _marketData[k];
        return HyperCoreTypes.MarketData({
            spotPrice: m.spotPrice,
            oraclePrice: m.oraclePrice,
            timestamp: m.timestamp
        });
    }

    function hasMarketData(string calldata coin) external view returns (bool) {
        return _hasMarketData[_coinKey(coin)];
    }

    function candlesCount(string calldata coin, string calldata interval)
        external view returns (uint256)
    {
        return _candles[_key(coin, interval)].length;
    }

    function fundingCount(string calldata coin) external view returns (uint256) {
        return _funding[_coinKey(coin)].length;
    }

    // ---- key + copy helpers ----

    function _key(string calldata coin, string calldata interval)
        internal pure returns (bytes32)
    {
        return keccak256(abi.encodePacked(coin, "||", interval));
    }

    function _coinKey(string calldata coin) internal pure returns (bytes32) {
        return bytes32(bytes(coin));
    }

    // storage → memory copies (view because reading storage).
    function _cMem(HyperCoreTypes.Candle storage c)
        internal view returns (HyperCoreTypes.Candle memory)
    {
        return HyperCoreTypes.Candle({
            open: c.open, high: c.high, low: c.low, close: c.close,
            startTime: c.startTime, endTime: c.endTime, volume: c.volume
        });
    }

    function _fMem(HyperCoreTypes.FundingSnapshot storage s)
        internal view returns (HyperCoreTypes.FundingSnapshot memory)
    {
        return HyperCoreTypes.FundingSnapshot({
            fundingRate: s.fundingRate, oi: s.oi, timestamp: s.timestamp
        });
    }

    // ---- insertion sort, in storage ----

    function _insertionSortCandleStorage(HyperCoreTypes.Candle[] storage a)
        private
    {
        uint256 n = a.length;
        for (uint256 i = 1; i < n; i++) {
            HyperCoreTypes.Candle memory cur = _cMem(a[i]);
            uint256 j = i;
            while (j > 0 && uint256(a[j - 1].startTime) > uint256(cur.startTime)) {
                a[j] = _cMem(a[j - 1]);
                j--;
            }
            a[j] = cur;
        }
    }

    function _insertionSortFundingStorage(
        HyperCoreTypes.FundingSnapshot[] storage a
    ) private {
        uint256 n = a.length;
        for (uint256 i = 1; i < n; i++) {
            HyperCoreTypes.FundingSnapshot memory cur = _fMem(a[i]);
            uint256 j = i;
            while (j > 0 && uint256(a[j - 1].timestamp) > uint256(cur.timestamp)) {
                a[j] = _fMem(a[j - 1]);
                j--;
            }
            a[j] = cur;
        }
    }
}
