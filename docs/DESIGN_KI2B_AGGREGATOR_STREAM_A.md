# KI-2b — Aggregator Stream-A Delegation Signing

**Status**: design proposal · **Severity**: pre-M3 production blocker (HIGH) · **Blast radius**: `YieldAggregator.sol`, `PerpFundingLeg.sol`, `BasisHedgeLeg.sol`, `IIntentSubmittingLeg.sol` (interface extension) · **Related**: `docs/DESIGN_KI2_SUBMITINTENT.md §4, §9`, `docs/ROADMAP.md §2.5 KI-16`

Not audited. Not to be deployed with real capital.

---

## 1. Problem statement

Round-7 landed Phase 1 of the KI-2 fix: `PerpFundingLeg.submitIntent`
and `BasisHedgeLeg.submitIntent` now accept a real
`(Delegation, Signature)` tuple, verify it against
`TradeOnlyAgent.isValidDelegation`, enforce the venue-local
`maxPerOrder` cap, and forward the signature to the writer. That
closed the *user-driven* (stream B) path — an LP signing a
`keeper = legAddress` delegation and calling `leg.submitIntent(...)`
directly works against a real `ElysiumCoreWriter`.

Phase 2 — the *aggregator-driven* path — is still broken. Every
`PerpFundingLeg.allocateTo`, `.harvest`, `.reduceFrom` call site, and
the three corresponding call sites in `BasisHedgeLeg`, still pass
`_fallbackSig()` — the `Signature({v: 27, r: 0, s: 0})` zero-signature
placeholder. In a MockWriter test rig the venue doesn't inspect the
signature, so the current 171 forge tests pass. Against a real
`ElysiumCoreWriter`, `TradeOnlyAgent._recover`
(`TradeOnlyAgent.sol:165-190`) rejects `r == 0` / `s == 0` outright,
and the writer's delegation gate rejects the intent outright. The
aggregator-driven slow loop is dead on arrival against a real writer.

### The four call sites (round-11 finding #9, round-7 KI-2 deferral)

| # | Location | Context | `_fallbackSig()` used |
|---|---|---|---|
| 1 | `PerpFundingLeg.sol:178` | `allocateTo` → `_writeOpen` | short-perp open |
| 2 | `PerpFundingLeg.sol:198, 201` | `harvest` → `_writeClose` + `_writeOpen` | flip-close then re-open |
| 3 | `PerpFundingLeg.sol:222` | `reduceFrom` → `_writeClose` | pro-rata short close |
| 4 | `BasisHedgeLeg.sol:177` | `allocateTo` → `_writeOpen` | short-perp open |
| 5 | `BasisHedgeLeg.sol:197, 200` | `harvest` → `_writeClose` + `_writeOpen` | flip-close then re-open |
| 6 | `BasisHedgeLeg.sol:221` | `reduceFrom` → `_writeClose` | pro-rata short close |

(The `harvest` path uses two callsites each — close then reopen — but
they're semantically one rebalance action, so they collapse to the
"allocate / harvest / reduce" three buckets per leg; the task brief
counts four call sites per leg as four *actions*, not per writer
call.) The `_fallbackSig()` symbol itself is defined twice
(`PerpFundingLeg.sol:371`, `BasisHedgeLeg.sol:362`).

### Phase 1 → Phase 2 framing

`DESIGN_KI2_SUBMITINTENT.md §9` lays out the three-phase migration:

- **Phase 1 (DONE, round-7)**: additive only. `submitIntent` added
  alongside the existing `allocateTo` / `harvest` / `reduceFrom`.
  `_zeroSig()` renamed to `_fallbackSig()` on the two perp legs and
  is still reachable from the aggregator-only call paths. Existing
  171 forge tests continue to pass against the MockWriter.
- **Phase 2 (this doc, deferred)**: refactor the aggregator's
  `executePending` and `harvestFromAllLegs` to sign a stream-A
  delegation and route through `submitIntent`. Replace
  `_fallbackSig()` with an aggregator-authorized signature throughout
  the leg. Remove the `_fallbackSig()` symbol entirely.
- **Phase 3 (IMPLEMENTED in round-15a)**: rename
  `lastDelegationNonce` → `nextDelegationNonce` (pre-increment
  semantics — the value written into `Delegation.nonce` is the
  pre-increment value, i.e. first call proposes nonce=0), delete
  `bumpNonce()`, add `lastExecutedNonce(delegator, nonce)` view
  keyed by `(delegator, nonce)`. `lastExecutedNonce` is written
  ONLY after a successful `_writeOpen`/`_writeClose` returns inside
  `submitIntent`/`submitIntentFromStreamA` — not from the fallback
  `_writeOpen`/`_writeClose` path (gated by `devFallbackEnabled`,
  uses `_fallbackSig`). See DESIGN_KI2_SUBMITINTENT.md §9 Phase 3
  for the full rationale and `Phase3NonceCleanupTest` in
  `solidity/test/Legs.t.sol` for coverage.

Phase 2 is the gap between the current state and a testnet-deployable
aggregator. Without it, `executePending` on a rebalance that shifts
weight to `PerpFundingLeg` or `BasisHedgeLeg` will revert at the
writer — the *entire* allocation tx atomically (see the round-7
`AllocationExecuted` atomicity observation: the aggregator's
`nonReentrant` guard wraps the whole leg loop). The perp legs are
effectively unreachable from the aggregator against any venue that
verifies signatures.

### Blast radius of the current state

Round-11 is currently shipping the KI-1 rate-tracking fix on
`KHYPELeg.sol` and `SpotStakingLeg.sol`. Those are the two stake
legs; they never call the writer, so this doc's problem is
orthogonal and the two tracks do not collide. The four call sites in
§1 are in `PerpFundingLeg.sol` and `BasisHedgeLeg.sol` only.

---

## 2. Design space

The aggregator has two roles in the Option C hybrid model
(`DESIGN_KI2_SUBMITINTENT.md §4`):

- **Keeper identity on stream A** — the aggregator itself signs
  delegation envelopes with `keeper = address(aggregator)`; the
  writer accepts them on the aggregator's behalf. This is the fast
  loop that produces alpha (see `AGGREGATOR_SPEC.md §3.5`).
- **Caller identity on stream B** — the aggregator may also submit
  stream-B delegations on behalf of a share-holding LP (via the leg
  as keeper), but this is optional and not required for
  aggregator-driven rebalances.

The design question is: how does the aggregator obtain a valid
`(Delegation, Signature)` tuple with `keeper = address(aggregator)`
that the writer will accept, given that the aggregator is a *contract*
and cannot sign on-chain?

### Option A — aggregator contract signs as keeper

The aggregator's constructor takes a `TradeOnlyAgent` reference and
attempts to sign a delegation with `keeper = address(aggregator)`
from within the aggregator itself.

- **Pro**: single keeper identity, single delegation per rebalance,
  matches the FIX-21 revoke model exactly (`revoke(aggregator)`
  cleanly halts every stream-A delegation).
- **Con**: a contract cannot sign EIP-712 messages. `ecsign` on a
  contract returns `(0, 0, 0)` — there is no key material on-chain.
  The only EIP-712 signers are EOAs (or wallets that front an EOA).
  **This option is not implementable.** Listed for completeness.

### Option B — off-chain keeper signs, aggregator submits (recommended)

The off-chain keeper (an EOA or keeper-relay operated by the vault
operator) signs a stream-A delegation with `keeper = address(aggregator)`
*off-chain* and calls a new aggregator entry point:

```solidity
function executePendingWithStreamA(
    ITradeOnlyAgent.Delegation calldata d,
    ITradeOnlyAgent.Signature calldata sig
) external nonReentrant onlyKeeper;
```

The aggregator verifies the signature itself (a redundant belt over
the writer's own verification — the writer would reject an invalid
sig, but failing fast at the aggregator lets us skip the writer's
gas-expensive setup when the signature is bad), then routes each
perp leg's intent through `leg.submitIntent(d, sig, delta)` with the
leg treating the aggregator as its authorized caller. Staking legs
go through the existing `leg.allocateTo(delta)` unchanged.

- **Pro**: the keeper already signs an allocation request per
  rebalance; adding a single delegation signature is marginal work.
  The aggregator stays passive — it doesn't hold any signing key, so
  there's no new secret to compromise. Revocation is one handle:
  `revoke(aggregator)` from the delegator kills every stream-A
  delegation regardless of how many nonces were pre-signed.
- **Pro**: FIX-21 revoke-survives-never-expires applies cleanly.
  Stream-A delegations use a short `expiresAt` (typically 1 hour),
  so they're naturally scoped to one rebalance.
- **Con**: the off-chain keeper becomes a *hot path* dependency —
  every rebalance requires a fresh keeper signature. If the keeper
  is offline during the timelock window, `executePending` blocks
  (though the timelock itself still expires and `pendingAllocationId`
  can be cancelled).
- **Con**: the aggregator keeper is the *same address* as the aggregator
  `keeper` role today. That's fine on its own (it already calls
  `requestAllocation`), but it means the off-chain keeper must now
  hold a signing key that is authorized to spend up to
  `d.maxNotional` of the delegator's notional cap. Compromising the
  keeper compromises not just allocation weights but also the
  delegator's cap spend against every venue the delegator has keyed
  the keeper to. This is the same trust assumption as today's
  allocation requests, just with a real cap attached.

### Option C — aggregator verifies the signature itself (belt-and-braces)

Same call flow as Option B, but the aggregator calls
`TradeOnlyAgent.isValidDelegation(delegator, d, sig)` *before*
calling the leg, and additionally checks the aggregate notional
cap:

```solidity
require(
    tradeOnlyAgent.isValidDelegation(delegator, d, sig),
    "invalid stream-A delegation"
);
uint256 remaining = tradeOnlyAgent.remainingNotional(
    address(this), delegator, d
);
require(remaining >= totalDelta, "cap exceeded");
```

The leg's `submitIntent` then re-verifies the signature on its own
path (because the leg's verifier call is what binds the sig to the
writer call).

- **Pro**: aggregator-side verification is fast-fail; a bad
  signature never touches the leg's storage (`submittedIntents`,
  `nextDelegationNonce`), and no writer gas is burned on a doomed
  call. Also lets the aggregator enforce a *delegator-level* cap
  aggregate (`remainingNotional` across all four legs in one view
  call) before routing to individual legs.
- **Con**: duplicate verifier work. The leg's `submitIntent` already
  calls `tradeOnlyAgent.isValidDelegation` per `DESIGN_KI2_SUBMITINTENT.md §5.4`,
  so the same EIP-712 recovery runs twice per intent. Gas cost is
  small (`isValidDelegation` is ~15k gas, `ecrecover` ~3k, plus
  lookup overhead), but it's duplicated and it adds a new external
  call to the aggregator's already-heavy slow-loop path.
- **Con**: the aggregate-cap check is subtle. `remainingNotional`
  keys on `(venue, delegator, keeper, nonce)` and the venue is
  `msg.sender` at the verifier call — but the aggregator is the
  caller, not the writer, so the venue address would be the
  aggregator, not the venue the intent actually routes to. That
  means the aggregator's `remainingNotional` query does *not*
  reflect the venue-local cap the writer will enforce — it reflects
  a phantom venue keyed by `address(aggregator)` in the verifier's
  `usedNotional` mapping. This is either a bug or a deliberate
  double-ledger; either way it's confusing. **Recommend against
  the aggregate-cap check in the aggregator; keep it in the leg.**

### Option D — aggregator acts as user, no stream A

The aggregator treats itself as a *user* calling `leg.submitIntent(d, sig, amount)`
where the LP signs with `keeper = legAddress` (stream B). No stream A
at all — every aggregator-driven rebalance requires a fresh LP
signature per leg-action.

- **Pro**: reuses the existing stream-B code path entirely; the
  aggregator never needs to hold or verify a stream-A delegation.
  The two-speed model collapses to one-speed (LP-driven).
- **Con**: UX regression. Every rebalance requires N LP signatures
  (one per leg-action the rebalance produces), and each LP's
  signature is only valid for a specific `keeper = legAddress`
  they chose. The two-speed framing in `AGGREGATOR_SPEC.md §3.5` —
  the fast loop producing the +0.5-1% alpha — goes away; the
  aggregator becomes purely LP-driven, which is a documented design
  change (not a bug, but a UX contract break).
- **Con**: revocation semantics get worse. Stream-B revocation is
  per-leg (each LP revokes each leg independently), so a delegated
  keeper compromise that today would be halted by `revoke(aggregator)`
  (single handle, kills all stream-A activity) would require
  `revoke(leg_i)` × 4 for each leg, and even then only if the LP
  has not revoked the aggregator from the delegation. This is a
  FIX-21 concern that stream B alone does not address.

### 2.1 Comparison

| Property | Option A | Option B | Option C | Option D |
|---|---|---|---|---|
| Aggregator must sign on-chain | Yes | No | No | No |
| Aggregator can actually sign | **No** (contract, no key) | n/a | n/a | n/a |
| Keeper identity for stream A | aggregator | aggregator | aggregator | none (LP signs stream B per leg) |
| Aggregator-side verifier call | — | Optional | Mandatory | — |
| Duplicate verification work | — | No | Yes (belt) | No |
| FIX-21 single-handle revoke | Yes | Yes | Yes | No (per-leg) |
| Aligns with two-speed framing | Yes | Yes | Yes | No |
| UX regression | No | Marginal (keeper signs once per rebalance) | Same as B | Yes (LP signs per rebalance) |
| Implementable today | **No** | Yes | Yes | Yes |
| Churn | Medium | Low-Medium | Medium | High (interface change) |

Option A is ruled out (unimplementable). Option D regresses the
documented two-speed design. The choice is between B and C; the
difference is whether the aggregator redundantly verifies the
signature (C) or defers to the leg's existing verification (B).

---

## 3. Recommended option — **B**

Option B is the recommended option. Rationale:

1. **The aggregator is a contract and cannot sign.** Option A is
   literally unimplementable in EVM Solidity. Only EOAs can produce
   EIP-712 signatures on-chain; a contract's `ecrecover` input
   would always be `(r, s, v) = (0, 0, 27)`, which is exactly the
   placeholder value KI-2 eliminated.
2. **The keeper already signs off-chain.** The aggregator's keeper
   role today is an EOA (or keeper-relay) that calls
   `requestAllocation` and `harvestFromAllLegs` from the off-chain
   loop. Adding a delegation signature to that same off-chain flow
   is a marginal operation; no new secret material, no new
   infrastructure.
3. **Option C's aggregate-cap check has a subtle bug.** The
   `remainingNotional` call from the aggregator keys on the
   aggregator's address as `venue`, but the writer will execute
   against the venue address (the leg, or the writer itself — see
   `TradeOnlyAgent.sol:34-37`). So the aggregator's
   `remainingNotional` view would not match what the writer
   actually enforces. Option B skips this by deferring to the leg's
   verifier call (which is what binds the sig to the writer call
   today).
4. **FIX-21 revoke semantics are preserved.** Stream-A delegations
   have `keeper = address(aggregator)`. A single
   `revoke(aggregator)` from the delegator halts every stream-A
   delegation simultaneously on every venue, regardless of nonce.
   The two-speed framing in `AGGREGATOR_SPEC.md §3.5` is preserved
   end-to-end.
5. **Blast radius is small.** One new aggregator entry point
   (`executePendingWithStreamA`), one new internal `_distributeStreamA`
   helper, one `submitIntent` authorizer tweak on each perp leg
   (allow `msg.sender == address(aggregator)`), and removal of
   `_fallbackSig()` from both legs. `IYieldLeg` unchanged,
   `TradeOnlyAgent` unchanged, `ElysiumCoreWriter` unchanged,
   staking legs unchanged.

The one real trade-off is the off-chain keeper dependency. Under
Option B, every aggregator-driven rebalance requires a fresh keeper
signature over a stream-A delegation. If the keeper is offline for
the 24h timelock window, `executePending` blocks (the pending
allocation stays queued and can be cancelled, or executed later
with a fresh signature — but the rebalance doesn't happen until
then). That is an acceptable trade-off because:

- The keeper is already a hot-path dependency for `requestAllocation`
  and `harvestFromAllLegs`.
- The aggregator has an `owner`-gated recovery path:
  `setPaused(true)` halts all paths, and `setKeeper(newKeeper)`
  swaps in a fresh keeper.
- The `pendingAllocationId` is preserved while the keeper is
  offline, so the allocation request itself isn't lost — just
  deferred.

**Recommendation locked: Option B.** The alternative (Option C) is
defensible but pays duplicate-verifier-gas for no observable safety
gain; the aggregate-cap check it enables has a subtle venue-key bug
that would need its own fix before it could be deployed.

---

## 4. Detailed flow

### 4.1 Signer side (off-chain keeper)

Per aggregator-driven rebalance epoch, the off-chain keeper:

1. Computes the desired weight delta from the pending allocation
   (`pendingAllocationId` events + leg `currentValue()` reads).
2. For each perp leg that will receive a positive delta:
   - Sets `d.keeper = address(aggregator)`.
   - Sets `d.assetIds = [HYPE_ASSET_ID]` (or `[1]` per the current
     `HYPE_ASSET_ID = 1` placeholder; confirm with Kinetiq at M3).
   - Sets `d.maxNotional = <total perp leg delta for this epoch>`.
   - Sets `d.maxPerOrder = <per-leg perp delta>` (so the writer
     will enforce per-order cap automatically per leg).
   - Sets `d.expiresAt = block.timestamp + 1h` (short-lived, per
     the Option C two-speed framing in
     `DESIGN_KI2_SUBMITINTENT.md §4`).
   - Sets `d.nonce = <unique per rebalance>` (kept by the keeper
     as an off-chain counter, or derived from a block-height +
     timelock hash).
   - Sets `d.salt = <random 32 bytes>` (per delegation, defeats
     cross-epoch replay of the same nonce).
3. Signs the resulting `Delegation` envelope using EIP-712 with the
   delegator's private key (or a keeper-key that the delegator has
   authorized to sign stream-A intents — see §4.4 for the
   keeper-vs-delegator identity question).
4. Calls `aggregator.executePendingWithStreamA(d, sig)` from the
   same tx that flips the pending allocation's `executesAt`.

### 4.2 Aggregator side — new entry point

```solidity
function executePendingWithStreamA(
    ITradeOnlyAgent.Delegation calldata d,
    ITradeOnlyAgent.Signature calldata sig
) external nonReentrant onlyKeeper {
    require(pendingAllocationId != bytes32(0), "nothing pending");
    require(block.timestamp >= _pending.executesAt, "not yet");
    require(d.keeper == address(this), "stream-A keeper mismatch");

    // Optional belt (Option C lite): pre-check that the cap is
    // sufficient for the sum of deltas we're about to route.
    // Note: this is advisory — the leg's own submitIntent does
    // the authoritative verification against the writer's venue key.
    uint256 totalAssetsNow = totalAssets();
    uint16[4] memory oldW = _weights;
    uint256 perpDeltaTotal = 0;
    for (uint i = 0; i < 4; i++) {
        if (!_isPerpLeg(i)) continue;
        uint256 oldTarget = (totalAssetsNow * oldW[i]) / BPS_DENOM;
        uint256 newTarget = (totalAssetsNow * _pending.weights[i]) / BPS_DENOM;
        if (newTarget > oldTarget) perpDeltaTotal += newTarget - oldTarget;
    }
    require(perpDeltaTotal <= d.maxNotional, "stream-A cap below rebalance delta");

    _weights = _pending.weights;
    bytes32 id = pendingAllocationId;
    pendingAllocationId = bytes32(0);
    _pending = PendingAllocation({
        weights: [uint16(0),uint16(0),uint16(0),uint16(0)],
        executesAt: 0, reason: ""
    });

    uint256 newAllocTotal = 0;
    for (uint i = 0; i < 4; i++) {
        uint256 oldTarget = (totalAssetsNow * oldW[i]) / BPS_DENOM;
        uint256 newTarget = (totalAssetsNow * _weights[i]) / BPS_DENOM;
        if (newTarget > oldTarget) {
            uint256 delta = newTarget - oldTarget;
            if (_isPerpLeg(i)) {
                // Stream A: aggregator submits via submitIntent with
                // the leg as authorized caller. Keeper identity
                // is the aggregator; the leg's submitIntent must
                // allow msg.sender == address(this) as an
                // authorized stream-A caller.
                IIntentSubmittingLeg(IYieldLeg(i)).submitIntent(d, sig, delta);
            } else {
                // Staking leg: existing path, no writer call.
                asset_.safeTransfer(address(legs[i]), delta);
                legs[i].allocateTo(delta);
            }
            newAllocTotal += delta;
        } else if (oldTarget > newTarget) {
            uint256 delta = oldTarget - newTarget;
            // ReduceFrom doesn't need a writer call in the spot
            // direction; perp reduceFrom goes through the same
            // stream-A path as allocateTo (a close intent).
            uint256 reduced = legs[i].reduceFrom(delta);
            // TODO: for perp legs, this becomes a reduceIntent
            // (close position with the same stream-A delegation).
            // Tracked as Phase 2.5 follow-up.
            newAllocTotal -= reduced;
        }
    }
    _allocatedTotal += newAllocTotal;
    emit AllocationExecuted(id, _weights);
}
```

### 4.3 Leg side — authorized aggregator caller

`PerpFundingLeg.submitIntent` and `BasisHedgeLeg.submitIntent`
currently require `msg.sender == delegator || msg.sender == owner`.
Under Option B the aggregator becomes an authorized caller:

```solidity
// BEFORE (current, KI-2 Phase 1)
require(
    msg.sender == delegator || msg.sender == owner,
    "not authorized"
);

// AFTER (KI-2b Phase 2)
require(
    msg.sender == delegator
    || msg.sender == owner
    || msg.sender == aggregator,   // stream-A aggregator forwarding
    "not authorized"
);
```

Where `aggregator` is a new `immutable` field set in the leg's
constructor (or derived from `owner` if the aggregator is deployed
by the leg's owner). Under stream A the delegation has
`d.keeper == address(aggregator)`, but the leg's `submitIntent`
currently requires `d.keeper == address(this)` (stream B). Phase 2
needs to allow stream A:

```solidity
// BEFORE
require(d.keeper == address(this), "keeper is not this leg");

// AFTER
require(
    d.keeper == address(this) || d.keeper == aggregator,
    "keeper not this leg or aggregator"
);
```

### 4.4 Keeper-vs-delegator identity

Under Option B, two addresses appear in the delegation:

- `d.keeper = address(aggregator)` — the venue-side identity that
  the writer will check against `msg.sender`.
- `d.from` (implicit in the EIP-712 digest, `_delegationHash`) —
  the address whose signature authorized the delegation.

The signer (off-chain keeper) is not necessarily `d.from`. In the
current reference implementation of `TradeOnlyAgent._recover`,
`d.from` is the delegator (the address who signed the EIP-712 digest).
Two operational models:

- **Model 1: delegator = keeper**. The same EOA that signs allocation
  requests is also the delegator who signs stream-A delegations.
  Simple; one secret, one signer. Fine for the reference testnet
  but not for production where the delegator and keeper are usually
  different roles.
- **Model 2: delegator signs stream-A intents, keeper submits**.
  A separate "delegator EOA" signs `(d, sig)` off-chain and passes
  `(d, sig)` to the keeper (via a keeper-relay or a signing service
  like Fireblocks). The keeper then submits to
  `aggregator.executePendingWithStreamA`. This is the production
  target. Requires the keeper to have code access to consume the
  delegator's signature, which is what `executePendingWithStreamA(d, sig)`
  provides.

Both models work; the current reference test uses Model 1
(simpler), production should use Model 2.

### 4.5 Nonce management

The keeper's `d.nonce` counter is off-chain, one nonce per rebalance
epoch. The aggregator does not advance `nextDelegationNonce` (that
field is leg-local, per `DESIGN_KI2_SUBMITINTENT.md §6`, and is
only ever used by `_nextDelegation()` inside the leg's Phase-1
`allocateTo` / `harvest` / `reduceFrom` paths — which are being
removed in Phase 2 anyway). Phase 3 (see §7) cleans up the leftover
`nextDelegationNonce` storage field and removed the `bumpNonce()`
symbol — done in round-15a. The leg-local nonce advances
monotonically across `_nextDelegation()` calls and rolls back on
revert (Solidity atomic semantics), so a `_nextDelegation()` call
whose downstream writer call reverts leaves `nextDelegationNonce`
unchanged.

---

## 5. What changes

### 5.1 `YieldAggregator.sol`

New methods (additive, existing methods retained for staking-leg
flows):

- `executePendingWithStreamA(Delegation, Signature)` — the new
  stream-A rebalance path. Runs the same weight-application logic
  as `executePending` but routes perp-leg allocations through
  `leg.submitIntent(d, sig, delta)` and perp-leg reductions through
  `leg.reduceIntent(d, sig, delta)` (new method on
  `IIntentSubmittingLeg`, see §5.3).
- `harvestFromAllLegs(Delegation, Signature)` — new overload that
  accepts a stream-A delegation for the perp-leg harvest. The
  existing `harvestFromAllLegs()` (no args) is retained and
  continues to work for staking legs only; it should be gated by
  a new internal check that no perp leg has any open position
  when called without a stream-A delegation. (In practice the
  existing tests never mix — the aggregator's `legs[]` array is
  set at constructor time and the perp legs' positions live
  independently — but a defensive guard here prevents the case
  where a keeper calls the old method after adding a perp leg to
  the deployment.)
- `_distribute(uint256)` is unchanged (staking legs go through
  the existing path).
- `_isPerpLeg(uint256 i)` internal helper: returns
  `type(IIntentSubmittingLeg).is(address(legs[i]))` (interface
  check via the existing `supportsInterface` mechanism, or a
  per-leg `isPerp()` view method if the interface check is too
  slow).

### 5.2 `PerpFundingLeg.sol`, `BasisHedgeLeg.sol`

- `allocateTo`, `harvest`, `reduceFrom` — **refactored to call
  `_submitIntentForAggregator(...)` internally**. Under Phase 2
  these methods become thin wrappers that require a stream-A
  delegation to be in-flight (a transient state set by
  `executePendingWithStreamA` before the leg call), and forward
  to `submitIntent(d, sig, amount)`. The `owner`-only check stays
  (the aggregator is `owner` of the leg). The `_fallbackSig()`
  call sites are deleted.
- `_fallbackSig()` — **removed entirely**. This closes finding #9
  from the round-9 adversarial review.
- `_nextDelegation()` — kept for Phase 1's `allocateTo`
  fallback path until Phase 2 lands; removed in Phase 3 (see
  §7).
- New constructor arg `address aggregator` (or derive from owner).

### 5.3 `IIntentSubmittingLeg.sol`

The interface gains two methods:

```solidity
interface IIntentSubmittingLeg {
    // Existing (stream B, unchanged):
    function submitIntent(
        ITradeOnlyAgent.Delegation calldata d,
        ITradeOnlyAgent.Signature calldata sig,
        uint256 amount
    ) external returns (uint256);

    // New (stream A, aggregator-only caller):
    /// Aggregator-driven allocation. d.keeper == address(aggregator);
    /// msg.sender must be the aggregator address (checked inside
    /// submitIntent via a new `aggregator` field on the leg).
    function allocateFromStreamA(
        ITradeOnlyAgent.Delegation calldata d,
        ITradeOnlyAgent.Signature calldata sig,
        uint256 amount
    ) external onlyAggregator returns (uint256);

    /// Aggregator-driven reduction (close perp position).
    function reduceIntent(
        ITradeOnlyAgent.Delegation calldata d,
        ITradeOnlyAgent.Signature calldata sig,
        uint256 amount
    ) external onlyAggregator returns (uint256);

    function harvestIntent(
        ITradeOnlyAgent.Delegation calldata d,
        ITradeOnlyAgent.Signature calldata sig
    ) external onlyAggregator;
}
```

The `submitIntent` method is unchanged; the new `*Intent` methods
are aggregator-only and are internally thin wrappers over the same
writer-call code.

### 5.4 Not changing

- `TradeOnlyAgent.sol` — unchanged. FIX-21 already covers
  never-expires revoke; FIX-14 caps are venue-keyed; per-order cap
  is enforced.
- `ElysiumCoreWriter.sol` (interface) — unchanged. Already takes
  `(assetId, side, notional, delegator, d, sig)`.
- `IYieldLeg.sol` — unchanged. Staking legs never call the writer.
- `KHYPELeg.sol`, `SpotStakingLeg.sol` — unchanged (round-11 is
  working on their KI-1 rate-tracking fix independently).
- `check_repo.py`, `deploy.py`, `test_deploy_anvil.py` — unchanged.

---

## 6. Test plan

New tests live in `solidity/test/YieldAggregator.t.sol`
(aggregator-side) and `solidity/test/Legs.t.sol` (leg-side).

### 6.1 Aggregator-side tests (`YieldAggregator.t.sol`)

| # | Test | Setup | Assertion |
|---|---|---|---|
| 1 | `test_executePendingWithStreamA_routesPerpLegsThroughSubmitIntent` | Setup: aggregator with 2 perp legs + 2 staking legs; pending allocation shifts weight from staking to perp. Keeper calls `executePendingWithStreamA(d, sig)` with `d.keeper == address(aggregator)`, `d.maxNotional >= rebalance_delta`, `d.maxPerOrder == per_leg_delta`. | MockWriter sees N calls where N = 1 per perp-leg open; every invocation has `d.keeper == address(aggregator)`; every invocation's `d.nonce == d.nonce` (same delegation reused across legs, capped per venue); staking legs still see `allocateTo(delta)` (not `submitIntent`). |
| 2 | `test_executePendingWithStreamA_reverts_onInvalidSig` | Bad signature (wrong nonce, wrong r/s, non-canonical). | Reverts before touching any leg. MockWriter is not called. |
| 3 | `test_executePendingWithStreamA_reverts_onWrongKeeper` | `d.keeper = address(someOtherKeeper)` not the aggregator. | Reverts `"stream-A keeper mismatch"`. |
| 4 | `test_executePendingWithStreamA_reverts_whenDelegatorExpired` | `d.expiresAt = block.timestamp - 1` (already expired). | Reverts at the aggregator's own `isValidDelegation` belt check (if Option C lite is adopted) or at the leg's `submitIntent` verifier call. |
| 5 | `test_executePendingWithStreamA_reverts_whenCapBelowRebalanceDelta` | `d.maxNotional < total perp delta`. | Reverts at aggregator before touching any leg. |
| 6 | `test_executePendingWithStreamA_reusesSameDelegationAcrossMultipleLegs` | Two perp legs both receiving positive delta, same `d` used for both. | Each leg's `submitIntent` accepts; MockWriter sees two invocations with the same `d` (different `msg.sender` at the writer since each leg is the caller — but the same `d.keeper` = aggregator). Fixture for FIX-14's per-venue isolation: `usedNotional` at venue=leg1 has one entry, `usedNotional` at venue=leg2 has a separate entry. |
| 7 | `test_executePending_stillWorksForStakingLegsOnly` | Existing aggregator with only staking legs; pending allocation shifts within staking legs. Keeper calls the *old* `executePending()`. | Works unchanged — no stream-A delegation needed. Regression test. |
| 8 | `test_harvestFromAllLegs_streamAPath_worksOnPerpLegs` | Aggregator with perp legs holding positions; keeper calls `harvestFromAllLegs(d, sig)`. | MockWriter sees `closePosition` calls with `d.keeper == aggregator`; realised USDC is swept to the vault. |

### 6.2 Leg-side tests (`Legs.t.sol`)

| # | Test | Setup | Assertion |
|---|---|---|---|
| 9 | `test_perpLeg_submitIntent_allowsAggregatorCaller` | Aggregator calls `leg.submitIntent(d, sig, delta)` where `d.keeper == address(aggregator)` and `msg.sender == address(aggregator)`. | Accepts (unlike stream-B which requires `d.keeper == leg`). |
| 10 | `test_perpLeg_submitIntent_rejectsStreamBIfKeeperIsAggregator` | A non-aggregator caller submits `d.keeper == address(aggregator)`. | Reverts `"not authorized"` — the aggregator is the only allowed caller for stream-A delegations. |
| 11 | `test_fallbackSigGone` | Compile-time: `_fallbackSig` no longer appears in either perp leg. | grep-based check in `verify.py` (extend existing). Regression against KI-2b Phase 2 completion. |
| 12 | `test_harvest_intent_routesCloseAndOpenUnderStreamA` | Keeper calls `harvestIntent(d, sig)` on a perp leg with an open short. | MockWriter sees a `closePosition` and then an `openPosition` under the same `d`, in the same tx. |
| 13 | `test_reduceIntent_partial` | Keeper calls `reduceIntent(d, sig, amount)` where `amount < perpNotional`. | MockWriter sees a `closePosition` for `amount`; `perpNotional` decreases by exactly `amount`. |

### 6.3 Regression tests

- Existing 171 forge tests should continue to pass without
  modification. The existing aggregator tests use `executePending()`
  (no args) which is retained unchanged; the existing leg tests
  use `allocateTo(amount)` (no args) which is *not* retained —
  those tests need to be updated to use the new stream-A path, OR
  the aggregator can synthesize a "test-only" delegation internally
  that satisfies the delegation check (see §6.4).
- `TradeOnlyAgent.t.sol` tests unchanged.
- `FuzzCoverage.t.sol` fuzz tests unchanged; the aggregator's new
  `executePendingWithStreamA` is not fuzzed (the EIP-712 signature
  is off-chain, so fuzzing the aggregator path requires a signing
  helper that we don't have in the fuzz suite yet).

### 6.4 Test-mock concern

The existing leg tests call `leg.allocateTo(amount)` directly from
the test EOA (as the owner). Under Phase 2, `allocateTo` is no
longer an entry point that works without a stream-A delegation.
Two options:

- **Keep `allocateTo` as an owner-only test-mode wrapper.** The
  aggregator checks `owner != address(aggregator)` at constructor
  time (test-mode flag) and preserves the current `allocateTo`
  behavior on the test-mode path. Production deployments require
  the aggregator to be `owner` of the leg, which turns on the
  stream-A path.
- **Update all 15 leg tests** to call `submitIntent` directly with
  a pre-signed `(d, sig)` pair. Requires a signing helper in the
  forge test harness (or a `vm.sign` helper via forge-std).

**Recommendation: option 1 for Phase 2**, so existing leg tests
continue to pass unchanged. The test-mode wrapper is `private` and
gated by an `isTestMode` bool set at construction (default `false`
in production, `true` when the leg's owner is the test EOA). Phase 3
can remove the wrapper if desired.

---

## 7. Blast radius

| Component | Touched? | Change |
|---|---|---|
| `YieldAggregator.sol` | **Yes** | New `executePendingWithStreamA(Delegation, Signature)`, new `harvestFromAllLegs(Delegation, Signature)`, new internal `_isPerpLeg(i)`, new `_distributeStreamA` helper. Existing `executePending()`, `harvestFromAllLegs()`, `_distribute` retained unchanged for staking-leg flows. |
| `PerpFundingLeg.sol` | **Yes** | `allocateTo`, `harvest`, `reduceFrom` refactored to route through `submitIntent` with a stream-A delegation in-flight. `_fallbackSig()` removed (closes round-9 finding #9). `_nextDelegation()` retained for Phase 2 but unused in production paths (removed in Phase 3). New constructor arg `address aggregator`. |
| `BasisHedgeLeg.sol` | **Yes** | Same as `PerpFundingLeg`. |
| `IIntentSubmittingLeg.sol` | **Yes** | New `allocateFromStreamA`, `reduceIntent`, `harvestIntent` methods (or unified into `submitIntent` with a mode bit). |
| `IYieldLeg.sol` | No | Base interface unchanged. |
| `TradeOnlyAgent.sol` | No | FIX-21 and FIX-14 already cover the needed semantics; `remainingNotional` and `recordExecution` unchanged. |
| `IElysiumCoreWriter.sol` | No | Already takes `(d, sig)` per intent. |
| `KHYPELeg.sol`, `SpotStakingLeg.sol` | No | Staking legs never call the writer. Independent track (round-11 KI-1 rate-tracking). |
| `solidity/test/YieldAggregator.t.sol` | **Yes** | 8 new aggregator tests (§6.1). |
| `solidity/test/Legs.t.sol` | **Yes** | 5 new leg tests (§6.2). Existing 15 leg tests may need minor updates per §6.4. |
| `solidity/scripts/verify.py` | **Yes** | Add grep that `_fallbackSig` does not appear in any leg (parallel to the existing `_zeroSig` grep that round-7 added). |
| `check_repo.py` | No | Not modified per task constraints. |
| `deploy.py` / `test_deploy_anvil.py` | No | Not modified per task constraints. |
| Docs | **This file** | Plus a forward-reference in `DESIGN_KI2_SUBMITINTENT.md §9.2` and a KI-16 row in `ROADMAP.md §2.5`. |

---

## 8. Migration risk

The three-phase plan in `DESIGN_KI2_SUBMITINTENT.md §9` still
applies. This doc is Phase 2 in isolation; the other two phases
remain per the parent doc.

### 8.1 Phase 2 rollout

1. Deploy the updated `PerpFundingLeg.sol` and
   `BasisHedgeLeg.sol` alongside the aggregator (or upgrade in
   place via a future governance-gated setter; not present today).
   The `_fallbackSig()` symbol is removed at compile time; the
   round-7 leg tests that exercised `allocateTo` directly will
   need updating (see §6.4).
2. Deploy the updated `YieldAggregator.sol`. The new
   `executePendingWithStreamA(Delegation, Signature)` entry point
   is additive; the old `executePending()` continues to work.
3. Governance gate: `executePending` refuses to shift any weight
   to a perp leg unless `MockWriter.isProduction()` returns true
   (or the deploy-time flag from the parent doc's §9 is set).
   Staking-leg-only rebalances continue to work via the old path.

### 8.2 Rollback

Reverting KI-2b (Phase 2) is a **safe rollback against MockWriter
tests**, and **unsafe rollback against a real writer**:

- Rollback restores `_fallbackSig()` in both perp legs, restoring
  the current broken-in-production state. That is a status quo, not
  a regression — but it means the perp legs are still non-production
  after rollback.
- Rollback also removes the aggregator's `executePendingWithStreamA`
  path; the aggregator reverts to `executePending()` which cannot
  route through a stream-A delegation. Any in-flight pending
  allocations that were requested under the Phase-2 model will need
  to be cancelled via `cancelPending`.

Rollback is only useful in the sense that the repo returns to a
compilable state. It does *not* restore any production functionality
that wasn't there before — because there was none. The right
forward path is Phase 2 → Phase 3, not Phase 2 → rollback.

### 8.3 Migration risk table

| Risk | Mitigation |
|---|---|
| Keeper offline during timelock window | `cancelPending` is available; `pendingAllocationId` is preserved; `setKeeper` swaps in a fresh keeper. |
| Keeper compromise (holds signing key + aggregator keeper role) | `revoke(aggregator)` from the delegator halts every stream-A delegation simultaneously (FIX-21). Also `setPaused(true)` + `setKeeper(newKeeper)` as a governance-layer stop-gap. |
| Delegator compromise | Delegator has already given the keeper authority to sign stream-A intents; there's no further containment. Accept as a governance-level trust assumption. |
| Leg's `submitIntent` accepts a stream-A delegation from a non-aggregator caller | Leg checks `msg.sender == aggregator` before accepting. Test #10 in §6.2 guards this. |
| Same `(d, sig)` replayed across two legs | Leg's `submittedIntents[keccak(keeper, nonce, salt)]` is per-leg; FIX-14's per-venue cap (`usedNotional[venue]`) is also per-leg. Both provide replay protection. Test #6 in §6.1 exercises this. |
| `_fallbackSig` still reachable via `allocateTo` in test mode | Test-mode wrapper is gated by an `isTestMode` bool defaulting to `false` in production. Regression test #11 in §6.2 guards the compile-time removal in the production path. |
| Aggregator `submitIntent` fails on one leg, succeeds on another | Each `submitIntent` call is independent; a failure on leg i rolls back leg i only if the aggregator reverts entirely (which is the current atomicity model — the aggregator's `nonReentrant` guard wraps the whole loop, so any single leg failure reverts the entire tx). No new atomicity concern; the existing model applies. |
| Staking-leg aggregator tests that call `executePending` (no stream-A) after the aggregator is deployed alongside perp legs | The `executePending()` (no args) path is retained unchanged; it only routes through `allocateTo` / `reduceFrom`, which under Phase 2 are the test-mode wrappers on perp legs (see §6.4). If a test deploys an aggregator with all-staking legs, no stream-A delegation is ever needed and no code path is affected. |

---

## 9. Verification

This is a **DESIGN document**. Implementation is deferred to a
follow-up commit (round-13 agent, TBD).

- **Status**: pending review. The design is ready for approval but
  has not been implemented in this round.
- **Owner for implementation**: a future agent in the round-13
  workstream (the round-11 agent is occupied with the KI-1
  rate-tracking fix on stake legs; round-12 is this doc).
- **Expected implementation scope**: ~150 lines of Solidity changes
  across three files (`YieldAggregator.sol`, `PerpFundingLeg.sol`,
  `BasisHedgeLeg.sol`), plus ~1 interface addition
  (`IIntentSubmittingLeg.sol`), plus ~13 new tests across two test
  suites, plus 1 new grep in `verify.py`.
- **Verification gate**: all new tests pass, all existing tests pass
  (no regression), `check_repo.py` 0 FAIL, `forge test` green across
  the full 171+ test suite.

If the design is approved as-is, the implementation commit will:

1. Refactor `PerpFundingLeg.sol` and `BasisHedgeLeg.sol` per §5.2.
2. Remove `_fallbackSig()` from both legs (closes round-9 finding #9).
3. Add `executePendingWithStreamA` and `harvestFromAllLegs(Delegation, Signature)`
   to `YieldAggregator.sol` per §5.1.
4. Extend `IIntentSubmittingLeg.sol` per §5.3.
5. Add the 13 new tests from §6.1 and §6.2.
6. Update `docs/DESIGN_KI2_SUBMITINTENT.md §9` to mark Phase 2 as
   implemented with a pointer to this doc's decision record.
7. Update `docs/ROADMAP.md §2.5` KI-16 row status from "design only"
   to "FIXED in round-13" (or the round number where the
   implementation lands).
8. Update `docs/ROADMAP.md §5` Leg TODOs table to strike the
   "add submitIntent" TODO for `PerpFundingLeg` (already struck in
   round-7 for Phase 1; no change needed for Phase 2 since the
   Phase-1 row already says "DONE").
9. Update `solidity/scripts/verify.py` to add the `_fallbackSig`
   grep.

---

## 10. Decision record

**This is a DESIGN document. Implementation is deferred to a
follow-up commit (round-13).**

- **Decision**: KI-2b is the recommended completion of the KI-2
  story. Option B (off-chain keeper signs, aggregator submits) is
  recommended. If KI-2b is not implemented, the perp legs remain
  permanently non-production — every aggregator-driven allocation to
  `PerpFundingLeg` or `BasisHedgeLeg` will revert at the writer,
  killing the aggregator's entire fast-loop alpha claim
  (`AGGREGATOR_SPEC.md §3.5`, §4). The repo's current claim of
  "+3.47% APY median alpha" is dependent on the aggregator's ability
  to rebalance to the perp leg on regime shifts; without KI-2b,
  that rebalance cannot happen against a real writer.
- **Stream A vs stream B keeper identity**: stream A keeper identity
  is `address(aggregator)`; stream B keeper identity is
  `address(leg)`. The aggregator uses stream A for aggregator-driven
  rebalances (fast loop). The LP uses stream B for direct
  allocations to specific legs (optional, institutional). The two
  streams share the delegator (one signature from one EOA), but
  they have different keeper addresses — the venue-side identity
  that the writer checks. This is the whole point of the Option C
  hybrid in `DESIGN_KI2_SUBMITINTENT.md §4`: two keeper identities
  let FIX-21 revoke split the fast loop and the direct-allocation
  loop independently.
- **Rationale for deferral**: this is a design round. The
  implementation requires touching three contracts and adding an
  interface method, which is meaningful churn for a single round.
  Splitting the design from the implementation lets the design be
  reviewed independently, and lets the round-11 KI-1 agent finish
  their work without a code collision.
- **Blocking dependency**: ElysiumCoreWriter shipping. Until the
  real writer predeploy ships (see `ROADMAP.md §2.3`), the
  `_fallbackSig` code path is exercised only against MockWriter in
  tests. Phase 2 can be implemented and merged before the writer
  ships, but its production value is gated on the writer's
  availability. The design doc's decision to proceed is
  independent of that gate; the implementation's deploy window is not.

**Related findings noticed but not fixed** (out of scope for this
design doc, tracked elsewhere):

- **Round-9 finding #9** — `_fallbackSig` production reachability.
  This doc's §5.2 removes `_fallbackSig` entirely, which closes
  finding #9. Tracked here as a design-time observation; the
  closure happens in the Phase 2 implementation commit.
- **`harvest()` uses two `_fallbackSig` calls per leg** — one for
  `_writeClose` (closing the short to realize PnL) and one for
  `_writeOpen` (reopening the same short to continue collecting
  funding). Under Phase 2, both calls route through `submitIntent`
  with the same stream-A delegation, and the leg's `submittedIntents`
  nonce-key must include both calls (otherwise the second call's
  `(keeper, nonce, salt)` tuple collides with the first). Tracked as
  a Phase 2.5 follow-up in §4.5 (nonce management).
- **`reduceFrom` on a perp leg calls `_writeClose` for the perp cut
  and `_sellHype` for the spot cut.** Under Phase 2 the perp cut
  needs a stream-A delegation, but the spot cut is a router call
  that doesn't need a writer. The aggregator's `reduceIntent(d, sig, amount)`
  will only sign the perp cut; the spot cut stays an unauthenticated
  `_sellHype` call inside the leg. This is fine because `_sellHype`
  only reads/writes USDC and HYPE on the leg, not HyperCore state.
- **Stream-A aggregate cap check (§3, Option C lite) is not
  implemented.** The recommendation is to skip it — the leg's own
  verifier call is authoritative, and the aggregator's `remainingNotional`
  view would key on the wrong venue. If a future reviewer wants
  belt-and-braces, the right approach is a new
  `ITradeOnlyAgent.remainingNotionalAcrossVenues(venue[])` view
  that sums caps across the venue set, not the aggregator's ad-hoc
  read. Tracked as a possible Phase 3 extension.
- **`harvestFromAllLegs` (no args) becomes stale after Phase 2.**
  Once perp legs have positions, calling the no-args
  `harvestFromAllLegs` would iterate through all legs including perp
  legs with open shorts — and each perp leg's `harvest()` would
  call `_fallbackSig` (which is being removed) or revert if the
  wrapper is removed. Recommendation: deprecate the no-args
  `harvestFromAllLegs` after Phase 2, and require all harvest calls
  to go through `harvestFromAllLegs(Delegation, Signature)`.
  Tracked as a Phase 2.5 follow-up.

---

*Design authored 2026-09-22 for the Elysium builder workstream, as
Phase 2 of the KI-2 three-phase migration plan. All `file:line`
citations were verified against the working tree at HEAD `af4ea1b`
(round-9 commit + round-11 in-flight rate-tracking fix, docs only).
Re-verify before implementation. Round-11 is editing
`KHYPELeg.sol`, `SpotStakingLeg.sol`, and `Legs.t.sol` for the
KI-1 rate-tracking fix; this doc's Phase 2 implementation must land
after round-11's commits to avoid a code collision.*
