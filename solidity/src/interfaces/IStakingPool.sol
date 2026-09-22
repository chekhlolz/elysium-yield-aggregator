// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title IStakingPool
 * @notice Common staking-pool abstraction used by both KHYPELeg (kHYPE
 *         issuance) and SpotStakingLeg (direct HYPE staking). The two
 *         venues on HyperCore expose slightly different ABIs; this
 *         interface captures the union of what a leg actually needs:
 *         stake/unstake, exchange rate, and an unbonding period.
 *
 * @dev The stake() and unstake() semantics are:
 *       - stake(token, amount): burn `amount` of `token`, mint stake
 *         tokens 1:1 at the current exchange rate.
 *       - unstake(stakeToken, amount): burn stake tokens, schedule a
 *         `creditAt` timestamp; underlying tokens are credited at that
 *         time via creditUnbonded().
 */
interface IStakingPool {
    /** Stake `amount` of `token` (HYPE) and receive stake tokens. */
    function stake(address token, uint256 amount) external;

    /** Begin unbonding `amount` of the stake token. */
    function unstake(address stakeToken, uint256 amount) external;

    /** Withdraw previously-unbonded tokens once the clock has run. */
    function creditUnbonded(address stakeToken, uint256 amount, address to)
        external returns (uint256 outAmount);

    /** Spot HYPE per 1 stake token (1e18 fixed-point). */
    function exchangeRate() external view returns (uint256);

    /** Stake-token balance at `stakeToken` for `account`. */
    function balanceOf(address stakeToken, address account) external view returns (uint256);

    /** Unbonding period in seconds. 0 = instant (for mocks). */
    function unbondingPeriod() external view returns (uint256);

    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount, uint64 creditAt);
    event Unbonded(address indexed user, uint256 amount);
}
