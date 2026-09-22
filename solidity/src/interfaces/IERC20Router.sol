// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title IERC20Router
 * @notice Token-swap router facade used by KHYPELeg and SpotStakingLeg
 *         to move USDC<->HYPE. Deliberately thin so legs stay
 *         mock-friendly — a test rig can implement this with a fixed
 *         1:1 rate and swap fees become trivial to reason about in
 *         simulation.
 */
interface IERC20Router {
    /** Swap USDC into `tokenOut`. Returns `outAmount` actually received. */
    function swapExactUSDCForToken(
        address tokenOut,
        uint256 amount
    ) external returns (uint256 outAmount);

    /** Swap `tokenIn` into USDC. Returns `outAmount` actually received. */
    function swapExactTokenForUSDC(
        address tokenIn,
        uint256 amount
    ) external returns (uint256 outAmount);

    /** Quote: how many `tokenOut` does `amountIn` of `tokenIn` fetch? */
    function getAmountOut(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view returns (uint256 outAmount);
}
