// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title IXHYPELeg
 * @notice Marker interface for the Liminal xHYPE wrapper. The vault itself
 *         speaks standard ERC-4626 (IERC4626Minimal below); this marker
 *         adds the two xHYPE-specific fields a leg needs beyond 4626:
 *
 *           - apyBps()         : advertised annualised APY in bps
 *                               (1450 = 14.50% live baseline).
 *           - isLiquidatable() : whether the vault currently accepts
 *                               deposits and redemptions at full rate.
 *
 *         LiminalXHYPELeg implements this so any external caller can
 *         detect "this is an xHYPE-shaped 4626 vault" without having to
 *         hardcode the Liminal address. The vault address is supplied
 *         via the leg's constructor — no Liminal address is baked into
 *         this repo.
 */

/// @dev Minimal ERC-4626 surface. The vault behind LiminalXHYPELeg is
///      expected to expose the full 4626 surface; we keep this minimal
///      so the leg only has to verify the methods it actually calls
///      (deposit, withdraw, preview*, balanceOf, convertTo*).
interface IERC4626Minimal {
    function asset() external view returns (address);
    function totalAssets() external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function previewDeposit(uint256 assets) external view returns (uint256);
    function previewMint(uint256 shares) external view returns (uint256);
    function previewWithdraw(uint256 assets) external view returns (uint256);
    function previewRedeem(uint256 shares) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function mint(uint256 shares, address receiver) external returns (uint256 assets);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
}

interface IXHYPELeg {
    /// @return Advertised annualised APY of the wrapped vault, in bps
    ///         (1450 = 14.50%). 0 = unknown / paused.
    function apyBps() external view returns (uint256);

    /// @return true if the vault currently accepts deposits and
    ///         redemptions at full rate; false during pauses, cooldowns,
    ///         or maintenance windows. The leg checks this before
    ///         sending fresh allocations so a paused vault does not
    ///         strand the aggregator's cash.
    function isLiquidatable() external view returns (bool);
}
