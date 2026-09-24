// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./ITradeOnlyAgent.sol";

/**
 * @title IIntentSubmittingLeg
 * @notice Extended interface for legs that accept user-driven intents
 *         (stream-B per docs/DESIGN_KI2_SUBMITINTENT.md §4). Staking
 *         legs (KHYPE, Spot) do NOT implement this — they never call
 *         the writer, so they have no intent-submission surface.
 *
 * The delegator signs a Delegation with `keeper = address(leg)`; the
 * delegator (or an authorized caller named in the delegation) submits
 * the (delegation, signature) tuple to `submitIntent`. The leg
 * verifies the signature against `TradeOnlyAgent`, enforces the
 * venue-local `maxPerOrder` cap, forwards the signature to the
 * writer, and returns the notional actually allocated.
 *
 * KI-2b Phase 2 (DESIGN_KI2B_AGGREGATOR_STREAM_A.md §5.3) adds three
 * stream-A variants: `submitIntentFromStreamA`, `reduceIntent`, and
 * `harvestIntent`. The stream-A entry points accept
 * `d.keeper == address(aggregator)` (not the leg's own address); the
 * delegator signs one delegation per aggregator-driven rebalance
 * (DESIGN_KI2B_AGGREGATOR_STREAM_A.md §3-4).
 */
interface IIntentSubmittingLeg {
    /**
     * Stream B: submit a signed intent to this leg. The delegator's
     * signed delegation names `address(leg)` as the keeper; `msg.sender`
     * must be the delegator (or the leg's owner, for aggregator
     * forwarding).
     *
     * The leg is responsible for:
     *   - Validating `d.keeper == address(this)`.
     *   - Clamping `amount <= d.maxPerOrder` (venue-local per-order
     *     cap; the verifier does not check this — see
     *     DELEGATION_SPEC.md §107-134).
     *   - Verifying the EIP-712 signature against
     *     `TradeOnlyAgent.isValidDelegation`.
     *   - Forwarding the signature to
     *     `writer.openPosition(...)` / `writer.closePosition(...)`.
     *   - Calling `TradeOnlyAgent.recordExecution` to update the
     *     venue's per-delegation notional ledger (FIX-14).
     *
     * @return allocatedUsd   The amount actually allocated.
     */
    function submitIntent(
        ITradeOnlyAgent.Delegation calldata d,
        ITradeOnlyAgent.Signature calldata sig,
        uint256 amount
    ) external returns (uint256);

    /**
     * KI-2b Phase 2 (stream A): aggregate-delegated allocate. The
     * caller must be the aggregator named as `d.keeper`. `amount` is
     * the total (spot + perp) notional requested; the leg splits it
     * per its own strategy math (50/50 for PerpFundingLeg, HR=1.0 for
     * BasisHedgeLeg).
     *
     * The aggregator calls this from `executePendingWithStreamA(d, sig)`
     * after validating the stream-A delegation (keeper == aggregator,
     * not expired). The leg verifies the EIP-712 signature and
     * enforces the per-order cap before calling the writer.
     *
     * @return allocatedUsd   The amount actually allocated.
     */
    function submitIntentFromStreamA(
        ITradeOnlyAgent.Delegation calldata d,
        ITradeOnlyAgent.Signature calldata sig,
        uint256 amount
    ) external returns (uint256);

    /**
     * KI-2b Phase 2 (stream A): aggregate-delegated reduce. Closes
     * `amount` of the leg's perp notional under the aggregator's
     * delegation and sweeps the returned USDC to the aggregator. The
     * spot-side reduction (sell HYPE back to USDC through the router)
     * is leg-internal and does not touch the writer — see
     * DESIGN_KI2B_AGGREGATOR_STREAM_A.md §10.
     *
     * @return returnedUsd    The USDC returned to the aggregator.
     */
    function reduceIntent(
        ITradeOnlyAgent.Delegation calldata d,
        ITradeOnlyAgent.Signature calldata sig,
        uint256 amount
    ) external returns (uint256);

    /**
     * KI-2b Phase 2 (stream A): aggregate-delegated harvest. Closes
     * the open short under the aggregator's delegation, re-opens it
     * (same notional) to continue collecting funding, then sweeps the
     * realised PnL USDC to the aggregator. The spot HYPE position
     * stays open throughout (only the perp side is close/reopened).
     *
     * No `amount` argument — `harvestIntent` closes/reopens the leg's
     * entire perp notional in a single round-trip.
     */
    function harvestIntent(
        ITradeOnlyAgent.Delegation calldata d,
        ITradeOnlyAgent.Signature calldata sig
    ) external;
}
