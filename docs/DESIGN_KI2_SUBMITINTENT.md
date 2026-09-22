# KI-2 — `submitIntent` writer plumbing

**Status**: design draft · **Repo**: `hypeback/` · **Scope**: replace the
`_zeroSig()` writer stub in every perp-routed leg with a real signed-intent
path that can be exercised against the production `ElysiumCoreWriter`.

Not audited. Not to be deployed with real capital.

---

## 1. Problem statement

Every perp-routed leg calls `writer.openPosition(...)` /
`writer.closePosition(...)` with `_zeroSig()` — a placeholder that returns
`Signature({v: 27, r: 0, s: 0})` and will always fail `ecrecover` against
any real `TradeOnlyAgent` verification.

- `PerpFundingLeg._writeOpen` / `_writeClose`:
  `solidity/src/legs/PerpFundingLeg.sol:261-263, 271-273`.
- `BasisHedgeLeg._writeOpen` / `_writeClose`:
  `solidity/src/legs/BasisHedgeLeg.sol:262, 270`.
- `_zeroSig()` is defined identically in both:
  `PerpFundingLeg.sol:303-305`, `BasisHedgeLeg.sol:290-292`.

Consequences for production:

1. **Every `allocateTo` / `harvest` / `reduceFrom` on a perp leg will revert**
   as soon as the writer stops being a stub — because
   `TradeOnlyAgent._recover` (`TradeOnlyAgent.sol:158-164`) does
   `require(v == 27 || v == 28)` and `ecrecover(digest, 27, 0, 0)`
   returns a non-zero address that will never match `from`. The two
   perp legs (`PerpFundingLeg`, `BasisHedgeLeg`) are dead on arrival
   against a real writer. The two staking legs (`KHYPELeg`,
   `SpotStakingLeg`) do not call the writer at all
   (`KHYPELeg.sol:24-30`, `SpotStakingLeg.sol:11-19`), so KI-2 does
   not touch them — but the aggregator's `_distribute` path
   (`YieldAggregator.sol:376-384`) hits all four legs in one tx, so a
   single revert poisons the whole allocation.
2. **`lastDelegationNonce` is leg-local and monotonically incremented**
   (`PerpFundingLeg.sol:289`, `BasisHedgeLeg.sol:276`) — it advances
   on every `_nextDelegation` call even when the corresponding write
   reverts. That state is meaningless without a real signature; once
   we start signing, we need to reason about which nonces have been
   pre-signed by the delegator and which have actually been executed.
3. **The leg sets `d.expiresAt = 0` (never-expires) unconditionally**
   (`PerpFundingLeg.sol:297`, `BasisHedgeLeg.sol:284`). Pre-FIX-21
   this was a revoke bypass (see §2). Post-FIX-21 it is legal, but it
   is a strong claim that needs to be deliberate rather than default.
4. **`bumpNonce()` exists as an owner-only escape hatch**
   (`PerpFundingLeg.sol:238`, `BasisHedgeLeg.sol:240`) — a maintenance
   knob for a world where nonces were meaningless. With real
   signatures the nonce becomes cryptographic identity, and
   "bumping" it is not what the delegator wants; the delegator wants
   to sign the specific nonce they meant to sign.

This is the single largest gap between the current skeleton and a
testnet-deployable aggregator.

---

## 2. Threat model

### 2.1 Actors

| Actor | Role | Owns |
|---|---|---|
| Delegator | Signs `Delegation` envelopes | Nothing on-chain beyond signature |
| Keeper | Presents `(Delegation, Signature)` to a venue | The contract address named as `keeper` in the delegation |
| Venue (writer) | Executes intents on HyperCore | `usedNotional` ledger in `TradeOnlyAgent` |
| Aggregator | ERC-4626 vault, keeper on the slow loop | Weight-vector state, share accounting |
| Leg | Wrapper over a single venue | `allocatedUsd`, per-leg state |

### 2.2 What is replayed

The EIP-712 domain is chain-separated (`TradeOnlyAgent.sol:140-150`),
so a signature valid on Elysium cannot be replayed on HyperEVM or
any other chain. The signed message (per spec §3,
`DELEGATION_SPEC.md:73-79`) is:

```
keccak256(abi.encode(
    DELEGATION_TYPEHASH,
    keeper,
    keccak256(abi.encode(assetIds)),
    maxNotional,
    maxPerOrder,
    expiresAt,
    nonce,
    salt
))
```

Replay surfaces, and how each is defended:

1. **Replay of the same `(keeper, nonce)` on the same venue.**
   `recordExecution` (`TradeOnlyAgent.sol:84-102`) caps
   cumulative notional at `d.maxNotional` — so a single
   delegation with a fixed nonce cannot be executed past its cap
   even if the same `(sig, d)` tuple is presented many times.
   **No new defence needed; inherent to FIX-14.**
2. **Replay of the same `(keeper, nonce)` on a different venue.**
   Keyed by `(venue, delegator, keeper, nonce)` — each venue has its
   own `maxNotional` bucket (`TradeOnlyAgent.sol:34-37, 152-156`).
   Effective ceiling is `N × maxNotional` for `N` venues (documented
   limitation, `DELEGATION_SPEC.md §9`,
   `solidity/tests_plan.md:701`).
3. **Replay across the four legs.** All four legs are on Elysium and
   route through a single writer predeploy — they are all the same
   venue from the verifier's point of view. So a single nonce
   consumed on `PerpFundingLeg` reduces the remaining cap for
   `BasisHedgeLeg` under the same delegator/keeper pair.
   **Design consequence**: the nonce source must be per-(leg, delegator)
   OR the delegator must budget one delegation per leg-action. We
   recommend per-leg nonces (see §6).
4. **Replay across a re-entrant callback.** `recordExecution` is
   called inside the writer's own execution path and its state
   is updated in the same tx — no cross-block window.

### 2.3 Interactions with existing protections

| Protection | Location | Interaction with KI-2 |
|---|---|---|
| **Universal revoke** | `TradeOnlyAgent.sol:105-109`, checked at `:59` | Once `submitIntent` is real, revoke actually matters: pre-FIX-21 a delegated `expiresAt=0` delegation could outlive a `revoke()`. Post-FIX-21, revocation invalidates every never-expires delegation simultaneously on every venue. |
| **FIX-21 — revoke survives never-expires** | `TradeOnlyAgent.sol:46-58` | The legs currently set `d.expiresAt = 0` unconditionally. Under FIX-21 the delegator can `revoke(keeper)` and every queued intent from that keeper stops. **This is the reason we prefer a design where revoking the aggregator keeper also revokes the keeper-driven path.** |
| **FIX-14 — per-venue notional cap** | `TradeOnlyAgent.sol:84-102` | Caps are `maxNotional` per `(venue, delegator, keeper, nonce)`; a single signed delegation therefore caps at `maxNotional`, not at `maxNotional × N_venues`. Legs that share a nonce across venues eat from the same bucket. |
| **Per-order cap** | Delegated to venue, not verifier (`DELEGATION_SPEC.md:107-110`) | Legs must clamp the writer call's `notional` to `d.maxPerOrder` before calling; today's `_nextDelegation` sets `maxPerOrder = notional` (`PerpFundingLeg.sol:296`), so it's tautologically true. Under `submitIntent` the keeper picks the notional and the delegator sets the cap — we must enforce at the leg too. |
| **Reentrancy guard on legs** | `PerpFundingLeg.sol:46-51`, `BasisHedgeLeg.sol:49-55` | `submitIntent` must go inside the guard; the writer could callback (it doesn't today, but the interface leaves the door open). |
| **Aggregator `nonReentrant`** | `YieldAggregator.sol:75-81` | Unchanged; the aggregator already treats legs as untrusted. |

### 2.4 Explicit non-threats

- **Cross-chain replay** — domain includes `block.chainid`
  (`TradeOnlyAgent.sol:146`). Out of scope per
  `DELEGATION_SPEC.md §8`.
- **Sub-delegation** — spec says the keeper cannot re-delegate
  (`DELEGATION_SPEC.md:194`). Our design does not implement
  sub-delegation: whoever signs a delegation is `from` on every
  subsequent `isValidDelegation`; the keeper is a distinct address
  named inside the signed envelope.
- **Oracle manipulation** — `oracle.priceOf` is called on staking
  legs only; perp legs only read funding/basis APY.

---

## 3. Design options

Notation: `keeper` is the address that signs/presents to the venue;
`delegator` is the one who signs the delegation.

### Option A — leg-owned intents, aggregator forwards

Every perp leg grows a new entry point:

```solidity
function submitIntent(
    ITradeOnlyAgent.Delegation calldata d,
    ITradeOnlyAgent.Signature calldata sig,
    uint256 amount
) external returns (uint256);
```

The leg validates `d.keeper == address(this)` and then applies the
intent to its internal state machine: if it matches an in-flight
`allocateTo`/`harvest`/`reduceFrom` context, it consumes the signature
and calls the writer; otherwise it enqueues a per-leg intent queue
and executes the writer call on the next appropriate action.

- **Pro**: matches the current leg-side shape of
  `_nextDelegation` + `_writeOpen` (`PerpFundingLeg.sol:286-301,
  256-273`). Each leg can keep its own nonce space. Users who want to
  allocate directly to a leg (e.g. an institutional LP that skips the
  aggregator) can just sign `keeper = legAddress`.
- **Con**: two delegations in flight for the same keeper/delegator
  pair — one with `keeper = aggregator` for the aggregator-driven
  slow loop, one with `keeper = eachLeg` for the fast loop. Revocation
  becomes per-address, so `revoke(aggregator)` does not revoke the
  keeper's authority to submit on the legs. That is a FIX-21
  concern: the aggregator keeper can still be revoked, but the
  leg keepers live on.
- **Blast radius**: touches both perp legs (interface + storage +
  nonce management), adds a new event, keeps `IYieldLeg` unchanged,
  no aggregator change.

### Option B — aggregator-only

Legs stay passive; only the aggregator knows how to submit intents.
The aggregator becomes the sole keeper and signs a single
`Delegation(keeper=aggregator, assetIds=[HYPE], maxNotional=VAULT_CAP, ...)`.
Legs expose a new internal hook:

```solidity
// On IYieldLeg:
function write(
    IElysiumCoreWriter.Side side,
    uint256 notional,
    ITradeOnlyAgent.Delegation calldata d,
    ITradeOnlyAgent.Signature calldata sig
) external; // aggregator-only
```

The aggregator calls `leg.write(...)` after `leg.allocateTo(delta)` —
or, better, refactors `allocateTo` so that the writer calls happen
via a callback.

- **Pro**: single keeper = single revocation handle.
  `revoke(aggregator)` cleanly stops all perp intent submission in
  one tx, which is exactly what FIX-21 gives us for free. Simple
  mental model — one delegation, one venue. Aligns with
  `AGGREGATOR_SPEC.md §3.5` fast loop being keeper-driven.
- **Con**: breaks the current separation where the leg is the
  keeper. The legs currently set `keeper = address(this)`
  (`PerpFundingLeg.sol:293`); changing that means either (a) the
  delegator signs delegations to the aggregator address (leg's
  `_nextDelegation` becomes aggregator-side), or (b) the aggregator
  passes an aggregator-keyed delegation into the leg via a new
  write-through parameter. Both require changing the shape of the
  leg's writer-call site. Also, direct-to-leg allocation
  (institutional LP signing to a specific leg) is no longer possible
  under this model.
- **Blast radius**: touches all 4 legs (2 staking legs gain an
  aggregator-only write hook they don't currently need), aggregator,
  and `IYieldLeg` interface. Highest churn.

### Option C — hybrid: aggregator submits keeper-driven intents, legs accept direct user intents

Both surfaces exist:

- **Aggregator → leg (keeper-driven)**: aggregator calls
  `leg.submitIntent(d, sig, amount)` with a delegation where
  `d.keeper == address(aggregator)`. This is the fast loop:
  `harvestFromAllLegs` and `executePending` re-route intent
  submission through this path. The aggregator keeper signs the
  delegation; the leg forwards to the writer with `msg.sender ==
  aggregator` — but the venue check
  (`DELEGATION_SPEC.md:101`) requires `msg.sender == d.keeper`, so
  this variant does NOT work as sketched.

  Correction: for Option C to work the delegator must sign TWO
  delegation streams:
  - stream A: `keeper = aggregator` (aggregator submits its own
    intents to the writer on behalf of its keeper-driven rebalance);
  - stream B: `keeper = leg` (user-driven direct allocations to
    a specific leg, submitted via `leg.submitIntent`).

  Stream A goes through the writer directly, not through the leg.
  The leg's `allocateTo` (spot portion) is still aggregator-driven
  through the existing `IYieldLeg` interface — but the perp half
  (`_writeOpen`) is aggregator-signed and aggregator-submitted, not
  leg-submitted.

- **Leg → writer (user-driven)**: `leg.submitIntent(d, sig, amount)`
  where `d.keeper == address(leg)`. A user (or the aggregator acting
  as a user on behalf of a share-holding LP) submits a leg-scoped
  delegation. The leg verifies `msg.sender == d.keeper` — but under
  stream B the keeper IS the leg, so `msg.sender` would need to be
  the leg itself, which is not who signed the tx. This means stream
  B requires the user to submit the intent to the leg in a special
  form where the leg itself is the caller — which only makes sense
  if the leg forwards to the writer and passes `d.keeper == address(leg)`;
  but the venue checks `msg.sender == d.keeper` and `msg.sender`
  at the writer is the leg, not the user. So this works: the user
  calls `leg.submitIntent(d, sig, amount)` with `d.keeper = address(leg)`,
  the leg validates the signature against `d`, and the leg itself
  becomes `msg.sender` at the writer. The user is not the keeper;
  the leg is. That's the model.

- **Pro**: clean mapping to the two-speed framing. Keeper signs once
  per aggregator-driven action (stream A); LP signs once per direct
  allocation (stream B). Revoking the aggregator keeper is a
  well-defined event (kills the fast loop). Revoking a leg keeper
  only kills direct allocations to that specific leg. FIX-14 caps
  stay per-stream (each stream has its own keeper address, so they
  get separate `maxNotional` buckets at the verifier).
- **Con**: two keeper identities to reason about, two delegation
  streams to sign, and a fork in the design: which leg-actions
  require stream A vs stream B? The rule must be written down
  precisely or the leg will accidentally accept either.
- **Blast radius**: touches both perp legs (new `submitIntent`),
  touches the aggregator (signs its own stream-A intents and
  forwards to the writer directly), leaves `IYieldLeg` unchanged
  on the spot portion. `IElysiumCoreWriter` is unchanged — it
  already takes `(assetId, side, notional, delegator, d, sig)`
  (`IElysiumCoreWriter.sol:27-44`).

### 3.1 Comparison

| Property | Option A | Option B | Option C |
|---|---|---|---|
| New keeper identity introduced | Yes (per-leg) | Yes (aggregator) | Yes (aggregator AND per-leg) |
| Direct-to-leg allocation possible | Yes | No | Yes |
| FIX-21 revoke covers all intent flows | No (only per-leg) | Yes | Partial (fast loop yes, direct no) |
| `IYieldLeg` change | No | Yes (write hook) | No |
| Aggregator change | No | Yes (signs, submits) | Yes (signs stream A) |
| Leg change | Yes (submitIntent) | Yes (write hook) | Yes (submitIntent, spot only in some flows) |
| Aligns with AGGREGATOR_SPEC §3.5 two-speed | Medium | Yes | Best |
| Churn | Low | High | Medium |

---

## 4. Recommended option: **C (hybrid)**

The aggregator's two-speed design
(`AGGREGATOR_SPEC.md:207-249`) already has a slow loop (24h timelock,
keeper-driven, `executePending`) and a fast loop (keeper reacts to
funding ticks within current weights, sub-second settle via the
writer). Option C maps one-to-one onto that split:

- **Slow loop (aggregator keeper, stream A)**: The aggregator keeper
  signs a single broad-scope delegation per epoch (e.g. per rebalance)
  with `keeper = aggregator`, `assetIds = [HYPE]`,
  `maxNotional = <target delta × 4 legs>`, `maxPerOrder = <per-leg
  delta>`. The aggregator submits directly to the writer on
  `executePending`. Stream A is where the alpha lives (see §3.5 of
  the aggregator spec).
- **Fast loop (aggregator keeper continues, stream A) + LP direct
  allocations (stream B)**: The aggregator still routes through the
  writer on `harvestFromAllLegs` using stream A. Institutional LPs
  that want to bypass the aggregator and go straight to a leg
  sign stream B delegations with `keeper = legAddress` and submit
  via `leg.submitIntent(d, sig, amount)`. Stream B is opt-in and
  optional — the aggregator works fine without it.

Justification against the two hard constraints:

- **FIX-21 (revoke-bypass for never-expires)**: Option C uses
  `expiresAt` explicitly. Stream A delegations are short-lived
  (per rebalance, `expiresAt = executesAt + 1 hour`) — revocation
  is immediate and the never-expires sentinel is not used. Stream B
  delegations can be never-expires for LP permanence, but then
  the FIX-21 fix in `TradeOnlyAgent.sol:58` is the safety net:
  a delegator who revokes a leg keeper invalidates every queued
  stream B intent at every venue simultaneously. Under Option A
  this same fix would apply but the never-expires delegation could
  outlive a compromised aggregator keeper (stream A) — which is a
  real operational gap. Under Option C stream A is short-lived so
  FIX-21 is a defence-in-depth, not the primary control.
- **FIX-14 (per-venue notional cap)**: Stream A has
  `keeper = aggregator` — one bucket in the verifier, easy to
  budget (`maxNotional` per stream-A delegation is a hard cap on
  the aggregator's perp activity in that epoch). Stream B has
  `keeper = leg` — one bucket per leg per delegator. Two buckets
  per LP, no cross-talk (FIX-14's per-venue isolation
  `TradeOnlyAgent.sol:34-37` does the work).

Why not B: it forces a `IYieldLeg` interface change and touches all
4 legs including the two that never talk to the writer. Also
breaks direct-to-leg allocation which is a documented use case
(`AGGREGATOR_SPEC.md:141-161`, "the aggregator never touches
HyperCore state directly; it always routes through a leg" —
Option B is a partial exception to that rule).

Why not A: it doesn't help the aggregator's fast loop
(`harvestFromAllLegs`, `executePending`) get a clean
`keeper = aggregator` delegation — under Option A the leg is the
keeper, so the aggregator keeper would be signing intents for a
keeper it doesn't control (each leg has its own keeper stream),
and revocation of the aggregator keeper would leave every leg
keeper's stream B live. That is a real compromise-recovery gap.

---

## 5. Interface diff

### 5.1 `IYieldLeg` — no change to the base interface

The existing `IYieldLeg` (`solidity/src/interfaces/IYieldLeg.sol`)
stays as-is. The new method is a separate, optional interface:

```solidity
/// New file: solidity/src/interfaces/IIntentSubmittingLeg.sol
interface IIntentSubmittingLeg {
    /**
     * Submit a signed intent to this leg. The leg is the keeper
     * named in `d.keeper`; `msg.sender` must equal `d.keeper`.
     *
     * The leg is responsible for:
     *   - Validating `d.keeper == address(this)`.
     *   - Clamping `amount <= d.maxPerOrder`.
     *   - Checking the tradeOnlyAgent's `remainingNotional` cap
     *     before calling the writer (as venues must, per
     *     DELEGATION_SPEC.md §4).
     *   - Forwards to `writer.openPosition(...)` or
     *     `writer.closePosition(...)` with the given `sig`.
     *
     * The delegator (`d.from`, i.e. `msg.sender` on the TOA call
     * inside the writer) is set to the leg's configured
     * `delegator`.
     */
    function submitIntent(
        ITradeOnlyAgent.Delegation calldata d,
        ITradeOnlyAgent.Signature calldata sig,
        uint256 amount
    ) external returns (uint256 allocatedUsd);
}
```

Legs that implement this: `PerpFundingLeg`, `BasisHedgeLeg`.
Legs that do not: `KHYPELeg`, `SpotStakingLeg` — they never talk to
the writer (`KHYPELeg.sol:24-30`, `SpotStakingLeg.sol:11-19`).
The aggregator can check `type(IIntentSubmittingLeg).is(implementedBy)`
via a `supportsInterface` or a try-call; the current interface
does not require ERC-165 and neither does the aggregator use it.

### 5.2 `IElysiumCoreWriter` — no change

The writer interface (`IElysiumCoreWriter.sol:27-44`) already takes
`(assetId, side, notional, delegator, d, sig)`. The
`_zeroSig()` in the current leg is just a bad placeholder value for
the `sig` parameter. Once the leg accepts a real signature via
`submitIntent`, `_writeOpen` / `_writeClose` receive a real sig and
forward it unchanged. No new method, no new parameter.

### 5.3 `TradeOnlyAgent` — no change

`TradeOnlyAgent.sol:21-165` is complete. KI-2 does not touch it.
In particular:

- `isValidDelegation` (`:40-63`) — signature + revoke + expiry.
  FIX-21 already fixed the never-expires revoke bypass.
- `remainingNotional` (`:69-76`) — venues must call this before
  `recordExecution`.
- `recordExecution` (`:84-102`) — venues call this after
  successful execution.

### 5.4 Concrete shape of the new leg method

For `PerpFundingLeg` (the same pattern applies to
`BasisHedgeLeg`):

```solidity
// Added to PerpFundingLeg.sol, after the existing `bumpNonce()`:
function submitIntent(
    ITradeOnlyAgent.Delegation calldata d,
    ITradeOnlyAgent.Signature calldata sig,
    uint256 amount
) external nonReentrant returns (uint256) {
    require(d.keeper == address(this), "keeper is not this leg");
    require(amount > 0 && amount <= d.maxPerOrder, "bad amount");

    uint256 spotPortion = amount / 2;
    uint256 perpPortion = amount - spotPortion;
    if (spotPortion == 0) spotPortion = amount;

    uint256 hypeIn = _buyHype(spotPortion);
    spotHypeBalance += hypeIn;

    if (perpPortion > 0) {
        // Forward the caller-supplied sig to the writer.
        _writeOpen(d, sig, IElysiumCoreWriter.Side.Short, perpPortion);
        perpNotional += perpPortion;
    }

    allocatedUsd += amount;
    _recordApy(expectedApy());
    emit Allocated(amount, allocatedUsd);
    return amount;
}
```

`_writeOpen` and `_writeClose` change from `(Delegation, Side, notional)`
to `(Delegation, Signature, Side, notional)` — they now accept the
signature and pass it through. `_zeroSig()` is deleted.

The existing `allocateTo`, `harvest`, `reduceFrom` retain their
current signature — they become "aggregator-only convenience
wrappers" for the aggregator-driven slow loop, and internally
they will route to `submitIntent` via a stream-A delegation
that the aggregator signs and passes in. That routing is a
follow-up refactor (see §8).

---

## 6. Replay protection

**Question**: how does the leg prevent the same
`(keeper, nonce)` from being reused?

**Answer**: it doesn't need to — the verifier does.

- The venue checks `remainingNotional` before executing
  (`DELEGATION_SPEC.md:119-121`); a nonce whose cap is fully
  spent is rejected by `recordExecution` returning `false`
  (`TradeOnlyAgent.sol:98-99`).
- The nonce is the EIP-712 message input, so it is part of the
  cryptographic identity (`TradeOnlyAgent.sol:120-129`). Two
  different nonces in the same delegation produce different
  signatures; the same nonce with the same message hash produces
  the same signature — meaning two presentations with the same
  nonce are literally the same tx (idempotent, blocked by the cap).
- Cross-venue replay: the key is
  `keccak256(venue, delegator, keeper, nonce)`
  (`TradeOnlyAgent.sol:152-156`), so the same `(keeper, nonce)` on
  two different venues has two independent caps.

**Where does nonce live?**

Current state: `lastDelegationNonce` is a per-leg
`uint256` counter (`PerpFundingLeg.sol:77`,
`BasisHedgeLeg.sol:76`) incremented in `_nextDelegation`.

Recommended: keep the per-leg counter, but rename to make its
purpose explicit:

- `nextDelegationNonce` — the next nonce the leg will propose.
- `uint64[4] lastExecutedNonces` (circular buffer of size 4) — the
  last 4 nonces actually executed, so a client can query
  `lastExecutedNonce(i)` and know the next safe nonce to pre-sign.

`bumpNonce()` (`PerpFundingLeg.sol:238`, `BasisHedgeLeg.sol:240`)
becomes owner-only and only usable when `nextDelegationNonce` is
behind the last-executed counter (e.g. after a failed writer call
that reverted but not before the leg advanced the counter).

**Cross-leg nonce collision**: because the verifier keys by
`(venue, delegator, keeper, nonce)` and `keeper = legAddress`,
nonces in `PerpFundingLeg` and `BasisHedgeLeg` are in different
buckets even if numerically equal. So the delegator can reuse
`nonce = 1` on both legs. That's fine.

---

## 7. Test plan

New tests live in `solidity/test/Legs.t.sol` (additions) and a new
`solidity/test/Mocks/MockWriter.sol`.

### 7.1 Mock writer

```solidity
// New file: solidity/test/mocks/MockWriter.sol
contract MockWriter is IElysiumCoreWriter {
    struct Invocation {
        uint256 assetId;
        Side side;
        uint256 notional;
        address delegator;
        address keeper;
        uint64 nonce;
        bytes32 salt;
        bool open;
        bytes32 sigHash;   // keccak256(v,r,s)
    }
    Invocation[] public invocations;
    bool public failNext;
    uint256 public fakeCreditedUsdc;  // for harvest tests

    function openPosition(
        uint256 assetId, Side side, uint256 notional, address delegator,
        ITradeOnlyAgent.Delegation calldata d,
        ITradeOnlyAgent.Signature calldata sig
    ) external {
        require(!failNext, "writer forced fail");
        invocations.push(Invocation(
            assetId, side, notional, delegator,
            d.keeper, d.nonce, d.salt, true,
            keccak256(abi.encode(sig.v, sig.r, sig.s))
        ));
    }
    // closePosition analogous.
}
```

### 7.2 New tests

For `PerpFundingLeg` (mirror for `BasisHedgeLeg`):

| # | Test | Setup | Assertion |
|---|---|---|---|
| 1 | `test_submitIntent_rejectsWrongKeeper` | `d.keeper = address(0xdead)`, `msg.sender = keeper` | reverts `"keeper is not this leg"` |
| 2 | `test_submitIntent_rejectsAmountOverMaxPerOrder` | `d.maxPerOrder = 100`, `amount = 101` | reverts `"bad amount"` |
| 3 | `test_submitIntent_forwardsRealSigToWriter` | Valid `d, sig, amount`; MockWriter logs invocation | `invocations[0].sigHash != keccak256(27,0,0)` and `== keccak256(v,r,s)`; `keeper == address(leg)` |
| 4 | `test_submitIntent_zeroSigGone` | Compile-time: `_zeroSig()` no longer exists in either perp leg | grep-based check in `verify.py` (extend existing) |
| 5 | `test_submitIntent_reentrantWriterDoesNotDoubleAllocate` | MockWriter reenters `submitIntent` | revert on `nonReentrant` guard |
| 6 | `test_aggregatorExecutePending_routesThroughSubmitIntent` | Aggregator triggers `executePending` with a stream-A delegation; legs receive intent via `submitIntent` | `MockWriter.invocations` non-empty, all `keeper == address(leg)` |

For `TradeOnlyAgent` regression (already covered by
`TradeOnlyAgent.t.sol`, no new tests):

- `test_recordExecution_venueCapEnforced` (line 248) already
  proves replay-within-a-nonce is bounded by `maxNotional`.
- `test_revoke_invalidatesValidDelegation` (line 211) already
  proves FIX-21 is on.

Verifier update (`verify.py`): extend the "no zero-sig" grep that
is already implied by the ABI check to explicitly forbid
`_zeroSig()` symbol in any leg under `solidity/src/legs/`.

---

## 8. Blast radius

| Component | Touched? | Change |
|---|---|---|
| `TradeOnlyAgent.sol` | No | FIX-21 already fixed the never-expires revoke bypass; KI-2 consumes it, doesn't change it. |
| `IYieldLeg.sol` | No | New separate `IIntentSubmittingLeg` interface. |
| `IElysiumCoreWriter.sol` | No | Already takes `(assetId, side, notional, delegator, d, sig)`. |
| `YieldAggregator.sol` | Follow-up | Aggregator must eventually sign stream-A delegations and forward intents via legs' new `submitIntent` on `executePending` and `harvestFromAllLegs`. That's a separate ticket (call it KI-2b) so the aggregator can land without breaking the existing slow-loop path. |
| `PerpFundingLeg.sol` | Yes | Add `submitIntent`, remove `_zeroSig`, add `nextDelegationNonce` rename, drop `bumpNonce` (or restrict to catch-up). |
| `BasisHedgeLeg.sol` | Yes | Same as above. |
| `KHYPELeg.sol` | No | Never calls the writer. |
| `SpotStakingLeg.sol` | No | Never calls the writer. |
| `verify.py` | Yes | Add a grep that `_zeroSig` does not appear in any leg. |
| `check_repo.py` | No | Not modified per task constraints. |

---

## 9. Migration risk

**Question**: what happens to existing allocations?

Current state of test allocations (per `solidity/test/Legs.t.sol`):
all 15 existing leg tests use the `allocateTo(amount)` path and
assert on `allocatedUsd`, `allocatedUsd`, `perpNotional`,
`spotHypeBalance`, etc. They do not inspect `MockWriter.invocations`
at all — the current writer is likely a no-op mock or a stub
that doesn't check signatures. Adding a real signature to the
existing `allocateTo` path is a breaking change for those tests.

**Migration plan (three phases)**:

1. **Phase 1 — additive only**: add `submitIntent` alongside the
   existing `allocateTo`. Keep `_zeroSig()` as a fallback for
   `allocateTo`/`harvest`/`reduceFrom` (aggregator path) so existing
   15 leg tests + 28 aggregator tests continue to pass. Only
   `submitIntent` uses a real signature. `verify.py` grep is
   updated to look for `_zeroSig()` only in aggregator-only call
   paths, not in `submitIntent`.
2. **Phase 2 — aggregator refactor**: refactor `YieldAggregator.executePending`
   and `harvestFromAllLegs` to sign a stream-A delegation and call
   `leg.submitIntent(...)` instead of `leg.allocateTo(...)`. Replace
   `_zeroSig()` with the aggregator-signed signature throughout the
   leg. `_zeroSig()` symbol removed from both perp legs.
3. **Phase 3 — cleanup**: delete `bumpNonce()`, rename
   `lastDelegationNonce` → `nextDelegationNonce`, add
   `lastExecutedNonce(i)` view.

Existing allocations that were made under Phase 1 with `_zeroSig()`
cannot be executed against a real writer — they live only in the
MockWriter test rig. In production, the aggregator must not
allocate to perp legs until Phase 2 is deployed. This is enforced
by a governance gate: `executePending` refuses to shift any weight
to a perp leg unless `MockWriter.isProduction()` returns true (or
equivalent deploy-time flag).

Deposits to `KHYPELeg` and `SpotStakingLeg` are unaffected — those
legs never touch the writer. Withdrawals from perp legs under
Phase 1 are still possible via `reduceFrom` as long as the
MockWriter accepts them; in production the perp-leg withdraw path
must go through a real signature too, so Phase 2 is a hard
prerequisite for live perp-leg withdrawals.

**Rollback**: reverting KI-2 (i.e. restoring `_zeroSig()`) is
safe as long as the MockWriter mock continues to be the writer in
the test rig. On a live deploy, reverting KI-2 reverts the
aggregator back to broken state on the writer path — which is
the current state. So rollback = status quo, not worse.

---

## Appendix — file:line index of claims

- KI-2 root cause (writer called with `_zeroSig()`):
  `solidity/src/legs/PerpFundingLeg.sol:261-273`,
  `solidity/src/legs/BasisHedgeLeg.sol:262, 270`.
- Staking legs don't call the writer:
  `solidity/src/legs/KHYPELeg.sol:17-20, 124-172`,
  `solidity/src/legs/SpotStakingLeg.sol:11-19, 124-171`.
- Aggregator slow/fast loop framing:
  `docs/AGGREGATOR_SPEC.md:207-249`.
- `_nextDelegation` sets `expiresAt=0` and `keeper=address(this)`:
  `solidity/src/legs/PerpFundingLeg.sol:286-301`,
  `solidity/src/legs/BasisHedgeLeg.sol:273-288`.
- FIX-21 never-expires revoke bypass fix:
  `solidity/src/delegation/TradeOnlyAgent.sol:46-63`.
- FIX-14 per-venue notional cap:
  `solidity/src/delegation/TradeOnlyAgent.sol:34-37, 84-102, 152-156`.
- EIP-712 signature schema and domain separation:
  `docs/DELEGATION_SPEC.md:73-79`,
  `solidity/src/delegation/TradeOnlyAgent.sol:117-150`,
  `solidity/test/TradeOnlyAgent.t.sol:62-95`.
- `IElysiumCoreWriter` already carries `(d, sig)`:
  `solidity/src/interfaces/IElysiumCoreWriter.sol:27-44`.
- Legs' `bumpNonce()` owner helper:
  `solidity/src/legs/PerpFundingLeg.sol:238`,
  `solidity/src/legs/BasisHedgeLeg.sol:240`.
- Leg reentrancy guard: `solidity/src/legs/PerpFundingLeg.sol:46-51`,
  `solidity/src/legs/BasisHedgeLeg.sol:49-55`.
- Aggregator reentrancy guard and pending allocation:
  `solidity/src/aggregator/YieldAggregator.sol:75-81, 281-350`.
- Revoke is universal (venue-independent):
  `docs/DELEGATION_SPEC.md:82-92`,
  `solidity/src/delegation/TradeOnlyAgent.sol:105-114`.
- Cross-chain replay is blocked by `block.chainid` in the domain:
  `docs/DELEGATION_SPEC.md:193-195`,
  `solidity/src/delegation/TradeOnlyAgent.sol:146`.
