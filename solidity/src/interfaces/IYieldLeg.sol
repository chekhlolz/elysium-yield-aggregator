// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title IYieldLeg
 * @notice Abstraction for a single yield source inside YieldAggregator.
 *
 * Each leg wraps one yield venue (spot staking, kHYPE, perp funding,
 * delta-neutral basis hedge) and exposes a uniform interface so the
 * aggregator treats all legs as opaque black boxes.
 *
 * Design rules:
 *   - A leg NEVER touches HyperCore state directly; it routes through
 *     ElysiumCoreWriter for any perp operation.
 *   - A leg NEVER calls the aggregator back during allocateTo(); yields
 *     are moved by the aggregator calling harvest() at will.
 *   - expectedApy() is a point-in-time read, not a commitment.
 */
interface IYieldLeg {
    /** Human-readable name, e.g. "PerpFundingLeg". */
    function name() external view returns (string memory);

    /**
     * Currently-expected annualized yield in basis points.
     * For perp funding, this is the trailing 24h EMA. For staking,
     * it's the current protocol rate.
     *
     * Units: basis points of 10000 = 100%.
     */
    function expectedApy() external view returns (uint256);

    /**
     * Trailing ApyBps observations, oldest first. Length and cadence
     * are leg-defined; consumers should tolerate variable window length.
     */
    function apyHistory() external view returns (uint256[] memory);

    /**
     * Allocate `amount` (in asset's smallest unit) into this leg.
     * The leg keeps track of the allocated amount internally.
     *
     * @param amount  asset units to allocate (USDC 6 decimals by convention)
     * @return allocated USD actually placed (may be less than amount on
     *         partial fills or rounding)
     */
    function allocateTo(uint256 amount) external returns (uint256);

    /**
     * Move any realized yield from this leg back to the aggregator.
     * Legs may also pull accrued yield on this call; the aggregator does
     * not need to wait for funding settlement windows.
     */
    function harvest() external;

    /**
     * Reduce allocation by `amount`. Used during rebalance or withdrawal.
     *
     * @param amount  asset units to reduce by
     * @return returnedUSD  actual amount returned (may be less due to
     *         unstake waiting periods — see leg docs)
     */
    function reduceFrom(uint256 amount) external returns (uint256);

    /** Total USD currently allocated to this leg, accrued yield included. */
    function currentValue() external view returns (uint256);

    event Allocated(uint256 amount, uint256 totalAllocated);
    event Reduced(uint256 amount, uint256 totalAllocated);
    event Harvested(uint256 yieldUsd);
}
