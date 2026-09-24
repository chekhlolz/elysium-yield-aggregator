// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {HyperCoreTypes} from "./types.sol";

/**
 * @title IHyperCorePrecompile
 * @notice The HyperCore market-data precompile surface we EXPECT on Elysium.
 *
 * IMPORTANT — this is a SPECULATIVE INTERFACE.
 *
 * Kinetiq has not published the final ABI of the HyperCore market-data
 * precompile yet. The placeholder address used throughout this harness
 * (`0x000000000000000000000000000000000000C0DE`) matches the constant
 * already defined in `hypeback/hypercore.py::HYPERCORE_PRECOMPILE_ADDRESS`
 * so the Python backtester and the Solidity test harness share one
 * source of truth.
 *
 * When Kinetiq publishes the real spec, the only thing that should
 * change is this file (or the mocks, if the value types or argument
 * shapes shift). The `MarketDataFeedAdapter` is already written to
 * tolerate the current RegimeDetector's `IMarketDataFeed` shape, so
 * swapping the underlying precompile should not require touching
 * contracts above the harness.
 *
 * Naming convention: method names and struct field names follow the
 * Python client (`candleSnapshot`, `fundingSnapshot`, `marketData`) so
 * the two clients share the same vocabulary. If Kinetiq's final spec
 * uses different names (e.g. `getCandles` / `getFundingHistory` /
 * `getPrice`), an adapter in `src/MarketDataFeedAdapter.sol` bridges.
 *
 * Structs live in `HyperCoreTypes` so they can be reused by callers
 * that only need the type shapes and don't want to depend on the
 * precompile interface itself.
 */
interface IHyperCorePrecompile {
    /**
     * Return OHLCV candles in the [startTime, endTime] window (inclusive,
     * unix seconds). Intervals accepted today: "1m", "5m", "15m", "1h",
     * "4h", "1d", "1w". Anything else returns an empty array — tests
     * should not rely on a specific revert on unknown intervals.
     */
    function candleSnapshot(
        string calldata coin,
        string calldata interval,
        uint256 startTime,
        uint256 endTime
    ) external view returns (HyperCoreTypes.Candle[] memory);

    /**
     * Return the last `count` funding ticks for `coin`, sorted ascending
     * by timestamp. If fewer than `count` records exist, return all of
     * them. The mock treats `count` as a strict cap (not "from now").
     */
    function fundingSnapshot(
        string calldata coin,
        uint256 count
    ) external view returns (HyperCoreTypes.FundingSnapshot[] memory);

    /**
     * Latest market data for `coin`. If the mock has not been primed with
     * `setMarketData(coin, ...)`, this returns a zero-value MarketData
     * rather than reverting, so consumers get a stable "no data yet"
     * sentinel rather than an EVM error.
     */
    function marketData(string calldata coin)
        external view returns (HyperCoreTypes.MarketData memory);
}
