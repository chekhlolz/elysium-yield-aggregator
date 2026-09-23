# KI-1 (b) — Stake-Leg Rate-Tracking Divergence

**Status**: design proposal · **Severity**: pre-M3 accounting correctness (HIGH) · **Blast radius**: `KHYPELeg.sol`, `SpotStakingLeg.sol` only (no interface change) · **Related**: `docs/DESIGN_KI1_UNIT_RECONCILE.md §9`, `docs/ROADMAP.md §2.5`

---

## 1. Problem statement

`KHYPELeg` and `SpotStakingLeg` track their on-book position in
`khypeBalance` / `rewardHypeBalance`. The variable records the **HYPE
input** of each `allocateTo` (the raw amount the router returned, in
18-decimal HYPE units), but `reduceFrom` decrements the same counter by
a HYPE amount while `pool.unstake` burns a **stake-token** amount
(HYPE × live `pool.exchangeRate()` / 1e18). Whenever `pool.exchangeRate()`
moves, the pool's actual stake-token holdings and `khypeBalance`
diverge, and the divergence compounds on every subsequent `reduceFrom`.

### The concrete numerical example (round-9 finding #1/#2)

Aggregator allocates 200 USDC at $1/HYPE, pool rate = 1.0:

- `allocateTo(200e6)` — router returns 200 HYPE = `200e18`.
- Pool mints at rate 1.0 (1:1): 200 stake tokens.
- `khypeBalance = 200 HYPE` (per `KHYPELeg.sol:181`), i.e. $200 worth.

Rate rises to 1.2. `currentValue()` re-prices: 200 stake tokens × 1.2
= 240 HYPE = $240 worth (mark-to-market, correctly). The pool holds
200 stake tokens; `khypeBalance` still says 200 (HYPE) — the ledger
and the pool agree here only because we haven't yet unstaked.

Now `reduceFrom(100e6)` — 100 USDC worth of HYPE at the $1 oracle:

- `hypeAmount = (100e6 · 1e18) / 1e6 = 100e18` (100 HYPE)
  (`KHYPELeg.sol:225`).
- Ledger: `khypeBalance -= 100` → `khypeBalance = 100 HYPE`
  (`KHYPELeg.sol:228`).
- Pool burn: `stakeTokenAmount = (100e18 · 12e17) / 1e18 = 120 stake
  tokens` (`KHYPELeg.sol:233`); `pool.unstake` burns **120** stake
  tokens (`KHYPELeg.sol:236`).

Result:

- **Pool holds**: 200 − 120 = 80 stake tokens. At rate 1.2 and price
  $1: 80 × 1.2 × $1 = **$96**.
- **Book claims**: `khypeBalance` = 100 HYPE. `currentValue()` returns
  `(100 · 1e18 · 1e6) / 1e18` = `100e6` = **$100**.

The ledger overstates the position by **$4** — a **4% overstatement**
on a 100-USD-unstake, 20% rate move. The pool will happily burn the
80 stake tokens that remain (leaving nothing), but the vault has
recorded $200 of the initial $300 as still allocated — half of the
leg's book value is not backed by any actual stake tokens.

A second `reduceFrom(100e6)` against the same post-drift state would
try to unstake `100 HYPE × 1.2 / 1e18 = 120` stake tokens from a pool
holding only 80, which reverts at `pool.unstake` (insufficient
stake-token balance) — an accounting bug that turns into a liveness
bug the moment a user tries to redeem the over-claimed principal.

### Flow-through to `totalAssets()` and `convertToShares()`

`YieldAggregator.totalAssets()` (`YieldAggregator.sol:180-182`) sums
`currentValue()` across all legs. With the drift:

- Each stake leg's `currentValue()` under-reports or over-reports the
  true stake-token value by a factor of `pool.exchangeRate()`. In the
  example above the leg's `currentValue()` returns $100 while the
  pool's real stake-token value is $96 (4% overstatement).
- The aggregator's `totalAssets()` inherits this 4% error.
- The ERC-4626 `convertToShares` / `convertToAssets` math
  (`YieldAggregator.sol:203-225`) uses `totalAssets()` and
  `totalSupply()`; a 4% systematic error in `totalAssets()` directly
  inflates (or deflates) `shareValue = totalAssets / totalSupply`.
  A first depositor depositing against an overstated share value gets
  fewer shares than they deserve; a redeemer gets more USDC than they
  should — a first-depositor-attack surface on top of the accounting
  bug.
- On rate *decrease* the drift flips sign (pool holds more HYPE than
  the book claims), producing under-reported `totalAssets()`, which
  inflates share value and gives late depositors more shares per USDC
  than they paid for.

Both directions of drift compound multiplicatively on every subsequent
`reduceFrom` until `khypeBalance` either underflows to 0 (reverting
the ledger) or exceeds the pool's stake-token holdings (making
`pool.unstake` revert).

### Why round-6's KI-1 fix did not prevent this

Round-6 (commit `a2462c5` and follow-ups through `9120c91`) resolved
the *USDC-vs-HYPE* unit-dominance bug in the `amount` parameter:
`amount` was being passed straight to `pool.unstake` as if it were a
stake-token amount, and `khypeBalance` was being decremented by the
USDC `amount` on the reduce path. That bug is fixed — `reduceFrom`
now converts USDC → HYPE via the oracle before decrementing
`khypeBalance` and computes `stakeTokenAmount` before calling
`pool.unstake`.

But the fix assumed `khypeBalance` and the pool's stake-token balance
were in the *same* unit. They are not: `khypeBalance` is the raw
HYPE input from the router, the pool holds stake tokens
(HYPE × rate / 1e18). The assumption holds only while
`pool.exchangeRate() == 1e18` (i.e. the 1:1 mint the test mocks
default to). Once the rate moves, the two diverge.

---

## 2. Root cause

`KHYPELeg.sol:125-130` and `SpotStakingLeg.sol:126-130` carry a
comment describing the KI-1 intent that the code does not actually
implement:

```solidity
// KI-1 (Option A, DESIGN_KI1_UNIT_RECONCILE): khypeBalance is now
// tracked in HYPE units (18 dec) -- the pool.exchangeRate() factor
// is folded in at the boundary (allocateTo), so the valuation
// math collapses to `hype * price`.
```

The claim is: *the exchange rate is folded in at `allocateTo`, so
after that the counter is effectively HYPE-equivalent*. The code at
`KHYPELeg.sol:181` does not do this:

```solidity
khypeBalance += hypeIn;   // raw router return, HYPE units
```

`hypeIn` is the router's HYPE return. To actually fold the rate in at
the boundary, this line would need to be:

```solidity
khypeBalance += (hypeIn * pool.exchangeRate()) / 1e18;   // stake-token units
```

Because the rate is *not* folded in at the boundary, `khypeBalance`
stays in HYPE-input units forever. The pool, on the other hand, holds
stake tokens — a strictly different unit that evolves with
`pool.exchangeRate()`.

The KI-1 comment is therefore aspirational: it describes an *intent*
to track HYPE-equivalent stake tokens, but the implementation tracks
raw HYPE input. `currentValue()` then treats `khypeBalance` as
HYPE-equivalent (`khypeBalance × price / 1e18`), which is only correct
when the rate has never moved since the last `allocateTo`. This is
finding #17: the comment and the code disagree about the unit, and
the code is wrong.

### Three call sites that disagree

| Site | Location | Unit |
|---|---|---|
| `khypeBalance += hypeIn` | `KHYPELeg.sol:181`, `SpotStakingLeg.sol:180` | HYPE input (raw router return) |
| `khypeBalance -= hypeAmount` | `KHYPELeg.sol:228`, `SpotStakingLeg.sol:226` | HYPE input (oracle-converted) |
| `pool.unstake(address(this), stakeTokenAmount)` | `KHYPELeg.sol:236`, `SpotStakingLeg.sol:234` | Stake tokens (rate-adjusted) |

Two of these three are in HYPE units and agree with each other; the
third is in stake-token units and is where the pool actually mutates
its own book. The pool's book is authoritative; the ledger's book is
a stale mirror that is only ever reconciled at `allocateTo` time and
only against the HYPE input, never against the pool's stake-token
balance.

---

## 3. Design options

### Option A — Track stake-token count; multiply by live rate in `currentValue()`

Redefine `khypeBalance` / `rewardHypeBalance` to hold the **stake-token
count** (the unit the pool itself uses). At the `allocateTo` boundary,
convert the router's HYPE return into stake tokens using the pool's
current `exchangeRate()`; at `currentValue()`, convert stake tokens
back to HYPE using the live rate before multiplying by the price.

- **`allocateTo`**: `khypeBalance += (hypeIn * pool.exchangeRate()) / 1e18`.
- **`currentValue()`**: `v = (khypeBalance * pool.exchangeRate() * price) / 1e36`.
- **`reduceFrom`**: compute `hypeAmount` as today, then convert to
  stake tokens via `pool.exchangeRate()`, then decrement
  `khypeBalance -= stakeTokenAmount` (stake-token units, matching
  what the pool actually burns).

**Pro**
- The ledger and the pool's book speak the same unit. The invariant
  `khypeBalance == pool.balanceOf(address(this), address(this))`
  (both in stake-token units) can be asserted in tests and maintained
  by construction.
- `currentValue()` becomes a pure valuation of stake tokens — stake
  tokens × rate × price, exactly matching what the pool would return
  on an unstake-and-credit cycle. The 1e36 denominator cancels one
  1e18 for stake tokens, one for HYPE, one for USDC; every factor is
  in exactly the right place.
- The blast radius is 3 call sites per leg. No new state, no new
  external dependencies (`pool.exchangeRate()` is already called in
  `reduceFrom` today).
- Closes finding #17 by implementing the intent the KI-1 comment
  already describes. The comment itself will need rewording to say
  "stake-token count" rather than "HYPE units", but the code will
  finally match it.

**Con**
- `currentValue()` now reads `pool.exchangeRate()` — a *new* external
  call in the read path (it was previously free of `pool` calls).
  If the pool reverts on `exchangeRate()` the whole leg read breaks;
  existing `pool.unstake`-adjacent failures would already break the
  reduce path, so this is not a strictly new failure mode, but the
  surface area widens slightly.
- The `allocateTo` boundary now depends on the pool's live rate, not
  just the router's return. A rate jump between the router swap and
  the `pool.exchangeRate()` read would produce a stake-token amount
  slightly different from what the pool would actually mint at the
  moment of `pool.stake`. In practice the pool mints deterministically
  on `stake(HYPE, amount)` using its own live rate at the moment of
  `stake`, so the safest implementation is to capture
  `pool.balanceOf(address(this), address(this))` before/after `stake`
  and use the delta — but that introduces an external read per
  allocate. See §5 for the recommendation.

**Blast radius**
- `KHYPELeg.sol` and `SpotStakingLeg.sol` only. Interface unchanged,
  aggregator unchanged, all other legs unchanged.

### Option B — Query `pool.balanceOf()` in `currentValue()`

Treat `khypeBalance` as a stale-cache fallback and have
`currentValue()` read the pool's authoritative stake-token balance
directly:

```solidity
function currentValue() external view returns (uint256) {
    uint256 stakeTokens = pool.balanceOf(address(this), address(this));
    uint256 price = _hypePriceUsdc();
    uint256 v = 0;
    if (stakeTokens > 0) {
        v = (stakeTokens * pool.exchangeRate() * price) / 1e36;
    }
    v += usdc.balanceOf(address(this));
    return v;
}
```

**Pro**
- The pool is the single source of truth by construction. No ledger
  bookkeeping at all for valuation.
- Robust to any future rate-tracking bug that slips into
  `allocateTo` / `reduceFrom`: the valuation is always the pool's
  own view.

**Con**
- `currentValue()` becomes an external call on every aggregator read
  (`totalAssets()` calls it once per leg per accounting refresh).
  That is a new per-block external dependency on the pool for a
  purely informational view function. If the pool reverts (e.g.
  during a pool halt), the aggregator's `totalAssets()` reverts with
  it — a liveness issue for the entire vault, not just the stake leg.
- Does *not* fix the underlying `reduceFrom` decrement:
  `khypeBalance -= hypeAmount` still subtracts a HYPE amount from a
  variable that (under this option) is now only a stale cache, but
  the pool still burns a stake-token amount. The bug in the reduce
  path remains; only the *visibility* of the bug changes.
- Introduces an invariant gap between the on-chain ledger (used for
  guards like `require(khypeBalance >= hypeAmount)`) and the pool's
  authoritative balance. Tests that assert on `khypeBalance` will
  diverge from tests that assert on `pool.balanceOf`.

**Blast radius**
- Same as Option A in the read path, but *fails to close* the reduce
  path bug. Insufficient on its own; would still need the Option A
  reduce fix.

### Option C — Accept the drift, document as a known limitation

Add a code comment acknowledging that `khypeBalance` and the pool's
stake-token balance diverge on rate moves, and defer a fix to a
future design round.

**Pro**
- Zero risk: no code changes.

**Con**
- The drift is unbounded. Every `reduceFrom` on a moved rate changes
  `khypeBalance` by a HYPE amount while the pool burns a rate-adjusted
  stake-token amount. The error compounds multiplicatively and flips
  sign depending on rate direction.
- The drift is *not* bounded to test-mock rate = 1.0. Any real
  staking venue's `exchangeRate()` will drift over time as yield
  accrues — that is the whole point of a liquid-staking pool.
- A vault with uncorrected accounting drift is a first-depositor
  attack surface on the ERC-4626 side. An attacker can drive
  `khypeBalance` systematically overstated or understated and use
  the resulting `totalAssets()` error to mint shares at a discount
  or redeem at a premium.
- Does not close finding #17 (the comment/code mismatch). The
  comment would still describe an intent the code does not implement.
- Not defensible: the drift is neither bounded nor small in practice,
  so this option only defers the failure mode, not the fix.

**Blast radius**
- Documentation only.

---

## 4. Recommended option — **A**

Option A is the only option that (a) fixes the underlying bug,
(b) closes finding #17 by making the code match the comment's
intent, and (c) keeps all accounting on-chain in the two stake legs
with a minimal blast radius.

Specifically for this repo at 2026-09-22:

- **Pre-M3.** No production capital has touched these contracts. The
  state-migration concern from §7 does not apply (see §7 below).
- **`pool.exchangeRate()` is already a dependency** of the reduce
  path (`KHYPELeg.sol:231`, `SpotStakingLeg.sol:229`). Option A just
  extends that dependency into the read path and the `allocateTo`
  boundary — no *new* external interface is introduced.
- **Blast radius is two legs, three call sites each.** No interface
  change, no aggregator change, no verifier change, no test-helper
  contract change (existing mocks already expose `exchangeRate()`).
- **Closes finding #17.** The KI-1 comment at `KHYPELeg.sol:125-130`
  / `SpotStakingLeg.sol:126-130` describes the intent; Option A makes
  the code match it. The comment itself will be reworded from
  "tracked in HYPE units" to "tracked in stake-token units" as part
  of the implementation commit.
- **Invariant assertion.** Post-fix, the invariant
  `khypeBalance == pool.balanceOf(address(this), address(this))`
  becomes assertable in tests — a new fuzz-friendly property that
  did not exist before.
- **Does not collide with round-8's slippage guard.** The round-8
  `slippageBps` guard bounds the *HYPE* return of
  `router.swapExactUSDCForToken` against the oracle price
  (`KHYPELeg.sol:171-176`). Option A does not touch the router call
  or the HYPE-level guard; it only converts the router's HYPE return
  into a stake-token count after the guard has already accepted it.
  The two layers are orthogonal.

The one real trade-off is the `pool.balanceOf` vs. rate-derived
question at `allocateTo`. Two sub-options:

- **A1 (rate-derived)** — `khypeBalance += (hypeIn * pool.exchangeRate()) / 1e18`
  at `allocateTo`. Simple, one read, no double-lookup. Relies on the
  pool's rate not moving between the router swap and the
  `pool.exchangeRate()` read.
- **A2 (balance delta)** — capture
  `pool.balanceOf(address(this), address(this))` before `pool.stake`
  and after, then `khypeBalance += delta`. Exact by construction, but
  adds a second `pool` read per allocate.

**Recommendation: A2** for robustness. The pool's own
`balanceOf` is the source of truth for what was actually minted;
deriving it from `hypeIn * rate / 1e18` is correct only if the pool
mints at exactly `rate` at the moment of `stake`, which is a
reasonable assumption for kHYPE-style pools but a subtle invariant
we would otherwise rely on silently. A2 makes the invariant explicit
by construction. The extra `pool.balanceOf` call is
negligible gas (~200 gas per read) and only fires once per
`allocateTo`, which is a low-frequency aggregator action.

If the pool interface does not expose `balanceOf` in a
leg-relevant form (some venues hide it behind an
`IStakingPool` wrapper that only exposes `stake`/`unstake`/`credit`),
fall back to A1 and add a comment noting the assumption.

---

## 5. Pseudocode diff (shape only, not full rewrite)

Matching the style of `DESIGN_KI1_UNIT_RECONCILE.md §5`.

### `KHYPELeg.sol` — `currentValue` (lines 131-141)

```solidity
// BEFORE (current)
function currentValue() external view returns (uint256) {
    uint256 v = 0;
    if (khypeBalance > 0) {
        uint256 price = _hypePriceUsdc();
        // khypeBalance is 18-dec HYPE, price is 6-dec USDC/HYPE.
        v = (khypeBalance * price) / 1_000_000_000_000_000_000;
    }
    v += usdc.balanceOf(address(this));
    return v;
}

// AFTER (Option A)
function currentValue() external view returns (uint256) {
    uint256 v = 0;
    if (khypeBalance > 0) {
        uint256 price = _hypePriceUsdc();
        uint256 rate  = pool.exchangeRate();
        // khypeBalance is 18-dec stake tokens, rate is 18-dec
        // (stake→HYPE), price is 6-dec USDC/HYPE.
        // v_6dec = khypeBalance * rate * price / 1e36
        //   (cancel 18-dec stake, 18-dec HYPE, keep 6-dec USDC).
        v = (khypeBalance * rate * price) / 1_000_000_000_000_000_000_000_000_000_000_000;
    }
    v += usdc.balanceOf(address(this));
    return v;
}
```

### `KHYPELeg.sol` — `allocateTo` (lines 143-187)

```solidity
// AFTER (Option A2 — balance delta, shape only)
function allocateTo(uint256 usdAmount) external nonReentrant returns (uint256) {
    require(msg.sender == owner, "not owner");
    require(usdAmount > 0, "zero");

    uint256 price = _hypePriceUsdc();
    require(price > 0, "no oracle price");

    uint256 hypeIn = router.swapExactUSDCForToken(address(hype), usdAmount);
    require(hypeIn > 0, "router returned 0");

    // Round-8 slippage guard — unchanged.
    if (slippageBps > 0) {
        uint256 hypeMin = (usdAmount * 1e18 * (BPS_DENOM - slippageBps))
                          / (price * BPS_DENOM);
        require(hypeIn >= hypeMin, "slippage exceeded");
    }

    // Round-9 fix: capture the pool's stake-token delta, not the
    // raw HYPE input. khypeBalance is now the stake-token count.
    uint256 stakeBefore = pool.balanceOf(address(this), address(this));

    hype.safeApprove(address(pool), hypeIn);
    pool.stake(address(hype), hypeIn);

    uint256 stakeAfter = pool.balanceOf(address(this), address(this));
    require(stakeAfter >= stakeBefore, "pool mint regressed");
    khypeBalance += (stakeAfter - stakeBefore);   // stake-token units

    allocatedUsd += usdAmount;
    _recordApy(expectedApy());
    emit Allocated(usdAmount, allocatedUsd);
    return usdAmount;
}
```

### `KHYPELeg.sol` — `reduceFrom` (lines 210-254)

```solidity
// AFTER (Option A — shape only)
function reduceFrom(uint256 usdAmount) external nonReentrant returns (uint256 returnedUsd) {
    require(msg.sender == owner, "not owner");
    require(usdAmount > 0, "bad amount");
    require(khypeBalance > 0, "bad amount");
    uint256 price = _hypePriceUsdc();
    require(price > 0, "no oracle price");

    uint256 hypeAmount = (usdAmount * 1e18) / price;   // 18-dec HYPE

    // Round-9 fix: convert to stake tokens BEFORE decrementing the
    // ledger, so the ledger and the pool burn the same unit.
    uint256 rate = pool.exchangeRate();
    require(rate > 0, "pool rate is 0");
    uint256 stakeTokenAmount = (hypeAmount * rate) / 1e18;
    require(stakeTokenAmount > 0, "zero stake amount");
    require(khypeBalance >= stakeTokenAmount, "bad amount");

    khypeBalance -= stakeTokenAmount;   // stake-token units
    pool.unstake(address(this), stakeTokenAmount);

    uint256 period = pool.unbondingPeriod();
    if (period == 0) {
        uint256 hypeOut = pool.creditUnbonded(address(this), stakeTokenAmount, address(this));
        if (hypeOut > 0) {
            hype.safeApprove(address(router), hypeOut);
            uint256 u = router.swapExactTokenForUSDC(address(hype), hypeOut);
            usdc.safeTransfer(owner, u);
            returnedUsd = u;
        }
    }

    allocatedUsd = usdAmount <= allocatedUsd
        ? allocatedUsd - usdAmount
        : 0;

    emit Reduced(usdAmount, allocatedUsd);
}
```

### `SpotStakingLeg.sol` — identical shape

Same edits, with `khypeBalance` → `rewardHypeBalance`
(`SpotStakingLeg.sol:59`) and `_stake` / `_unstake` helpers at
`SpotStakingLeg.sol:288-294` taking the stake-token amount.

### Comment rewording (closes finding #17)

```solidity
// BEFORE (KHYPELeg.sol:125-130)
/**
 * KI-1 (Option A, DESIGN_KI1_UNIT_RECONCILE): khypeBalance is now
 * tracked in HYPE units (18 dec) -- the pool.exchangeRate() factor
 * is folded in at the boundary (allocateTo), so the valuation
 * math collapses to `hype * price`.
 */

// AFTER
/**
 * KI-1 (b) rate-tracking (DESIGN_KI1_RATE_TRACKING): khypeBalance is
 * tracked in STAKE-TOKEN units (18 dec) — the pool.exchangeRate()
 * factor is applied at the boundary (allocateTo) so that
 * khypeBalance == pool.balanceOf(address(this), address(this))
 * by construction. currentValue() re-applies the live rate before
 * multiplying by price, so the valuation tracks the pool's
 * mark-to-market value of the same stake-token position.
 */
```

### Adjacent `claimPending` note

`claimPending(uint256 amount)` at `KHYPELeg.sol:259-267` takes a
stake-token amount today (`pool.creditUnbonded(address(this), amount, …)`).
Under Option A that call site is already in stake-token units and
needs no change; the caller (owner / aggregator) must pass a
stake-token amount, which is what the current signature implies.

### Not changing

- `IYieldLeg` interface.
- Aggregator.
- `PerpFundingLeg`, `BasisHedgeLeg` (they don't use stake tokens).
- `TradeOnlyAgent`, `RegimeDetector`.
- Round-8 slippage guard (still bounds `hypeIn` at the router).
- Round-6 KI-1 USDC→HYPE boundary conversion (still applied).

---

## 6. Test plan

Add to `solidity/test/Legs.t.sol` in the existing
`KI1ReconcileTest` suite (or a new `KI1bRateTrackingTest` sibling).

The existing `MockPriceOracle` and `MockRouter` mocks are sufficient
for the price side. The staking pool mock (currently
`MockStakingPool` or the inline test contract used by `KI1ReconcileTest`)
needs one addition: a **mutable `setRate(uint256 rate)` method** that
lets the test move `pool.exchangeRate()` between calls. The mock
should mint stake tokens at the live rate at `stake()` time (i.e.
`deltaStake = hypeIn * rate / 1e18`), so the mint is consistent with
the option's A2 `pool.balanceOf`-delta semantics.

### New tests — `KHYPELeg`

- **`test_KI1a_KHYPELeg_currentValue_tracksRateChange`** —
  Allocate 200 USDC at $1/HYPE, rate 1.0 → 200 stake tokens
  minted, `khypeBalance == 200e18`. Rate rises to 1.2 (via
  `setRate(1.2e18)`). Assert `currentValue() == 240e6` ($240,
  reflecting 200 × 1.2 × $1). **This test fails on the current
  code** (which returns $200 — the missing `× rate` factor).

- **`test_KI1a_KHYPELeg_reduce_from_decrementsStakeTokenCount`** —
  Allocate 200 USDC at rate 1.0, rate rises to 1.2, `reduceFrom(100e6)`
  ($100, $1/HYPE). Assert
  `khypeBalance == (200e18 - 120e18) = 80e18` (stake-token units,
  not the current code's `100e18` HYPE-units). Assert that
  `pool.balanceOf(address(leg), address(leg)) == 80e18` (the
  on-chain ledger matches the pool). **This test fails on the
  current code** (which leaves `khypeBalance` at 100e18 HYPE units
  while the pool holds 80 stake tokens).

- **`test_KI1a_KHYPELeg_noAccountingDrift_acrossRateChanges`** —
  Full round-trip: allocate 200 USDC at rate 1.0, rate rises to 1.2,
  rate falls to 0.9, `reduceFrom(100e6)` at each state, then harvest.
  Assert final `khypeBalance == pool.balanceOf(address(leg),
  address(leg))` exactly (not "to within one rounding unit" — exact),
  and final `currentValue()` equals the expected USDC mark-to-market
  value of the residual stake tokens. This is the direct invariant
  the current code violates.

- **`test_KI1a_KHYPELeg_noDoubleCount_onRepeatAllocate`** —
  Regression for the adjacent §9.1 bug in
  `DESIGN_KI1_UNIT_RECONCILE.md`: two consecutive `allocateTo` calls
  must not double-count. Second allocate must add *only* the delta
  stake tokens minted by that call, not the pool's total balance.

- **`test_KI1a_KHYPELeg_reduceFrom_fullyUnstakes_atPostRate`** —
  Rate moves 1.0 → 1.2, then `reduceFrom` on the full residual
  amount. Assert `pool.balanceOf` returns to zero and
  `khypeBalance == 0`. Guards against a `khypeBalance` that goes
  negative or is stranded above zero after a full unstake.

### New tests — `SpotStakingLeg`

Same three tests as above, with `rewardHypeBalance` in place of
`khypeBalance` and the `_stake` / `_unstake` helpers at
`SpotStakingLeg.sol:288-294` being the call sites. The spot-staking
pool interface is identical to the kHYPE pool interface for this
purpose.

### Fuzz invariants (optional but cheap)

- **`invariant_khypeBalance_matchesPool`** —
  For any sequence of `allocateTo` / `reduceFrom` / `setRate` calls
  the invariant `khypeBalance == pool.balanceOf(address(leg),
  address(leg))` must hold exactly. This is the direct regression
  against the round-9 finding and the simplest property to fuzz.

### Not changing

- Existing `test_KI1_*` tests should still pass — they operate at
  `pool.exchangeRate() == 1e18` (the 1:1 test default) where Option
  A's arithmetic collapses to the current arithmetic. Only the
  `currentValue()` multiplier changes shape (extra `× rate` term that
  is 1 at the default rate), and the `khypeBalance += …` term changes
  shape (extra `× rate / 1e18` factor that is 1 at the default rate).
- `test_harvest_doesNotDecrement_allocatedUsd_KHYPE` / `_Spot`
  (round-8) — unaffected.
- `test_allocateTo_reverts_onSlippageExceeded_KHYPE` / `_Spot`
  (round-8 slippage guard) — unaffected; the guard is at the HYPE
  level and stays.

---

## 7. Blast radius

| Layer | Touched? | Notes |
|---|---|---|
| `IYieldLeg` interface | **No** | Signatures stay `allocateTo(uint256)` / `reduceFrom(uint256)` in USDC. Only internal arithmetic and `currentValue()` math change. |
| `YieldAggregator.sol` | **No** | Reads `currentValue()` the same way. Aggregator does not call `pool.exchangeRate()` directly. |
| `TradeOnlyAgent.sol` | **No** | Stake legs never touch the delegation stack. |
| `RegimeDetector.sol` | **No** | No leg-facing surface. |
| `PerpFundingLeg.sol` / `BasisHedgeLeg.sol` | **No** | Neither tracks stake tokens. `spotHypeBalance` in these legs is already consistent (USDC notionals throughout). |
| `IPriceOracle.sol` / `IERC20Router.sol` | **No** | Unchanged. |
| `IStakingPool.sol` | **No** | `exchangeRate()` and `balanceOf()` are already declared on the interface. |
| Test mocks | **Additive** | `MockStakingPool` (or its inline equivalent in `Legs.t.sol`) gains a `setRate(uint256)` method. Existing mocks untouched. |
| `solidity/scripts/verify.py` | **No** | No ABI change. |
| `check_repo.py` | **No** | Unchanged. |
| `deploy.py` / `test_deploy_anvil.py` | **No** | Unchanged. |
| Docs | **This file** | Plus a note in `DESIGN_KI1_UNIT_RECONCILE.md §9` pointing here, plus the round-9 changelog in `ROADMAP.md §2.8`. |

---

## 8. Migration risk

**Effectively none.** As of the 2026-09-22 state (per
`ROADMAP.md §4` M2 status), this repo is at M2 (testnet deployment,
pre-mainnet). The stake legs have never been deployed to a chain
where production capital can flow:

- `solidity/scripts/deploy.py` refuses any mainnet chain ID until
  Kinetiq publishes Elysium's real testnet / mainnet IDs
  (`ROADMAP.md §2.3`).
- `chainId 999` in the current placeholders is HyperEVM mainnet,
  which the roadmap explicitly says is *not* the deployment target.

Therefore no deployed contract has state populated by either the
buggy or the fixed code. The fix can land on top of the current
`khypeBalance` / `rewardHypeBalance` storage layout with **no**
upgrade script and **no** user interaction.

If a testnet deployment with non-zero state ever needs migration:

1. Deploy the fixed leg alongside the old one.
2. Read `khypeBalance` and `allocatedUsd` from the old leg.
3. Read `pool.balanceOf(old_leg, old_leg)` — the pool's stake-token
   balance is the source of truth and always correct, regardless of
   what the old leg's ledger claims.
4. Have the pool operator transfer the corrected stake tokens to the
   new leg contract.
5. Set the new leg's `khypeBalance` to the transferred amount.
6. (Optional) migrate the aggregator's `legs[i]` pointer via a
   future governance-gated setter (not present today; would need to
   be added).

For the actual M2 target this is a non-issue.

---

## 9. Follow-up items

- **Adjacent: KI-1 §9.1 double-count bug status.** The
  `khypeBalance += pool.balanceOf(…)` double-count bug flagged in
  `DESIGN_KI1_UNIT_RECONCILE.md §9.1` was fixed in round-6 by
  switching the source to `hypeIn` (the router return). That fix is
  present at `KHYPELeg.sol:181` / `SpotStakingLeg.sol:180`. The
  Option A2 balance-delta pattern in this design re-establishes the
  same invariant (`khypeBalance += delta`, not `khypeBalance +=
  total`) under the new stake-token semantics.
- **Adjacent: `_fallbackSig` production reachability.** The KI-2b
  Phase 2 aggregator refactor (a future design round) may change how
  the perp legs' `_fallbackSig` is reached in production. Not in
  scope for this doc.
- **Adjacent: real pool interface confirmation.** If the real kHYPE
  pool interface on HyperCore does not expose `balanceOf` in a form
  the leg can call without a wrapper, the Option A2 pattern needs
  to fall back to A1 (rate-derived at boundary). Confirm with
  Kinetiq when the HyperCore staking pool spec is published.
- **Adjacent: rate precision.** The design assumes
  `pool.exchangeRate()` is a 1e18 fixed-point number. Verify
  against the real kHYPE pool interface when it ships. If the pool
  uses 6-decimals or some other fixed-point, all the `1e18`
  multipliers in this doc need to be adjusted accordingly.

---

## 10. Decision record

**This is a DESIGN document. Implementation is deferred to a
follow-up commit.**

- **Status**: pending review. The design is ready for approval but
  has not been implemented in this round.
- **Owner for implementation**: agent F (a future agent in the
  round-10 / round-11 workstream), who will pick up the implementation
  once this design is approved.
- **Expected implementation scope**: ~60 lines of Solidity changes
  across two legs, plus ~4 new mocks methods and ~6 new tests in
  `Legs.t.sol`. No interface change, no aggregator change, no
  verifier change.
- **Verification gate**: all new tests pass, all existing tests pass
  (no regression), `check_repo.py` 0 FAIL, `forge test` green across
  the full 171+ test suite.
- **Rationale for deferral**: this is a round-9 review finding that
  deserves a design round before implementation. The blast radius is
  small but the accounting semantics change enough that a design
  review (with the mock pool's rate-mutation surface spelled out)
  is worth the round-trip before the code lands.

If the design is approved as-is, the implementation commit will:

1. Modify `KHYPELeg.sol` and `SpotStakingLeg.sol` per §5.
2. Update the KI-1 comment per §5 to say "stake-token units" instead
   of "HYPE units".
3. Add `setRate(uint256)` to the mock staking pool.
4. Add the six new tests from §6.
5. Update `docs/DESIGN_KI1_UNIT_RECONCILE.md §9` to mark the
   `khypeBalance` rate-tracking follow-up as CLOSED with a pointer
   to this doc.
6. Update `docs/ROADMAP.md §2.5` KI-1 row to note that the
   rate-tracking sub-bug is now implemented (not just designed).
7. Update `README.md` and `solidity/README.md` byte-count tables if
   either leg's deployed size changes.

---

*Design authored 2026-09-22 for the Elysium builder workstream, in
response to round-9 adversarial review finding #1/#2 and finding #17.
All `file:line` citations were verified against the working tree at
HEAD `e01dc1d` (round-9 delegation sig canonicality commit).
Re-verify before implementation.*
