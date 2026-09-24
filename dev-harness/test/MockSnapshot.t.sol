// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import "@forge-std/Test.sol";
import {HyperCoreTypes} from "../src/types.sol";
import {HyperCorePrecompileMock} from "../src/HyperCorePrecompileMock.sol";

/**
 * MockSnapshot.t.sol — the mock returns exactly what you told it.
 *
 * Scope: pure unit tests for `HyperCorePrecompileMock`. No adapters,
 * no RegimeDetector, no cross-contract state. Just:
 *   setCandles → candleSnapshot returns the same
 *   setCandles(coinA) does not affect candleSnapshot(coinB)
 *   setCandles filters by time window
 *   setFunding → fundingSnapshot returns the last N
 *   setMarketData → marketData returns the same
 *   resetCoin clears only that coin
 */
contract MockSnapshotTest is Test {
    HyperCorePrecompileMock pc;

    // Fixed timestamps for reproducibility.
    uint64 constant T0 = 1_700_000_000; // ~2023-11-14
    uint64 constant HOUR = 3600;

    function setUp() public {
        pc = new HyperCorePrecompileMock();
    }

    function _price(int64 p) internal pure returns (int64) {
        return p * 1_000_000; // convenience: prices are 1e6-scaled
    }

    function _candle(
        int64 o, int64 h, int64 l, int64 c,
        uint64 t0, uint64 t1, int64 v
    ) internal pure returns (HyperCoreTypes.Candle memory) {
        return HyperCoreTypes.Candle({
            open: o, high: h, low: l, close: c,
            startTime: t0, endTime: t1, volume: v
        });
    }

    // ---- candleSnapshot ----

    function test_SetCandles_roundTrip_returnsSameData() public {
        HyperCoreTypes.Candle[] memory data = new HyperCoreTypes.Candle[](3);
        data[0] = _candle(_price(100), _price(110), _price(90), _price(105),
                          T0, T0 + HOUR, int64(500));
        data[1] = _candle(_price(105), _price(120), _price(100), _price(115),
                          T0 + HOUR, T0 + 2 * HOUR, int64(700));
        data[2] = _candle(_price(115), _price(130), _price(110), _price(120),
                          T0 + 2 * HOUR, T0 + 3 * HOUR, int64(900));

        pc.setCandles("HYPE/USDC", "1h", data);

        HyperCoreTypes.Candle[] memory back =
            pc.candleSnapshot("HYPE/USDC", "1h", 0, type(uint256).max);

        assertEq(back.length, 3, "3 candles returned");
        for (uint256 i = 0; i < 3; i++) {
            assertEq(back[i].open, data[i].open, "open");
            assertEq(back[i].high, data[i].high, "high");
            assertEq(back[i].low, data[i].low, "low");
            assertEq(back[i].close, data[i].close, "close");
            assertEq(back[i].startTime, data[i].startTime, "startTime");
            assertEq(back[i].endTime, data[i].endTime, "endTime");
            assertEq(back[i].volume, data[i].volume, "volume");
        }
    }

    function test_SetCandles_insertionSort_unorderedInput() public {
        HyperCoreTypes.Candle[] memory data = new HyperCoreTypes.Candle[](3);
        data[0] = _candle(_price(115), _price(130), _price(110), _price(120),
                          T0 + 2 * HOUR, T0 + 3 * HOUR, int64(900));
        data[1] = _candle(_price(100), _price(110), _price(90), _price(105),
                          T0, T0 + HOUR, int64(500));
        data[2] = _candle(_price(105), _price(120), _price(100), _price(115),
                          T0 + HOUR, T0 + 2 * HOUR, int64(700));

        pc.setCandles("HYPE/USDC", "1h", data);

        HyperCoreTypes.Candle[] memory back =
            pc.candleSnapshot("HYPE/USDC", "1h", 0, type(uint256).max);

        assertEq(back[0].startTime, T0);
        assertEq(back[1].startTime, T0 + HOUR);
        assertEq(back[2].startTime, T0 + 2 * HOUR);
    }

    function test_CandleSnapshot_timeWindow_filtersToRange() public {
        HyperCoreTypes.Candle[] memory data = new HyperCoreTypes.Candle[](4);
        for (uint256 i = 0; i < 4; i++) {
            int64 i64 = int64(uint64(i));
            int64 p = int64(100) + i64;
            data[i] = _candle(_price(p), _price(p + 5), _price(p - 5),
                              _price(p + 2), T0 + uint64(i) * HOUR,
                              T0 + uint64(i) * HOUR + HOUR, int64(100));
        }
        pc.setCandles("HYPE/USDC", "1h", data);

        HyperCoreTypes.Candle[] memory back =
            pc.candleSnapshot("HYPE/USDC", "1h", T0 + HOUR, T0 + 2 * HOUR);

        assertEq(back.length, 2, "only 2 candles in window");
        assertEq(back[0].startTime, T0 + HOUR);
        assertEq(back[1].startTime, T0 + 2 * HOUR);
    }

    function test_CandleSnapshot_unknownCoin_emptyArray() public {
        HyperCoreTypes.Candle[] memory back =
            pc.candleSnapshot("DOGE/USDC", "1h", 0, type(uint256).max);
        assertEq(back.length, 0, "empty");
    }

    function test_CandleSnapshot_differentCoin_isolated() public {
        HyperCoreTypes.Candle[] memory hypeData = new HyperCoreTypes.Candle[](1);
        hypeData[0] = _candle(_price(100), _price(105), _price(95), _price(102),
                              T0, T0 + HOUR, int64(500));
        pc.setCandles("HYPE/USDC", "1h", hypeData);

        HyperCoreTypes.Candle[] memory ethData = new HyperCoreTypes.Candle[](1);
        ethData[0] = _candle(_price(3000), _price(3100), _price(2900),
                             _price(3050), T0, T0 + HOUR, int64(700));
        pc.setCandles("ETH/USDC", "1h", ethData);

        HyperCoreTypes.Candle[] memory backHype =
            pc.candleSnapshot("HYPE/USDC", "1h", 0, type(uint256).max);
        HyperCoreTypes.Candle[] memory backEth =
            pc.candleSnapshot("ETH/USDC", "1h", 0, type(uint256).max);

        assertEq(backHype.length, 1);
        assertEq(backEth.length, 1);
        assertEq(backHype[0].close, _price(102));
        assertEq(backEth[0].close, _price(3050));
    }

    function test_CandleSnapshot_differentInterval_isolated() public {
        HyperCoreTypes.Candle[] memory h1 = new HyperCoreTypes.Candle[](1);
        h1[0] = _candle(_price(100), _price(105), _price(95), _price(102),
                        T0, T0 + HOUR, int64(500));
        pc.setCandles("HYPE/USDC", "1h", h1);

        HyperCoreTypes.Candle[] memory d1 = new HyperCoreTypes.Candle[](1);
        d1[0] = _candle(_price(100), _price(105), _price(95), _price(102),
                        T0, T0 + 24 * HOUR, int64(12000));
        pc.setCandles("HYPE/USDC", "1d", d1);

        assertEq(pc.candlesCount("HYPE/USDC", "1h"), 1);
        assertEq(pc.candlesCount("HYPE/USDC", "1d"), 1);
        HyperCoreTypes.Candle[] memory back1h =
            pc.candleSnapshot("HYPE/USDC", "1h", 0, type(uint256).max);
        HyperCoreTypes.Candle[] memory back1d =
            pc.candleSnapshot("HYPE/USDC", "1d", 0, type(uint256).max);
        assertEq(back1h[0].endTime, T0 + HOUR);
        assertEq(back1d[0].endTime, T0 + 24 * HOUR);
    }

    // ---- fundingSnapshot ----

    function test_SetFunding_roundTrip_returnsLastN() public {
        HyperCoreTypes.FundingSnapshot[] memory data =
            new HyperCoreTypes.FundingSnapshot[](4);
        for (uint256 i = 0; i < 4; i++) {
            data[i] = HyperCoreTypes.FundingSnapshot({
                fundingRate: (int64(100) + int64(uint64(i))) * 1_000_000,
                oi: (int64(5000) + int64(uint64(i))) * 1_000_000,
                timestamp: T0 + uint64(i) * HOUR
            });
        }
        pc.setFunding("HYPE/USDC", data);

        HyperCoreTypes.FundingSnapshot[] memory back =
            pc.fundingSnapshot("HYPE/USDC", 2);
        assertEq(back.length, 2);
        assertEq(back[0].timestamp, T0 + 2 * HOUR);
        assertEq(back[1].timestamp, T0 + 3 * HOUR);

        HyperCoreTypes.FundingSnapshot[] memory backAll =
            pc.fundingSnapshot("HYPE/USDC", 100);
        assertEq(backAll.length, 4);
    }

    function test_FundingSnapshot_zeroCount_returnsEmpty() public {
        HyperCoreTypes.FundingSnapshot[] memory back =
            pc.fundingSnapshot("HYPE/USDC", 0);
        assertEq(back.length, 0);
    }

    function test_FundingSnapshot_unknownCoin_emptyArray() public {
        HyperCoreTypes.FundingSnapshot[] memory back =
            pc.fundingSnapshot("DOGE/USDC", 5);
        assertEq(back.length, 0);
    }

    function test_FundingSnapshot_insertionSort_unordered() public {
        HyperCoreTypes.FundingSnapshot[] memory data =
            new HyperCoreTypes.FundingSnapshot[](3);
        data[0] = HyperCoreTypes.FundingSnapshot(100, 500, T0 + 2 * HOUR);
        data[1] = HyperCoreTypes.FundingSnapshot(100, 500, T0);
        data[2] = HyperCoreTypes.FundingSnapshot(100, 500, T0 + HOUR);
        pc.setFunding("HYPE/USDC", data);

        HyperCoreTypes.FundingSnapshot[] memory back =
            pc.fundingSnapshot("HYPE/USDC", 3);
        assertEq(back[0].timestamp, T0);
        assertEq(back[1].timestamp, T0 + HOUR);
        assertEq(back[2].timestamp, T0 + 2 * HOUR);
    }

    // ---- marketData ----

    function test_SetMarketData_roundTrip() public {
        HyperCoreTypes.MarketData memory md = HyperCoreTypes.MarketData({
            spotPrice: int64(100) * 1_000_000,
            oraclePrice: int64(100) * 1_000_000 + 500_000,
            timestamp: T0 + HOUR
        });
        pc.setMarketData("HYPE/USDC", md);

        HyperCoreTypes.MarketData memory back = pc.marketData("HYPE/USDC");
        assertEq(back.spotPrice, md.spotPrice);
        assertEq(back.oraclePrice, md.oraclePrice);
        assertEq(back.timestamp, md.timestamp);
    }

    function test_MarketData_unknownCoin_returnsZeroValue() public {
        HyperCoreTypes.MarketData memory back = pc.marketData("DOGE/USDC");
        assertEq(back.spotPrice, 0);
        assertEq(back.oraclePrice, 0);
        assertEq(back.timestamp, 0);
    }

    function test_MarketData_overwrite_lastWriteWins() public {
        HyperCoreTypes.MarketData memory v1 = HyperCoreTypes.MarketData({
            spotPrice: int64(100) * 1_000_000,
            oraclePrice: int64(100) * 1_000_000,
            timestamp: T0
        });
        HyperCoreTypes.MarketData memory v2 = HyperCoreTypes.MarketData({
            spotPrice: int64(200) * 1_000_000,
            oraclePrice: int64(200) * 1_000_000,
            timestamp: T0 + HOUR
        });
        pc.setMarketData("HYPE/USDC", v1);
        pc.setMarketData("HYPE/USDC", v2);
        HyperCoreTypes.MarketData memory back = pc.marketData("HYPE/USDC");
        assertEq(back.spotPrice, v2.spotPrice);
        assertEq(back.timestamp, v2.timestamp);
    }

    function test_HasMarketData_tracksPrimedCoins() public {
        assertFalse(pc.hasMarketData("HYPE/USDC"), "not primed yet");
        pc.setMarketData("HYPE/USDC", HyperCoreTypes.MarketData({
            spotPrice: int64(100) * 1_000_000,
            oraclePrice: int64(100) * 1_000_000,
            timestamp: T0
        }));
        assertTrue(pc.hasMarketData("HYPE/USDC"), "primed");
        assertFalse(pc.hasMarketData("ETH/USDC"), "other coin still unprimed");
    }

    // ---- setCandlesAndDeriveFunding ----

    function test_SetCandlesAndDeriveFunding_primesBoth() public {
        HyperCoreTypes.Candle[] memory data = new HyperCoreTypes.Candle[](2);
        data[0] = _candle(_price(100), _price(105), _price(95), _price(102),
                          T0, T0 + HOUR, int64(500));
        data[1] = _candle(_price(102), _price(108), _price(100), _price(105),
                          T0 + HOUR, T0 + 2 * HOUR, int64(600));
        pc.setCandlesAndDeriveFunding("HYPE/USDC", "1h", data);

        assertEq(pc.candlesCount("HYPE/USDC", "1h"), 2);
        assertEq(pc.fundingCount("HYPE/USDC"), 2);
        HyperCoreTypes.MarketData memory back = pc.marketData("HYPE/USDC");
        assertEq(back.spotPrice, _price(105));
        assertEq(back.oraclePrice, _price(105));
        assertEq(back.timestamp, T0 + 2 * HOUR);
    }

    // ---- resetCoin ----

    function test_ResetCoin_clearsOnlyThatCoin() public {
        HyperCoreTypes.Candle[] memory h1 = new HyperCoreTypes.Candle[](1);
        h1[0] = _candle(_price(100), _price(105), _price(95), _price(102),
                        T0, T0 + HOUR, int64(500));
        pc.setCandles("HYPE/USDC", "1h", h1);
        pc.setMarketData("HYPE/USDC", HyperCoreTypes.MarketData({
            spotPrice: int64(100) * 1_000_000,
            oraclePrice: int64(100) * 1_000_000,
            timestamp: T0
        }));

        HyperCoreTypes.Candle[] memory e1 = new HyperCoreTypes.Candle[](1);
        e1[0] = _candle(_price(3000), _price(3100), _price(2900),
                        _price(3050), T0, T0 + HOUR, int64(700));
        pc.setCandles("ETH/USDC", "1h", e1);

        pc.resetCoin("HYPE/USDC");

        assertEq(pc.candlesCount("HYPE/USDC", "1h"), 0, "HYPE cleared");
        assertEq(pc.candlesCount("ETH/USDC", "1h"), 1, "ETH untouched");
        assertFalse(pc.hasMarketData("HYPE/USDC"), "HYPE market data cleared");
    }

    // ---- introspection ----

    function test_CandlesCount_andFundingCount_returnLengths() public {
        HyperCoreTypes.Candle[] memory h1 = new HyperCoreTypes.Candle[](3);
        for (uint256 i = 0; i < 3; i++) {
            h1[i] = _candle(_price(100), _price(105), _price(95), _price(102),
                            T0 + uint64(i) * HOUR,
                            T0 + uint64(i) * HOUR + HOUR, int64(100));
        }
        pc.setCandles("HYPE/USDC", "1h", h1);
        assertEq(pc.candlesCount("HYPE/USDC", "1h"), 3);
        assertEq(pc.candlesCount("HYPE/USDC", "1m"), 0, "diff interval empty");

        HyperCoreTypes.FundingSnapshot[] memory f1 =
            new HyperCoreTypes.FundingSnapshot[](2);
        f1[0] = HyperCoreTypes.FundingSnapshot(100, 500, T0);
        f1[1] = HyperCoreTypes.FundingSnapshot(100, 500, T0 + HOUR);
        pc.setFunding("HYPE/USDC", f1);
        assertEq(pc.fundingCount("HYPE/USDC"), 2);
    }
}
