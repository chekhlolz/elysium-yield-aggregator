// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title IFundingSource
 * @notice Funding-rate source consumed by PerpFundingLeg. Distinct from
 *         IMarketDataFeed (which is the full market-data feed used by
 *         RegimeDetector): this interface only exposes the one method
 *         the perp-funding leg actually needs.
 *
 * @dev Sign convention: negative funding = short pays long; positive
 *      = long pays short (standard HyperCore). PerpFundingLeg reads
 *      this and flips sign when it holds a short.
 */
interface IFundingSource {
    /** Trailing funding rate for `coin`, in basis points. Signed. */
    function fundingRateBps(string calldata coin) external view returns (int64);

    /** Trailing funding rate annualized, in basis points. Signed. */
    function fundingApyBps(string calldata coin) external view returns (int64);
}
