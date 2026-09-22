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

- **Domain-separated EIP-712** signature with `domainSeparator = (name="TradeOnlyAgent v1", version="1", chainId=<Elysium>, verifyingContract=address(TradeOnlyAgent))`. The chain ID is the runtime chain ID of the verifier, not a constant — same signature code works on testnet and mainnet.
- The signed message is a `keccak256(abi.encode(DELEGATION_TYPEHASH, keeper, keccak256(abi.encode(assetIds)), maxNotional, maxPerOrder, expiresAt, nonce, salt))`.
- The keeper presents the signature + delegation struct at submit time. The venue calls `TradeOnlyAgent.isValidDelegation(delegator, d, sig)` and either accepts or rejects.
- **`expiresAt == 0` means "no expiry"** — the verifier must short-circuit the expiry check when the field is zero, not treat it as a timestamp in the past.

### Revocation model (resolved)

Revocation is **universal, not venue-local**. The delegator calls
`TradeOnlyAgent.revoke(keeper)` once, which sets a `revokedKeypaths[delegator][keeper] = true` flag on the shared verifier contract. Every venue that calls `isValidDelegation` consults that same flag, so a revoked keeper is rejected on all venues simultaneously.

Rationale: venues are few today (ElysiumCoreWriter) but the cost of a
keeper compromise is high — a compromised keeper could drain balances
across every venue that trusts it. Universal revocation from a single
shared contract is the only model that lets a delegator act on
compromise in one transaction. The cost is one storage write per
revocation (~0.5 HYPE on Elysium); venues that want to track
per-delegation notional can still do so locally via `recordExecution`
(see §4).

## 4. Venue-side adapter (ElysiumCoreWriter integration)

```solidity
// Inside ElysiumCoreWriter, when receiving an intent.
// msg.sender is the keeper; the delegator address is explicit in the call.

function submitIntent(address delegator, Intent calldata intent, Signature calldata sig) external {
    require(msg.sender == intent.delegation.keeper, "not keeper");

    // Universal verifier: checks sig + expiry + caps + universal revocation.
    require(TradeOnlyAgent(VERIFIER).isValidDelegation(delegator, intent.delegation, sig),
            "invalid delegation");

    // Per-order cap (the universal verifier does NOT check maxPerOrder against
    // the intent's notional — that's a venue responsibility, because the
    // verifier has no view of the intent).
    require(intent.notional <= intent.delegation.maxPerOrder, "per-order cap");

    // Venue-local notional tracking. The verifier's recordExecution()
    // deducts from the delegation's remaining cap, keyed by
    // (venue, delegator, keeper, nonce). This means the same delegation
    // can be used on multiple venues without cross-venue accounting —
    // but each venue enforces maxNotional independently, so a single
    // delegation on N venues has an effective ceiling of N × maxNotional.
    // See the "known limitation" note in §9.
    require(TradeOnlyAgent(VERIFIER).remainingNotional(
        address(this), delegator, intent.delegation) >= intent.notional,
        "notional cap exceeded");

    executeOnHyperCore(intent);
    TradeOnlyAgent(VERIFIER).recordExecution(
        address(this), delegator, intent.delegation,
        intent.notional, intent.delegation.salt,
        uint64(block.timestamp)
    );
}
```

The venue is responsible for:
- Verifying the signature against `ITradeOnlyAgent.isValidDelegation`
- Checking `intent.notional <= maxPerOrder` (per-order cap is venue-local)
- Querying `remainingNotional` before executing and calling `recordExecution` after
- Verifying `msg.sender == delegation.keeper` (the venue receives the trade from the keeper, not from the delegator)

The venue does **not** store the delegation struct itself — the keeper presents it each time, and the venue just checks the remaining capacity on the verifier.

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
| **TradeOnlyAgent (this spec)** | **Per delegation** | **Per delegation** | **Universal** (shared verifier) | **Yes** |

The differentiation: TradeOnlyAgent is a **persistent, scoped, revocable** delegation, not a per-order or per-batch authorization. Revocation is universal — a single `revoke(keeper)` on the shared verifier contract invalidates the keeper on every venue simultaneously.

## 8. What's out of scope

- **Fee structure** — venue-level, not part of the standard.
- **Sub-agent delegation** — keeper cannot re-delegate. If that's needed, a new spec.
- **Cross-chain delegation** — signatures are domain-separated by the verifier's `block.chainid`, so a signature valid on Elysium (whatever its chain ID turns out to be) is not valid on HyperEVM (chainId 999) or on any other chain. This is intentional — cross-chain replay of trade delegations would be catastrophic.
- **Governance of revocation** — revocation is per-keeper, immediate, no consensus. A compromised keeper is revoked with a single `revoke(keeper)` call on the shared verifier; that flag is checked by every venue.

## 9. Open questions for Kinetiq

1. **Does ElysiumCoreWriter already have a notion of signed intents?** If yes, TradeOnlyAgent wraps the existing signature scheme. If no, this is a greenfield addition.
2. **Per-venue notional cap is a known limitation.** Because `recordExecution` is venue-local, the same delegation used on N venues has an effective ceiling of N × `maxNotional`. If cross-venue aggregation of the cap is needed, the verifier needs a global `usedNotional` mapping that all venues update — that costs gas on every execution. For the current use case (ElysiumCoreWriter as the only venue, maybe 2-3 more in the future), venue-local tracking is the right tradeoff. Documenting it here so the limitation is explicit.
3. **Is there a builder allocation carve-out for standards work?** This spec is not a product — it's an on-chain primitive. If Kinetiq wants ecosystem coherence, this is the primitive to fund.

## 10. Reference implementation

A reference Solidity implementation is **shipped in this repo**:

- `solidity/src/delegation/TradeOnlyAgent.sol` — the verifier contract, EIP-712, universal revocation, venue-local notional tracking.
- `solidity/src/interfaces/ITradeOnlyAgent.sol` — the public interface.
- `solidity/scripts/verify.py` — ABI + EIP-712 + event verifier (run `python solidity/scripts/verify.py` to confirm).

The spec is the source of truth; the reference is the implementation. They match as of this writing — if the spec changes, the reference must be updated in the same commit. The reference is NOT audited and must not be deployed to mainnet without a formal audit.

---

*Generated for the Elysium builder workstream. This spec is intended as an open proposal for Kinetiq, not a product for deployment.*
