// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title ITradeOnlyAgent
 * @notice On-chain standard for scoped, revocable trade delegation.
 *
 * See docs/DELEGATION_SPEC.md for the full design.
 *
 * In one paragraph: a delegator signs an EIP-712 message granting a
 * keeper scoped trade rights (asset allowlist, max notional, max per
 * order, expiry). Venues (like ElysiumCoreWriter) accept a
 * (delegation, signature) tuple at intent-submit time and either
 * execute the trade or reject it. Revocation is venue-local.
 */
interface ITradeOnlyAgent {
    struct Delegation {
        address keeper;
        uint256[] assetIds;    // empty array = all assets
        uint256 maxNotional;   // total USD notional this keeper can trade (6 decimals)
        uint256 maxPerOrder;   // USD per single order (6 decimals)
        uint64  expiresAt;     // unix ts; 0 = never
        uint64  nonce;         // user-chosen for ordering / de-duplication
        bytes32  salt;         // user-chosen for uniqueness
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
    function isValidDelegation(address from, Delegation calldata d, Signature calldata sig)
        external view returns (bool)
    ;

    /** Revoke all delegations to `keeper`. Venue-local. */
    function revoke(address keeper) external;

    /** Query if `keeper` is revoked by the caller. Revocation is per-keeper. */
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
