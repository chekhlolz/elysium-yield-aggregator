// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../interfaces/IYieldLeg.sol";

/**
 * @title IYieldAggregator
 * @notice ERC-4626-style vault with regime-driven allocation across four
 *         yield legs. See docs/AGGREGATOR_SPEC.md for the full design.
 *
 * This interface is purely for external callers (frontends, indexers,
 * other contracts). The concrete `YieldAggregator` contract implements
 * it with its own storage layout.
 */
interface IYieldAggregator {
    // ---- ERC-20 accounting ----
    function asset() external view returns (address);
    function totalSupply() external view returns (uint256);
    function totalAssets() external view returns (uint256);
    function shares(address owner) external view returns (uint256);

    function convertToShares(uint256 assets) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);

    // ---- Deposit / withdraw ----
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
    function mint(uint256 shares, address receiver) external returns (uint256 assets);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);

    // ---- Current regime state ----
    function currentApyBps() external view returns (uint256);
    function currentWeights() external view returns (uint16[4] memory);
    function legs() external view returns (
        address spotVault,
        address khypeVault,
        address perpKeeper,
        address basisHedge
    );

    // ---- Pending allocation ----
    function pendingAllocationId() external view returns (bytes32);
    function requestAllocation(uint16[4] calldata newWeights, string calldata reason)
        external returns (bytes32 allocationId);
    function executePending() external;
    function cancelPending(bytes32 allocationId) external;

    // ---- Governance ----
    function setPaused(bool _paused) external;
}
