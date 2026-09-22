# KI-1 — Stake-Leg Unit-Domain Reconciliation

**Status**: design proposal · **Severity**: pre-M2 correctness · **Blast radius**: `KHYPELeg.sol`, `SpotStakingLeg.sol` only (no interface change) · **Related**: `docs/ROADMAP.md §2.5`

---

## 1. Problem statement

`KHYPELeg` and `SpotStakingLeg` conflate three unit domains inside one state
vector:

1. **USDC (6 decimals)** — what the aggregator passes to `allocateTo` /
   `reduceFrom` and what `currentValue()` returns. Defined by
   `IYieldLeg.allocateTo(uint256 amount)` — *"asset units to allocate (USDC
   6 decimals by convention)"* (`solidity/src/interfaces/IYieldLeg.sol:42`).
2. **HYPE (18 decimals)** — what the router actually swaps into
   (`router.swapExactUSDCForToken`, `KHYPELeg.sol:128`) and what the pool
   stakes (`pool.stake`, `KHYPELeg.sol:130`).
3. **Stake tokens / kHYPE (18 decimals)** — the value of `khypeBalance`
   (`KHYPELeg.sol:56`, `SpotStakingLeg.sol:57` via `rewardHypeBalance`),
   readable via `pool.balanceOf(address(this), address(this))`.

`currentValue()` reconciles the HYPE/stake-token side back to USDC using the
oracle price (`KHYPELeg.sol:111-122`). But `allocateTo` and `reduceFrom`
**never** reconcile — they treat the `amount` parameter and `khypeBalance`
as if they were in the same unit, and they decrement `allocatedUsd` by the
USDC `amount` (which is fine) *and* decrement `khypeBalance` by the USDC
`amount` (which is not).

**Concrete example.** The aggregator deposits 1 000 000 USDC (=$1 000 at 6
decimals) into `KHYPELeg`. Oracle is $2.00/HYPE.

- `allocateTo(1_000_000)`:
  - Router swaps 1 000 000 USDC for `hypeIn` HYPE = 500.0 HYPE = `500e18`
    wei-HYPE.
  - Pool stakes `500e18` HYPE and mints kHYPE. `khypeBalance` becomes
    `500e18` (assuming 1:1 mint rate).
  - `allocatedUsd = 1_000_000`. Correct so far.

- Oracle drifts to $2.05/HYPE. Aggregator rebalances: `reduceFrom(500_000)`
  (= $500 USDC).

- `reduceFrom(500_000)`:
  - Guard: `khypeBalance >= amount` → `500e18 >= 500_000` → true. The guard
    passes, but the numeric comparison is comparing 500 HYPE against
    $500 — the invariant is meaningless.
  - `khypeBalance -= 500_000` → `499_999_500_000_000_000_000_000e-3`…
    i.e. `khypeBalance` drops by 0.0000005 HYPE, not by the ~243.90 HYPE
    that $500 USDC actually represents.
  - `pool.unstake(address(this), 500_000)` — the pool burns
    **500 000 wei-kHYPE**, not the ~243.90e18 wei-kHYPE the caller meant.
    The leg has just told the pool to unstake a *dust fraction* while
    recording that it took $500 off the books.
  - If `unbondingPeriod == 0`, `creditUnbonded` returns ~0 wei-HYPE; the
    leg then calls `router.swapExactTokenForUSDC(hype, 0)`, sends nothing
    to the owner, but still decrements `allocatedUsd` by 500 000. The
    aggregator thinks $500 came back; the vault's USDC balance gained
    zero.
  - `harvest()` later sweeps USDC and calls `allocatedUsd -= u` where `u`
    is *USDC balance* — decrementing the USD ledger by the actual USDC
    in the contract rather than by the yield accrued.

**Result.** After the drift-and-reduce sequence, `allocatedUsd` says the
leg holds $500, `khypeBalance` says it holds ~500 HYPE (~$1025 worth),
`currentValue()` returns ~$1025, but the pool only has a tiny amount
unstaking. Every subsequent `currentValue()` call is inflated by the
amount of USDC the aggregator recorded as returned but never actually
received. This drifts `_allocatedTotal` in the aggregator
(`YieldAggregator.sol:315, 325, 416`) upward versus actual leg holdings,
which inflates `totalAssets()` (`YieldAggregator.sol:180-182`) and drives
the ERC-4626 exchange rate up — a first-depositor-style attack surface on
top of the accounting bug.

---

## 2. Root cause

The interface `IYieldLeg` (`solidity/src/interfaces/IYieldLeg.sol:38-46`)
deliberately makes `amount` USDC so the aggregator can pass weight
proportions straight through without any asset conversion
(`YieldAggregator.sol:377-384`). The stake legs take that USDC and:

- **Do the conversion once** on the way in, via the router
  (`KHYPELeg.sol:128` — `router.swapExactUSDCForToken`), which is fine.
- **Track the HYPE/kHYPE side in an 18-decimal field** (`khypeBalance`,
  `rewardHypeBalance`) — fine.
- **Track the USDC side in a 6-decimal field** (`allocatedUsd`) — fine.
- **Subtract the USDC `amount` from the 18-decimal field** on reduce
  (`KHYPELeg.sol:156`, `SpotStakingLeg.sol:155`) — **the bug**. Same
  problem feeds `pool.unstake(address(this), amount)` on the next line.
- **Subtract the USDC balance from `allocatedUsd`** on harvest
  (`KHYPELeg.sol:145`, `SpotStakingLeg.sol:144`) — arguably correct in
  shape (both are USDC), but the semantic is wrong: `harvest()` only
  sweeps **realised yield**, not principal, so decrementing the
  principal ledger by the sweep amount is at best confusing and at worst
  wrong if the leg ever holds principal USDC in the contract (e.g.
  leftover from a partial allocation).
- **`khypeBalance` is set to `pool.balanceOf(address(this), address(this))`
  in the allocation step** (`KHYPELeg.sol:132`,
  `SpotStakingLeg.sol:131`) — but that returns the leg's *current total*
  kHYPE balance, not the delta. A second `allocateTo` call would either
  double-count (if the previous stake is still in the pool) or drift from
  the real accounting (if the previous stake already partially unstaked).
  This is a second, adjacent bug worth noting but out of scope for KI-1.

The three operations that are unsafe in the current code:

| Operation | Location | Bug |
|---|---|---|
| `reduceFrom` guards `khypeBalance >= amount` | `KHYPELeg.sol:154`, `SpotStakingLeg.sol:153` | Compares HYPE to USDC |
| `khypeBalance -= amount` | `KHYPELeg.sol:156`, `SpotStakingLeg.sol:155` | Subtracts USDC from HYPE |
| `pool.unstake(address(this), amount)` | `KHYPELeg.sol:157`, `SpotStakingLeg.sol:156` | Passes USDC to a stake-token API |

`currentValue()` itself is *unit-correct* — it multiplies `khypeBalance`
by the pool exchange rate and then by the HYPE/USDC price
(`KHYPELeg.sol:116-118`). The problem is only on the mutation side.

---

## 3. Design options

### Option A — Convert once at the boundary, track only HYPE internally

`allocateTo(usdAmount)` converts USDC → HYPE internally using the router
and its oracle, keeps only `hypeBalance` (18 decimals) and
`allocatedUsd` (6 decimals, informational only). `reduceFrom(usdAmount)`
converts USDC → HYPE at the *current* price, unstakes that many HYPE, and
converts the returned HYPE back to USDC on credit. No HYPE-denominated
arithmetic is ever applied to a USDC variable.

**Pro**
- Single source of truth in one unit (HYPE), matching what the pool
  actually holds. The pool's `exchangeRate()` and `balanceOf()` calls stay
  internally consistent.
- No new state variables, no reconciliation logic, no periodic "sync on
  oracle tick" task. The state can't drift because it's only touched in
  HYPE units.
- Interface unchanged. The aggregator's call-site (`YieldAggregator.sol:381`
  and `:314, 324, 405`) is untouched.
- Matches the way `currentValue()` already does the math — every call
  uses the live oracle price.

**Con**
- Every `reduceFrom` still calls `_hypePriceUsdc()` (already wired via
  `IPriceOracle` — `KHYPELeg.sol:201-205`). If the oracle is unwired
  (test / fallback mode), the conversion factor is 0 and `reduceFrom`
  must fall back gracefully (see pseudocode below).
- The `allocatedUsd` field becomes bookkeeping-only. Any consumer that
  currently reads `allocatedUsd()` to make decisions needs to switch to
  `currentValue()`. Grep in this repo shows no such consumer — the field
  is write-only outside the legs (`allocatedUsd` appears only inside
  `src/legs/`, never in the aggregator or tests).

**Blast radius**
- `KHYPELeg.sol` and `SpotStakingLeg.sol` only. Interface, aggregator,
  `TradeOnlyAgent`, `RegimeDetector` untouched.

### Option B — Track both units in parallel, reconcile on oracle tick

Keep `khypeBalance` and `allocatedUsd` as today, add a `reconcile()`
function (or a periodic internal call) that snapshots
`allocatedUsd_expected = khypeBalance * exchangeRate / 1e18 * price / 1e6`
and corrects `allocatedUsd` when it diverges beyond a threshold.

**Pro**
- Additive change — no rewrite of `allocateTo` / `reduceFrom`.
- Preserves the informational `allocatedUsd` view for frontends.

**Con**
- Two sources of truth by construction. Any mutation of either field
  needs a corresponding update to the other, or the next reconcile tick
  "fixes" an unrelated drift (e.g. an oracle flash) by overwriting
  bookkeeping the caller relied on.
- Reconcile cadence is a governance knob that the aggregator spec does
  not currently expose — `harvestFromAllLegs()` (`YieldAggregator.sol:353`)
  would need to be extended, or the leg would need a self-correcting
  hook on every mutation.
- Does **not** fix the immediate reduce bug: `pool.unstake(amount)` still
  gets USDC unless we also convert at that call site — at which point
  we've moved to Option A anyway.
- Oracle-price drift between `allocateTo` and the next `reconcile` still
  shows up in `_allocatedTotal` in the aggregator until the tick fires.

**Blast radius**
- Same as Option A *plus* a new public method on `IYieldLeg` or a hack
  through `harvest()`. If added to `IYieldLeg`, `MockLeg` in
  `YieldAggregator.t.sol:47` needs updating too.

### Option C — Force the aggregator to convert to HYPE before calling legs

Add a wrapper layer (either in the aggregator or a `HypeAmountAdapter`)
that converts USDC → HYPE before calling `allocateTo`, so the legs
receive HYPE-denominated amounts throughout.

**Pro**
- Concentrates the conversion logic in one place.

**Con**
- Breaks the `IYieldLeg` interface contract (`IYieldLeg.sol:42` — "asset
  units to allocate (USDC 6 decimals by convention)"). Perp and basis
  legs already use USDC notionals (per `BasisHedgeLeg.sol:71, 210`),
  and the perp venue quotes notionals in USDC. Making the aggregator
  convert for only the stake legs makes the interface ambiguous.
- Touches `YieldAggregator._distribute` and `executePending`
  (`YieldAggregator.sol:307-327, 376-384`) — the highest-risk area of
  the file, the one we only just hardened in round-4 KI-5
  (`YieldAggregator.sol:317-325, 396-416`).
- Aggregator has to pick which oracle and which token to convert to;
  different legs could legitimately want different conversion factors in
  the future (e.g. a non-HYPE asset).

**Blast radius**
- `IYieldLeg` interface semantics, aggregator, `MockLeg` in tests, all
  4 legs, `verify.py` ABI coverage.

---

## 4. Recommended option — **A**

Option A is the only option that eliminates the bug at its source. Options
B and C both leave `pool.unstake(amount)` in some USDC-ish space and just
add reconciliation around it, which is a strictly larger surface area
than fixing the mutation directly.

Specifically for this repo at 2026-09-22:

- **The `IYieldLeg` interface stays as-is.** The aggregator's call sites
  (`YieldAggregator.sol:314, 324, 381, 405`) all keep passing USDC;
  `_distribute` (`YieldAggregator.sol:376-384`) and `executePending`
  (`YieldAggregator.sol:307-327`) keep their KI-5 hardening.
- **Only the two stake legs change.** `PerpFundingLeg` and
  `BasisHedgeLeg` don't suffer from this bug because they already track
  `spotHypeBalance` and use USDC notionals consistently
  (`PerpFundingLeg.sol:73, 207-226`; `BasisHedgeLeg.sol:71, 210-228`).
- **Pre-M2.** No production capital has touched these contracts, so
  state migration is a non-issue (§8 below).
- **Oracle dependency is already there.** `IPriceOracle.priceOf("HYPE")`
  (`solidity/src/interfaces/IPriceOracle.sol:14`) is a hard dependency
  of `currentValue()` on both stake legs today
  (`KHYPELeg.sol:117-118`, `SpotStakingLeg.sol:117-118`). Option A
  doesn't introduce a new dependency; it just uses the existing one in
  the mutation paths instead of only in the read path.

The one real tradeoff is oracle availability on the reduce path.
Option A handles this by requiring `_hypePriceUsdc()` to return non-zero
in `reduceFrom` (and reverting with a clear error otherwise). If the
oracle is unwired (`oracle == address(0)`), the leg can fall back to
the ratio `allocatedUsd * 1e12 / khypeBalance` as an implicit historical
average — but that fallback only makes sense after at least one
successful `allocateTo`, so it must reject `reduceFrom` if
`khypeBalance == 0` (already the case via the existing
`require(khypeBalance >= amount, "bad amount")` guard shape).

---

## 5. Pseudocode diff (shape only, not full rewrite)

### `KHYPELeg.sol` — `allocateTo` (lines 124-138)

```solidity
// BEFORE (current)
function allocateTo(uint256 amount) external nonReentrant returns (uint256) {
    require(msg.sender == owner, "not owner");
    require(amount > 0, "zero");

    uint256 hypeIn = router.swapExactUSDCForToken(address(hype), amount);
    hype.safeApprove(address(pool), hypeIn);
    pool.stake(address(hype), hypeIn);

    khypeBalance += pool.balanceOf(address(this), address(this)); // BUG: total, not delta
    allocatedUsd += amount;
    ...
}

// AFTER (Option A — shape only)
function allocateTo(uint256 usdAmount) external nonReentrant returns (uint256) {
    require(msg.sender == owner, "not owner");
    require(usdAmount > 0, "zero");

    // 1. Convert USDC -> HYPE (already done by the router; keep as-is).
    uint256 hypeIn = router.swapExactUSDCForToken(address(hype), usdAmount);
    require(hypeIn > 0, "router returned 0");

    // 2. Stake.
    hype.safeApprove(address(pool), hypeIn);
    pool.stake(address(hype), hypeIn);

    // 3. Record the *delta* of kHYPE received, not the pool total.
    //    (Adjacent bug — see §2. Out of strict KI-1 scope but required
    //     for the invariant we're establishing.)
    uint256 kHypeAfter = pool.balanceOf(address(this), address(this));
    khypeBalance += kHypeAfter;   // first-call semantics; subsequent
                                  // calls need a "before" snapshot.

    // 4. `allocatedUsd` stays informational (USDC ledger).
    allocatedUsd += usdAmount;
    _recordApy(expectedApy());
    emit Allocated(usdAmount, allocatedUsd);
    return usdAmount;
}
```

### `KHYPELeg.sol` — `reduceFrom` (lines 152-172)

```solidity
// AFTER (Option A — shape only)
function reduceFrom(uint256 usdAmount) external nonReentrant returns (uint256 returnedUsd) {
    require(msg.sender == owner, "not owner");
    require(usdAmount > 0, "zero");

    // 1. Convert USDC -> HYPE at the *current* oracle price.
    uint256 price = _hypePriceUsdc();
    require(price > 0, "no oracle price");
    uint256 hypeAmount = (usdAmount * 1e18) / price;
    // usdAmount is 6-dec USDC, price is 6-dec USDC per 1 HYPE, so
    // hypeAmount is in 18-dec HYPE.

    // 2. Convert HYPE -> kHYPE using the pool's exchange rate so we
    //    ask the pool to unstake the right number of stake tokens.
    uint256 rate = pool.exchangeRate();
    uint256 stakeTokenAmount = (hypeAmount * 1e18) / rate;

    // 3. Guard: don't over-withdraw against the on-book balance.
    require(khypeBalance >= stakeTokenAmount, "over-reduce");

    khypeBalance -= stakeTokenAmount;
    pool.unstake(address(this), stakeTokenAmount);   // now in the right unit

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

    // 4. Bookkeeping: `allocatedUsd` reflects the *attempted* USDC cut.
    //    If we didn't return the USDC yet (unbonding pending), the
    //    aggregator's KI-5 fix in YieldAggregator.sol:324 / :405
    //    will handle the mismatch via the actual returned value.
    if (allocatedUsd >= usdAmount) allocatedUsd -= usdAmount; else allocatedUsd = 0;
    emit Reduced(usdAmount, allocatedUsd);
}
```

### `SpotStakingLeg.sol` — identical shape

Same edit, with `khypeBalance` → `rewardHypeBalance`
(`SpotStakingLeg.sol:57`) and the internal `_stake` / `_unstake` helpers
at `SpotStakingLeg.sol:198-204` taking the stake-token amount instead of
the raw USDC amount.

### Adjacent `harvest()` fix

Both stake legs currently do `allocatedUsd -= u` on harvest
(`KHYPELeg.sol:145`, `SpotStakingLeg.sol:144`), which conflates yield
sweep with principal reduction. Under Option A this should be a no-op
on `allocatedUsd` — the yield has already been marked to market in
`currentValue()` via the exchange rate, so `harvest()` should only move
USDC and emit `Harvested`. This is a small but important cleanup that
should land in the same commit as the KI-1 fix.

---

## 6. Test plan

Add to `solidity/test/Legs.t.sol` (which already deploys real `KHYPELeg`
and `SpotStakingLeg` contracts against mock addresses — see
`Legs.t.sol:26-47`). To actually exercise the unit-conversion math we
need three new mocks alongside the existing `MockUSDC` / `MockLeg` in
`YieldAggregator.t.sol`:

### New mocks (in a shared `solidity/test/mocks/` file or inlined)

1. **`MockPriceOracle`** implementing `IPriceOracle`
   (`solidity/src/interfaces/IPriceOracle.sol`):

   ```solidity
   contract MockPriceOracle is IPriceOracle {
       uint256 public hypePriceUsdc = 2_000_000;   // $2.00, 6 dec
       uint256 public hypeApyBps    = 1000;
       function setPrice(uint256 p) external { hypePriceUsdc = p; }
       function priceOf(string calldata t) external view returns (uint256) {
           return t == "HYPE" ? hypePriceUsdc : 1_000_000;
       }
       function getApy(string calldata t) external view returns (uint256) {
           return hypeApyBps;
       }
   }
   ```

2. **`MockRouter`** implementing `IERC20Router`
   (`solidity/src/interfaces/IERC20Router.sol`): converts USDC ↔ HYPE
   at a fixed price the test can mutate between calls, and swaps in the
   opposite direction for the reduce path.

3. **`MockStakingPool`** implementing `IStakingPool`
   (`solidity/src/interfaces/IStakingPool.sol`): tracks the leg's
   stake-token balance, mint 1:1 at 1e18 exchange rate (test-friendly),
   `unbondingPeriod() == 0` so the reduce path is synchronous.

### New tests to add

- `test_KI1_KHYPELeg_reduceFrom_usesOraclePrice` —
  Set price=$2, allocate $1000 (=$1_000_000 USDC) → router should be
  called with $1_000_000, should return 500e18 HYPE, pool should mint
  500e18 kHYPE. Then mutate price to $2.05, call
  `reduceFrom(500_000)`, assert `pool.unstake` was called with the
  stake-token amount corresponding to ~243.90e18 HYPE (i.e.
  `(500_000 * 1e18) / 2_050_000`), **not** with 500 000 raw USDC.
  Assert `returnedUsd` ≈ 500 000 USDC and `allocatedUsd == 500 000`.

- `test_KI1_KHYPELeg_reduceFrom_noOverWithdraw` —
  Allocate $1000, price stable, call `reduceFrom(2_000_000)` (double).
  Should revert with `"over-reduce"` (or the existing `"bad amount"`).

- `test_KI1_KHYPELeg_reduceFrom_revertsIfOracleUnwired` —
  Deploy with `oracle == address(0)`, allocate, mutate, call
  `reduceFrom`. Should revert with `"no oracle price"` (the Option A
  guard). This documents the expected behaviour when the fallback
  is in use.

- `test_KI1_KHYPELeg_currentValue_matchesReduceArithmetic` —
  After allocate-then-partial-reduce, assert `currentValue()` returns
  the residual in USDC terms to within one rounding unit. This is
  the direct invariant the current code violates.

- **Repeat all four for `SpotStakingLeg`** (the code shape is
  identical per `SpotStakingLeg.sol:124-171`).

- `test_KI1_KHYPELeg_harvest_noLongerReducesAllocatedUsd` —
  After harvest, `allocatedUsd` should equal the initial allocation
  minus reduces, not the initial allocation minus the swept USDC.

### Fuzz invariants (optional but cheap)

- For all price paths `p ∈ [1e6, 100e6]` and allocation sizes
  `a ∈ [1, 1e8]`, the invariant
  `allocatedUsd_after_reduce == allocatedUsd_before - usdAmount`
  and `currentValue() <= currentValue_at_last_allocate * (p / p0)`
  should hold. Foundry's `forge test --fuzz-runs=1000` makes this a
  one-liner once the mocks are in place.

### Not changing

- Existing tests in `Legs.t.sol:57-186` should still pass unchanged —
  the interface is unchanged, and the tests that exercise
  `allocateTo`/`setFixedApyBps`/`name()` don't reach the reduce path.
- `YieldAggregator.t.sol` should not need edits because `MockLeg`
  (`YieldAggregator.t.sol:47-90`) doesn't call `reduceFrom` with a
  real unit conversion; its stub semantics are unaffected.

---

## 7. Blast radius

| Layer | Touched? | Notes |
|---|---|---|
| `IYieldLeg` interface | **No** | Signatures stay `allocateTo(uint256)` / `reduceFrom(uint256)` in USDC. Only the internal arithmetic changes. |
| `YieldAggregator.sol` | **No** | `_distribute` (`:376-384`) and `executePending` (`:307-327`) keep passing USDC and reading `currentValue()` the same way. |
| `TradeOnlyAgent.sol` | **No** | The stake legs (`KHYPELeg`, `SpotStakingLeg`) never call
  the delegation stack — the writer is a HyperCore primitive owned by
  the perp/basis legs. Grep confirms no `_zeroSig()` /
  `submitIntent` references in either stake leg. |
| `PerpFundingLeg.sol` / `BasisHedgeLeg.sol` | **No** | Their USDC notionals are already consistent
  (`PerpFundingLeg.sol:73, 207-226`; `BasisHedgeLeg.sol:71, 210-228`). |
| `RegimeDetector.sol` | **No** | No leg-facing surface. |
| `IPriceOracle.sol` | **No** | Already provides `priceOf("HYPE")` (`:14`); we just consume it
  in more code paths. |
| Test mocks | **Add** | `MockPriceOracle`, `MockRouter`, `MockStakingPool` in `solidity/test/`. Existing mocks untouched. |
| `solidity/scripts/verify.py` | **No** | No ABI change. |
| `hypeback/` python | **No** | Python sim doesn't model this drift; unrelated. |
| Docs | **This file** | Plus a line in `ROADMAP.md §2.5` flipping KI-1 from "documented"
  to "designed" when the doc lands. |

---

## 8. Migration risk

**Effectively none.** As of the 2026-09-22 state (per
`ROADMAP.md:192-193`), this repo is at M2 (testnet deployment,
pre-mainnet). The stake legs have never been deployed to a chain where
production capital can flow:

- The deploy harness (`solidity/scripts/deploy.py`) is a dry-run and
  refuses any real chain ID until Kinetiq publishes the Elysium testnet
  and mainnet IDs (`ROADMAP.md:108-118`).
- `chainId 999` in the current placeholders is HyperEVM mainnet, which
  the roadmap explicitly says is *not* the deployment target.

Therefore, no deployed contract has state populated by either the buggy
or the fixed `reduceFrom`. The fix can land on top of the current
`khypeBalance` / `rewardHypeBalance` storage layout without any upgrade
script or user interaction.

If, for some reason, a fork of these contracts has already been deployed
to an Elysium testnet with non-zero state, the recovery path is:

1. Deploy the fixed leg alongside the old one.
2. Read `khypeBalance` and `allocatedUsd` from the old leg.
3. Compute the corrected stake-token balance as
   `old_khypeBalance * 1e18 / (old_allocatedUsd * 1e18 / price * rate)`
   — i.e. re-derive the actual stake-token balance from the pool's own
   `balanceOf` view, which is always correct.
4. Have the pool operator transfer the corrected stake tokens to the new
   leg contract.
5. Migrate the aggregator's `legs[i]` pointer via a future
   governance-gated setter (not present today; add if this ever bites).

For the actual M2 target this is a non-issue.

---

## 9. Follow-up items outside KI-1 scope

These were surfaced while analysing KI-1 but should be separate issues:

- **Adjacent `khypeBalance += pool.balanceOf(...)` double-count**
  (`KHYPELeg.sol:132`, `SpotStakingLeg.sol:131`) — a repeat
  `allocateTo` call adds the pool's *total* balance rather than the
  delta, so a second allocation double-counts the first one's stake.
  Fix in the same commit as KI-1: capture `balanceBefore` and add
  `balanceAfter - balanceBefore`.
- **`harvest()` decrementing `allocatedUsd` by USDC sweep**
  (`KHYPELeg.sol:145`, `SpotStakingLeg.sol:144`) — should be a
  no-op on `allocatedUsd`; yield is already marked to market in
  `currentValue()`.
- **Router slippage of 0** on both legs (`KHYPELeg.sol:25-26`,
  `SpotStakingLeg.sol:27`) — orthogonal to KI-1 but should be added
  in the same round-5 hardening pass.

---

*Design authored 2026-09-22 for the Elysium builder workstream. All
`file:line` citations were verified against the working tree at that
commit; re-verify before implementation.*
