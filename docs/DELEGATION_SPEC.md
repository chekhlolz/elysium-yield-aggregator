# Trade-Only-Agent Delegation Protocol — Specification

**Status**: design draft · **Target**: Elysium mainnet, extensible to any EVM chain · **Scope**: on-chain standard for scoped trade delegation

---

## 1. Problem statement

On HyperCore, every user either:

1. **Signs their own orders** — requires always-on signing key, no way to delegate to a trading algorithm without giving it full wallet control.
2. **Gives an EOA full control** — trust the keeper with everything (balance, tokens, approvals, contract calls). No scope, no expiry, no revocation granularity.

Neither option is fit for institutional or advanced retail use. The gap:

> **How do I delegate trading rights to a keeper — scoped to specific assets, size-limited, time-limited, and revocable at any time — without handing over the wallet?**

Kinetiq's marketing for ElysiumCoreWriter uses the phrase **"trade-only agent"**, but there is no on-chain protocol defining what that means. Every vault writes its own version. This spec defines the standard.

## 2. Core interface

```solidity
interface ITradeOnlyAgent {
    /// The delegator signs an EIP-712 message granting scoped trade rights.
    /// The keeper presents that signature to a venue (ElysiumCoreWriter, etc.)
    /// when submitting orders.

    struct Delegation {
        address keeper;         // who can act
        uint256[] assetIds;     // which perps/spot pairs (empty = all)
        uint256 maxNotional;    // total USD notional this keeper can trade
        uint256 maxPerOrder;    // USD per single order
        uint64  expiresAt;      // unix ts; 0 = never
        uint64  nonce;          // incremented on each delegation
        bytes32  salt;          // user-chosen nonce for ordering
    }

    struct Signature {
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    // The venue calls this to validate a keeper's right to act
    function isValidDelegation(
        address from,            // delegator
        Delegation calldata d,
        Signature calldata sig
    ) external view returns (bool);

    // The delegator calls this to revoke all delegations to a keeper
    function revoke(address keeper) external;

    // Events emitted by the venue, not the delegator
    event TradeExecuted(
        address indexed delegator,
        address indexed keeper,
        uint256 indexed assetId,
        uint256 notional,
        bytes32 delegationId,
        uint64 executedAt
    );
}
```

## 3. Signature scheme

- **Domain-separated EIP-712** signature with `domainSeparator = (name="TradeOnlyAgent v1", chainId=99801, verifyingContract=...)`.
- The signed message is a `keccak256(abi.encode(DELEGATION_TYPEHASH, keeper, assetIds, maxNotional, maxPerOrder, expiresAt, nonce, salt))`.
- The keeper presents the signature + delegation struct at submit time. The venue checks `isValidDelegation` and either accepts or rejects.
- **No delegation storage on-chain by default** — this keeps the protocol permissive. Venues that want to track executed notional can index `TradeExecuted` events.

### Why stateless?

- **Permissionless**: no need to register on a registry contract.
- **Portable**: a signature works on any venue that implements the same interface.
- **Revocable**: revocation is on the venue side (keeper's nonce is tracked per-keeper by the venue). A revoked keeper's signature becomes invalid at the venue.

The tradeoff: revocation is venue-local, not universal. If a keeper is compromised, each venue must be notified separately. This is acceptable because venues are few (ElysiumCoreWriter today, maybe 2-3 more).

## 4. Venue-side adapter (ElysiumCoreWriter integration)

```solidity
// Inside ElysiumCoreWriter, when receiving an intent:

function submitIntent(Intent calldata intent, Signature calldata sig) external {
    require(isValidDelegation(msg.sender, intent.delegation, sig), "invalid delegation");
    require(block.timestamp <= intent.delegation.expiresAt, "expired");
    require(intent.notional <= intent.delegation.maxPerOrder, "per-order cap");

    // Keeper's remaining notional tracked in a venue-local mapping
    uint256 remaining = delegationRemaining[keccak256(abi.encode(msg.sender, intent.delegation.nonce))];
    require(remaining >= intent.notional, "notional cap exceeded");
    remaining -= intent.notional;
    delegationRemaining[...] = remaining;

    executeOnHyperCore(intent);
    emit TradeExecuted(msg.sender, intent.delegation.keeper, intent.delegation.nonce, intent.notional, ...);
}
```

The venue is responsible for:
- Verifying the signature against `ITradeOnlyAgent.isValidDelegation`
- Tracking per-delegation remaining notional (mapping indexed by keeper + nonce)
- Emitting `TradeExecuted` events
- Honoring revocation (venue pulls from a `revokedKeypaths` mapping the delegator can populate)

The venue does **not** need to store the delegation struct itself — the keeper presents it each time, and the venue just checks the remaining capacity.

## 5. Delegation lifecycle

```
┌──────────────┐  1. signs delegation  ┌──────────────┐
│  delegator   │ ────────────────────► │ EIP-712 msg  │
│  (user)      │                       └──────┬───────┘
└──────────────┘                              │
                                              ▼
                                     ┌────────────────┐
                                     │  keeper       │
                                     │  (algorithm)  │
                                     └───────┬───────┘
                                             │
                                             │ 2. submits intent
                                             │  with sig + delegation
                                             ▼
                              ┌────────────────────────────┐
                              │  ElysiumCoreWriter         │
                              │  (venue)                   │
                              │                            │
                              │  - verify sig              │
                              │  - check expiry, caps      │
                              │  - check revoked           │
                              │  - check remaining         │
                              │  - execute on HyperCore    │
                              │  - emit TradeExecuted      │
                              └────────────────────────────┘

Revocation: delegator calls revoke(keeper) on any venue
           → venue adds keeper to revokedKeypaths
           → all further submissions by that keeper are rejected
```

## 6. Why this matters for the Elysium ecosystem

1. **Institutional LPs can use aggregators without custodial bridges.** A 400k fund can delegate scoped trade rights to an aggregator, keep custody of assets, and revoke at any time.
2. **Algorithmic traders get access to venue liquidity.** A solo trader can publish a `TradeOnlyAgent` contract with their strategy, others delegate to them, revenue share via per-transaction fees.
3. **Kinetiq's "trade-only agent" phrase becomes concrete.** ElysiumCoreWriter marketing becomes executable.

## 7. Comparison to existing solutions

| Approach | Scope | Expiry | Revocation | Portable across venues |
|---|---|---|---|---|
| Full EOA control | No | No | Burn the EOA | No (single chain) |
| 0x protocol (order signing) | Per order | Per order | Per order | Yes, but order-centric |
| DCAO (0x) | Batch orders | Expiry per order | Per order | Yes |
| **TradeOnlyAgent (this spec)** | **Per delegation** | **Per delegation** | **Universal revoke** | **Yes** |

The differentiation: TradeOnlyAgent is a **persistent, scoped, revocable** delegation, not a per-order or per-batch authorization.

## 8. What's out of scope

- **Fee structure** — venue-level, not part of the standard.
- **Sub-agent delegation** — keeper cannot re-delegate. If that's needed, a new spec.
- **Cross-chain delegation** — signatures are domain-separated to a chainId, so a signature valid on Elysium (chainId 99801) is not valid on HyperEVM (chainId 999). This is intentional.
- **Governance of revocation** — revocation is per-keeper, immediate, no consensus. A compromised keeper must be revoked venue-by-venue.

## 9. Open questions for Kinetiq

1. **Does ElysiumCoreWriter already have a notion of signed intents?** If yes, TradeOnlyAgent wraps the existing signature scheme. If no, this is a greenfield addition.
2. **Should revocation be venue-local or universal?** Universal (via a shared `revokedKeypaths` registry) costs ~0.5 HYPE per revocation across all venues. Venue-local is free but requires keeper revocation on each venue.
3. **Is there a builder allocation carve-out for standards work?** This spec is not a product — it's an on-chain primitive. If Kinetiq wants ecosystem coherence, this is the primitive to fund.

## 10. Reference implementation

A reference Solidity implementation is in `solidity/` (not shipped in this repo, planned for v0.2). The spec is the source of truth; the reference is illustrative.

---

*Generated for the Elysium builder workstream. This spec is intended as an open proposal for Kinetiq, not a product for deployment.*
