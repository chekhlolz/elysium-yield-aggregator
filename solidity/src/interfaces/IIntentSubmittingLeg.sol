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
 */
interface IIntentSubmittingLeg {
    /**
     * Submit a signed intent to this leg. The delegator's signed
     * delegation names `address(leg)` as the keeper; `msg.sender` must
     * be the delegator (or the leg's owner, for aggregator forwarding).
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
}
