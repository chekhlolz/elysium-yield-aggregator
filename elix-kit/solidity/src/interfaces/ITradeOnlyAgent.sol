// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

/**
 * @title ITradeOnlyAgent
 * @notice On-chain standard for scoped, revocable trade delegation.
 *
 * See `hypeback/docs/DELEGATION_SPEC.md` for the full design.
 *
 * In one paragraph: a delegator signs an EIP-712 message granting a
 * keeper scoped trade rights (asset allowlist, max notional, max per
 * order, expiry). Venues (like ElysiumCoreWriter) accept a
 * (delegation, signature) tuple at intent-submit time and either
 * execute the trade or reject it. Revocation is venue-local.
 *
 * @dev Copied verbatim (with SPDX header normalised to Apache-2.0)
 *      from `hypeback/solidity/src/interfaces/ITradeOnlyAgent.sol`
 *      so this starter kit can link to the standard without a build
 *      dependency on the parent repo.
 */
interface ITradeOnlyAgent {
    struct Delegation {
        address keeper;
        uint256[] assetIds; // empty array = all assets
        /// Per-venue notional cap. The verifier tracks `usedNotional`
        /// keyed by (venue, delegator, keeper, nonce), so a single
        /// delegation used on N venues has an effective ceiling of
        /// N × maxNotional. This is a known limitation — see the
        /// "Per-venue notional cap" entry in docs/DELEGATION_SPEC.md §9.
        uint256 maxNotional; // USD per venue (6 decimals)
        uint256 maxPerOrder; // USD per single order (6 decimals)
        /// Unix ts; 0 = never expires (the "no expiry" sentinel).
        /// The verifier must NOT short-circuit on `d.expiresAt == 0` -
        /// that sentinel only means "skip the expiry-of-this-delegation
        /// check". All other validation (signature, keeper non-zero,
        /// cap fields non-zero, revocation, and any expiry check on
        /// OTHER delegations from the same delegator) still runs.
        uint64 expiresAt;
        uint64 nonce; // user-chosen for ordering / de-duplication
        bytes32 salt; // user-chosen for uniqueness
    }

    struct Signature {
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    /**
     * Verify a delegation signature for `from`. Returns true iff the
     * signature is valid, not expired, and the delegation nonce has
     * not been revoked.
     *
     * Note: `salt` and `nonce` together identify the delegation. A
     * verifier should deduplicate by the composite key.
     */
    function isValidDelegation(address from, Delegation calldata d, Signature calldata sig) external view returns (bool);

    /**
     * Revoke all delegations to `keeper`. Venue-local.
     */
    function revoke(address keeper) external;

    /**
     * Query if `keeper` is revoked by the caller. Revocation is per-keeper.
     */
    function isRevoked(address keeper) external view returns (bool);

    event TradeExecuted(
        address indexed delegator,
        address indexed keeper,
        uint256 indexed assetId,
        uint256 notional,
        bytes32 delegationId,
        uint64 executedAt
    );
    event Revoked(address indexed delegator, address indexed keeper);
}
