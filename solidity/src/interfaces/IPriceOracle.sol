// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title IPriceOracle
 * @notice Thin price + staking-APY facade used by the LST and staking
 *         legs. Deliberately separated from IMarketDataFeed (which is a
 *         full market-data feed for funding / vol) so legs can be
 *         deployed with a static-config oracle during testnet and
 *         swapped to a live oracle in production.
 */
interface IPriceOracle {
    /** Price of `token` in USDC (6 decimals). 1e6 = $1.00. */
    function priceOf(string calldata token) external view returns (uint256);

    /**
     * Venue-published annualized staking APY in basis points.
     * 10000 bps = 100%.
     */
    function getApy(string calldata token) external view returns (uint256);
}
