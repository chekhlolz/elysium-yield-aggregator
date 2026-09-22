// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../interfaces/ITradeOnlyAgent.sol";

/**
 * @title TradeOnlyAgent
 * @notice Reference implementation of the Trade-Only-Agent delegation
 *         standard. See docs/DELEGATION_SPEC.md for the full design.
 *
 * Design highlights:
 *   - EIP-712 typed signatures, domain-separated by chainId.
 *   - Delegation caps: asset allowlist, maxNotional, maxPerOrder.
 *   - Universal revoke: revoking a keeper invalidates every pending
 *     delegation to that keeper from the same delegator.
 *   - Venue-local notional tracking: the same (delegator, keeper, nonce)
 *     can be used on multiple venues without cross-venue accounting.
 *
 * NOT audited. Production requires a full audit before deployment.
 */
contract TradeOnlyAgent is ITradeOnlyAgent {
    /// EIP-712 type hashes.
    bytes32 private constant DELEGATION_TYPEHASH = keccak256(
        "Delegation(address keeper,uint256[] assetIds,uint256 maxNotional,uint256 maxPerOrder,uint64 expiresAt,uint64 nonce,bytes32 salt)"
    );

    // ---- Revocation state ----
    // revokedKeypaths[(delegator, keeper)] = true → all future delegations
    // to `keeper` from `delegator` are rejected (existing ones may still
    // be used if their nonce was already executed).
    mapping(address => mapping(address => bool)) public revokedKeypaths;

    // ---- Venue-local notional tracking ----
    // usedNotional[(venue, delegator, keeper, nonce)] = remaining cap.
    // The venue passes its own address as `venue` when submitting intents.
    mapping(address => mapping(bytes32 => uint256)) private usedNotional;
    mapping(bytes32 => uint256) private delegationCap;

    // ---- Verification ----
    function isValidDelegation(address from, Delegation calldata d, Signature calldata sig)
        external view override returns (bool)
    {
        if (d.keeper == address(0)) return false;
        if (d.maxNotional == 0) return false;
        if (d.maxPerOrder == 0) return false;
        // FIX-21 (round-3 P0): `expiresAt == 0` is the "no expiry"
        // sentinel and must NOT short-circuit the rest of validation.
        // The previous shape
        //   if (d.expiresAt == 0 || block.timestamp > d.expiresAt) {
        //       return d.expiresAt == 0;
        //   }
        // returned `true` for any never-expires delegation regardless of
        // revocation state or signature validity — a delegator who
        // revoked a keeper could not stop that keeper from acting under
        // pre-existing never-expires delegations. The expired check is
        // now the only early-out on `expiresAt`; revocation and
        // signature are always evaluated.
        if (d.expiresAt != 0 && block.timestamp > d.expiresAt) return false;
        if (revokedKeypaths[from][d.keeper]) return false;

        bytes32 digest = _delegationHash(from, d);
        return _recover(digest, sig) == from;
    }

    /**
     * Compute the remaining notional cap for a (venue, delegator, keeper, nonce) tuple.
     * Caller is responsible for checking `isValidDelegation` first.
     */
    function remainingNotional(address venue, address delegator, Delegation calldata d)
        external view returns (uint256)
    {
        bytes32 key = _delegationKey(venue, delegator, d.keeper, d.nonce);
        uint256 cap = delegationCap[key];
        uint256 used = usedNotional[venue][key];
        return cap > used ? cap - used : 0;
    }

    /**
     * Venue calls this after successfully executing a trade under this
     * delegation. Deducts notional from the delegation's remaining cap.
     *
     * @return accepted   true if the notional fits within the remaining cap.
     */
    function recordExecution(
        address venue,
        address delegator,
        Delegation calldata d,
        uint256 notional,
        bytes32 delegationId,
        uint64 executedAt
    ) external returns (bool accepted) {
        require(msg.sender == venue, "not venue");
        bytes32 key = _delegationKey(venue, delegator, d.keeper, d.nonce);
        if (delegationCap[key] == 0) {
            delegationCap[key] = d.maxNotional;
        }
        uint256 used = usedNotional[venue][key];
        if (used + notional > d.maxNotional) return false;
        usedNotional[venue][key] = used + notional;
        emit TradeExecuted(delegator, d.keeper, 0, notional, delegationId, executedAt);
        return true;
    }

    // ---- Revocation ----
    function revoke(address keeper) external override {
        require(keeper != address(0), "zero keeper");
        revokedKeypaths[msg.sender][keeper] = true;
        emit Revoked(msg.sender, keeper);
    }

    function isRevoked(address keeper) external view override returns (bool) {
        // nonce is part of the interface; revocation is keyed on (delegator, keeper) only.
        return revokedKeypaths[msg.sender][keeper];
    }

    // ---- EIP-712 internals ----
    function _delegationHash(address _from, Delegation calldata d) internal view returns (bytes32) {
        bytes32 digestStruct = keccak256(
            abi.encode(
                _from,
                DELEGATION_TYPEHASH,
                d.keeper,
                keccak256(abi.encode(d.assetIds)),
                d.maxNotional,
                d.maxPerOrder,
                d.expiresAt,
                d.nonce,
                d.salt
            )
        );
        return keccak256(
            abi.encodePacked(
                "\x19\x01",
                _domainSeparator(),
                digestStruct
            )
        );
    }

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("TradeOnlyAgent v1"),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
    }

    function _delegationKey(address venue, address delegator, address keeper, uint64 nonce)
        internal pure returns (bytes32)
    {
        return keccak256(abi.encode(venue, delegator, keeper, nonce));
    }

    function _recover(bytes32 digest, Signature calldata sig) internal pure returns (address) {
        bytes32 r = sig.r;
        bytes32 s = sig.s;
        uint8 v = sig.v;
        require(v == 27 || v == 28, "bad v");
        return ecrecover(digest, v, r, s);
    }
}
