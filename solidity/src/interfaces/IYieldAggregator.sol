// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./IYieldLeg.sol";

/**
 * @title IYieldAggregator
 * @notice Public interface for YieldAggregator (ERC-4626-style vault
 *         with regime-driven allocation across four yield legs).
 *
 * See ../aggregator/YieldAggregator.sol for the concrete impl and
 * docs/AGGREGATOR_SPEC.md for the design rationale.
 *
 * Note: the implementation exposes `legs` as `IYieldLeg[4] public immutable`,
 * whose auto-generated getter returns `address[4]`. We match that here
 * (`legsView()`) and additionally provide `legAt(i)` for safe indexed access.
 */
interface IYieldAggregator {
    // ---- ERC-20 accounting ----
    function asset() external view returns (address);
    function totalAssets() external view returns (uint256);
    function totalShares() external view returns (uint256);
    function shares(address owner) external view returns (uint256);

    function convertToShares(uint256 assets) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);

    // ---- Deposit / withdraw ----
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
    function mint(uint256 shares, address receiver) external returns (uint256 assets);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);

    // ---- ERC-4626 previews ----
    function previewDeposit(uint256 assets) external view returns (uint256);
    function previewMint(uint256 shares) external view returns (uint256);
    function previewWithdraw(uint256 assets) external view returns (uint256);
    function previewRedeem(uint256 shares) external view returns (uint256);

    // ---- Current regime state ----
    function currentApyBps() external view returns (uint256);
    function weights() external view returns (uint16[4] memory);
    function legsView() external view returns (address[4] memory);
    function legAt(uint256 i) external view returns (address);
    function totalLegValue() external view returns (uint256);

    // ---- Pending allocation (keeper + timelock) ----
    function pendingAllocationId() external view returns (bytes32);
    function requestAllocation(uint16[4] calldata newWeights, string calldata reason)
        external returns (bytes32 allocationId);
    function executePending() external;
    function cancelPending(bytes32 allocationId) external;

    // ---- Yield harvesting ----
    function harvestFromAllLegs() external;

    // ---- Governance ----
    function setPaused(bool _paused) external;
    function setKeeper(address _keeper) external;
    function setTimelock(uint32 _timelockSeconds) external;
}
