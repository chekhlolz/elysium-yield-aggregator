# Test Coverage Gap Analysis

**Scope.** The four `solidity/test/*.t.sol` files vs the seven source contracts
under `solidity/src/`. Companion to `solidity/tests_plan.md` (the original
235-case plan) and to the round-3/4 known-issues log in `docs/ROADMAP.md`
§2.4–§2.5 (KI-1..KI-6).

**Read of the verifier.** `check_repo.py` is not a test runner. It does
13 doc-string regex checks (D1–D11, I1–I4), compiles every `.sol` under
`src/` with solc 0.8.26 and checks: S1 (compiles clean), S2 (ERC-4626
surface present on `YieldAggregator`), S3 (source contains the
`expiresAt == 0` short-circuit), S4 (`revoke` in the ABI), S5 (README
size/ABI tables match the fresh build). It does not run `forge test`,
does not check test coverage, does not fuzz, does not detect reentrancy
or oracle-griefing patterns. Anything in this doc that touches runtime
behaviour is orthogonal to `check_repo.py`.

---

## 1. Current state

| Test file | Tests | Contract(s) | What is actually exercised |
|---|---|---|---|
| `solidity/test/YieldAggregator.t.sol` | 28 | `YieldAggregator` (+ `MockUSDC`, `MockLeg`) | Constructor (owner, keeper, timelock, zero-leg, weights-sum), `deposit` happy path / zero / paused, `withdraw` happy path / overspend, `requestAllocation` keeper-only + bad weights + one-at-a-time, `cancelPending` (FIX-12 gating, wrong-id, owner, keeper), `executePending` before/after timelock, reentrancy-guard reset across two deposits and two `executePending`, `setKeeper` (3 cases), `harvestFromAllLegs` keeper-gate + cascade, `currentApyBps` weighted average, `previewDeposit`/`previewRedeem` vs `convertTo*`. |
| `solidity/test/TradeOnlyAgent.t.sol` | 19 | `TradeOnlyAgent` | EIP-712 happy path, `expiresAt` expiry boundary (`FIX-7`), field-zero guards (`keeper`/`maxNotional`/`maxPerOrder`), wrong-signer, tampered `r`, bad `v` revert, `revoke` (zero-keeper, `isRevoked` state, invalidates a live delegation), `recordExecution` keeper-role / within-cap / over-cap / per-venue isolation / first-execution-sets-cap, empty `assetIds` = allow-all. |
| `solidity/test/RegimeDetector.t.sol` | 16 | `RegimeDetector` | Constructor (owner, feed, defaults), `setThresholds` owner-only + bad-order reject (round-3 P0 fix), `computeRegime` priority chain (`HIGH_VOL` > `FUNDING_NEG` > `FUNDING_STRONG` > `FUNDING_WEAK`) at boundaries, `computeRegime(0, _)` = `FUNDING_WEAK`, one fuzz test on `computeRegime`, `weightsForRegime` sums to 10_000 for all four regimes. |
| `solidity/test/Legs.t.sol` | 15 | `KHYPELeg`, `SpotStakingLeg`, `PerpFundingLeg`, `BasisHedgeLeg` | `setFixedApyBps` refreshes `expectedApy` on all 4 legs (KI-4), non-owner rejection, `BasisHedgeLeg.allocateTo` dust/zero guards (KI-3), `allocateTo` non-owner rejection on all 4, `name()` returns the expected literal on all 4. |
| **Total** | **78** | | |

Against the original `tests_plan.md` target of 235 cases we are at ~33%.

---

## 2. Coverage gaps by contract

### 2.1 `YieldAggregator`

Covered: constructor happy/edge paths, `deposit`, `withdraw`, `requestAllocation`,
`cancelPending`, `executePending`, `harvestFromAllLegs` (keeper-gate + happy),
`setKeeper`, `currentApyBps`, `previewDeposit`, `previewRedeem`, reentrancy-guard
reset.

**Missing / under-covered (public functions):**

- `mint(uint256 shares, address)` — zero tests. No zero-share revert, no
  paused, no dust-assets revert, no reentrancy-guard reset.
- `redeem(uint256 shares, address, address)` — zero tests. In particular the
  share-allowance branch at lines 269–273 is dead-lettered: the code reads
  `asset_.allowance(_owner, msg.sender)` and calls `asset_.safeApprove(msg.sender,
  current - newShares)`, but for ERC-4626 `redeem` the relevant allowance is
  `shareBalances[_owner]`, not `asset_.allowance`. The current test file does not
  exercise `redeem` at all, so this bug is silent.
- `withdraw` share-allowance branch (lines 248–255) — has the same bug shape:
  the code checks `asset_.allowance(_owner, msg.sender) >= assets` and pulls
  `assets` worth of tokens from `_owner` into the vault, then `_redeem` also
  sends `assets` to the receiver. That means a share-holder must mint `assets`
  into the aggregator themselves before delegating a withdrawal. `test_withdraw_
  moreThanOwned` trips the ERC-20 `transferFrom`, but there is no positive-path
  test with a real delegated-withdrawal sequence and no revert test for
  "no token allowance but positive shares". The test at line 202 uses
  `vm.expectRevert()` with no message assertion, so any revert would pass.
- `setPaused` — no test that it blocks `mint`, `withdraw`, or `redeem`. Only
  `deposit` has a paused test.
- `setTimelock` — zero tests. No zero-timelock edge case, no large-timelock
  edge case (does `block.timestamp + timelockSeconds` overflow `uint64`?), no
  test that a very short timelock makes `executePending` callable in the same
  block.
- `setPaused(true)` after a request, then `executePending` — is it gated?
  The function does not carry `notPaused`, so pause does not stop rebalances.
  This is probably intended (owner-gated keeper workflow survives pause), but
  it is not pinned down by a test.
- `currentValueOfLeg(i)`, `totalLegValue()`, `legsView()`, `legAt(i)`, `asset()`,
  `shares(address)`, `convertToAssets`, `convertToShares` — mostly exercised
  indirectly through `deposit`/`withdraw`, but `legAt(4)` and
  `currentValueOfLeg(4)` (the `bad leg index` revert) have no explicit tests.
- `previewMint`, `previewWithdraw` — no direct assertions (only `previewDeposit`
  and `previewRedeem` are checked).
- **`_distribute` under leg reversion** — if `legs[i].allocateTo(delta)` reverts
  mid-loop, `deposit` has already called `safeTransferFrom` and moved the assets
  into the aggregator. If the guard is a naive `try/catch` this would silently
  skip the leg; there is no `try/catch` here, so the whole deposit reverts.
  The behaviour is correct-by-construction but not pinned down by a test. Same
  for `legs[i].allocateTo` returning something other than `amount` (the mock
  always echoes `amount`; real legs might return less — e.g. BasisHedgeLeg's
  50/50 split — but the aggregator adds `allocated` to `distributed`, which is
  what is added to `_allocatedTotal`, so this is actually OK; just untested).
- **First depositor / share-creation edge cases** — no test with two
  depositors in sequence, no test that a second depositor gets shares at the
  pro-rata rate after the first already seeded 1:1. No test that a leg's
  `currentValue` drifting upwards before a second deposit correctly raises
  the share exchange rate.
- **Zero-share withdraw** — `_redeem` guards `newShares == 0` via the
  `convertToShares` result (`require(newShares > 0, "dust shares")`), but no
  test uses a very small `assets` value that rounds to zero shares.
- **Dust withdraw with partial free cash** — if the vault holds some free USDC
  from a partial `reduceFrom`, does `withdraw` mix free cash with fresh
  reductions correctly? Not tested.
- **All-weights-zero / all-weights-one / concentrated weights** — no test
  with `w = [10000, 0, 0, 0]` or `[0, 2500, 2500, 5000]`. `_distribute` skips
  zero-portion legs (`if (portion == 0) continue`) — that branch is not
  exercised.
- **`executePending` reduce path when a leg under-returns or reverts** —
  KI-5 fix is claimed; there is no regression test. A `MockLeg` that returns
  `delta / 2` on `reduceFrom` should still leave the invariant
  `_allocatedTotal + freeCash ≤ totalAssets` intact. Currently no test.
- **`executePending` reduce path when a leg *reverts*** — no test. A reversion
  inside the `for` loop reverts the whole `executePending`, which leaves
  `_weights` unchanged but `pendingAllocationId == 0`. This is a griefing
  surface for `cancelPending` (there is nothing to cancel anymore) — no test.
- **`harvestFromAllLegs` when a leg's `harvest()` reverts** — no test. The
  keeper is stuck: any single leg down freezes the cascade for everyone.
- **Reentrancy through the legs themselves** — the guard-reset tests use
  two clean deposits. There is no `MaliciousLeg` (as sketched in
  `tests_plan.md`) that calls back into `agg.deposit` or `agg.withdraw`
  from inside `allocateTo`/`harvest`/`reduceFrom`.
- **Events** — `Deposit`, `Withdraw`, `Transfer`, `AllocationRequested`,
  `AllocationExecuted`, `AllocationCancelled`, `Harvested`, `KeeperUpdated`,
  `PausedUpdated` are all emitted but not asserted on (except indirectly via
  `pendingAllocationId`). A `expectEmit` test would pin event argument
  ordering.

### 2.2 `TradeOnlyAgent`

Covered: signature happy path, `expiresAt` boundary, field-zero guards,
wrong-signer, tampered sig, bad `v` revert, `revoke` semantics, `recordExecution`
keeper-role + per-venue isolation + first-execution-sets-cap + empty `assetIds`.

**Missing:**

- **Aggregate notional across venues (KI-6)** — the current per-venue cap is
  accepted spec, but there is no test that documents *what happens* when the
  same delegation is used on 100 venues: the sum of notional used can be
  `100 × maxNotional`. A test asserting this behaviour would make the
  accepted-limitation explicit in the test suite so a future "fix" is
  deliberately breaking.
- **`maxPerOrder` is never enforced.** `isValidDelegation` checks
  `maxPerOrder > 0` but never compares it against the venue's `notional` in
  `recordExecution`. A delegation signed with `maxPerOrder = 100, maxNotional =
  10_000` can be replayed by a venue with `notional = 10_000` and accepted.
  This is a real bug — `maxPerOrder` is silently a documentation-only field.
  No test currently exposes this.
- **Cross-venue nonce reuse** — two venues using the same `(delegator,
  keeper, nonce)` are isolated today (`usedNotional[venue][key]`), which is
  the per-venue design. There is no test asserting that the *same* nonce
  can be used on N venues; the FIX-14 test only shows two venues both
  accepting 1000 of a 1000 cap.
- **`recordExecution` after `revoke`** — no test. `revoke` sets
  `revokedKeypaths` but does not touch `usedNotional` or `delegationCap`, so a
  revoked keeper's delegation can still be used by a venue to consume
  notional. Whether that is desired is not pinned down.
- **`recordExecution` replay protection** — same `delegationId` submitted
  twice by the same venue would consume the notional twice. `delegationId`
  is only emitted, never recorded. No test.
- **`recordExecution` with `delegationCap` already set from a previous
  `recordExecution` and a *different* `maxNotional`** — because
  `delegationCap[key]` is set once on first call and never updated, if a
  delegator signs a second delegation to the same keeper with
  `maxNotional = 5_000` (up from 1_000), the venue's `recordExecution` still
  caps at 1_000. But `remainingNotional` returns `cap - used`, so the caller
  would see the old, lower cap. No test covers the "raise the cap" case.
- **Signature recovery edge cases** — high-`s` non-canonical signatures,
  `r` or `s` == `0`, `r` or `s` > field order, `v == 29`. `vm.sign` produces
  canonical signatures, so `_recover`'s `require(v == 27 || v == 28)` is
  the only guard. `require(v == 27 || v == 28)` and the low-`s` invariant
  are untested. Note: modern `ecrecover` accepts high-`s`, so a non-canonical
  signature has the same recovered address — this is worth pinning down.
- **Empty vs non-empty `assetIds`** — `test_emptyAssetIds_allowed` confirms
  the empty case. But the non-empty case (`ids = [1]`) is only tested in
  the happy path. There is no test that a delegation signed for `assetIds =
  [1]` is rejected on a venue trading asset `2`. In practice, `TradeOnlyAgent`
  does not filter — it only ever *sees* the `assetIds` at hash time. The
  enforcement, if any, has to happen at the venue. This is a spec contract
  with the venue, and no test documents it.
- **Cross-chain replay** — `_domainSeparator` includes `block.chainid`, so a
  delegation signed on testnet cannot be replayed on mainnet. There is no
  test that flips `chainId` with `vm.chainId(...)` and asserts
  `isValidDelegation` returns false.
- **`isRevoked(keeper)` view** — called once as a positive check. No test
  that it returns false for an unrelated keeper before revocation.
- **`revoke` after delegation already recorded** — no test that revocation
  does not retroactively invalidate `usedNotional`. Whether it should is a
  spec question.
- **`remainingNotional` before any `recordExecution`** — only tested in
  `test_recordExecution_firstExecutionSetsCap`. No test that it returns `0`
  for a never-seen (venue, delegation) tuple when `delegationCap[key] == 0`.

### 2.3 `RegimeDetector`

Covered: constructor, `setThresholds` gating, priority chain at
boundaries, `weightsForRegime` sums.

**Missing:**

- **Fuzz does not verify the priority chain.** The single fuzz test asserts
  `r <= HIGH_VOL`, which is trivially true for any of the four regimes.
  The actual invariants that need fuzzing are:
  - `computeRegime(apy, vol) == HIGH_VOL iff vol >= thresholds.highVolBps`
  - `computeRegime(apy, vol) == FUNDING_NEG iff (apy < 0 && vol < highVol)`
  - `computeRegime(apy, vol) == FUNDING_STRONG iff (0 < apy >= strong && vol < highVol)`
  - `computeRegime(apy, vol) == FUNDING_WEAK` in all remaining cases
- **Boundary cases around thresholds.** No test with `apySigned = 799` (just
  under strong), `apySigned = 299` (just under weak), `volBps = 8999`
  (just under highVol), or `apySigned = -1` with high vol. Only exact-at
  thresholds are tested.
- **`setThresholds` then `computeRegime` consistency** — no test that changing
  thresholds (via `setThresholds`) and re-running `computeRegime` produces
  the new regime. The two functions are coupled through `thresholds`.
- **`observe()`** — never tested. That's the entry point that reads
  `IMarketDataFeed`, computes `basisBps`, and mutates `lastSnapshot`. No
  mock of `IMarketDataFeed` exists in the test tree. Missing tests:
  feed returning normal values → `lastSnapshot` populated and
  `RegimeUpdated` emitted on first call;
  feed returning normal values twice → no `RegimeUpdated` on second call
  (same regime);
  feed returning zero spot → `basisBps == 0` (no divide-by-zero);
  feed returning negative funding → `fundingApyBps_24h == 0` and
  `computeRegime` correctly sees `apySigned < 0`.
- **`current()` view** — never tested. Trivial to assert.
- **`thresholds` invariant** — no fuzz that after any sequence of
  `setThresholds` calls, `strong >= weak` is preserved (the constructor
  seeds this, but no test asserts the invariant holds across calls).
- **High-vol override of FUNDING_NEG** — no test with `(apySigned = -100,
  volBps = 9500)`. Expected `HIGH_VOL` (high-vol check is first).
- **`weightsForRegime` on an unknown regime value** — no test with
  `regime = 4` (which the enum does not define). The `else` branch silently
  falls through to HIGH_VOL weights `[5000, 5000, 0, 0]`.

### 2.4 The four legs (`KHYPELeg`, `SpotStakingLeg`, `PerpFundingLeg`, `BasisHedgeLeg`)

Covered: KI-3 dust guard, KI-4 `setFixedApyBps` refreshes `expectedApy`,
`allocateTo` non-owner rejection, `name()` literal.

**Missing per leg:**

- **`reduceFrom` happy path** — zero tests on any leg. Every leg has a
  `reduceFrom` with a partial-return branch, but no test asserts:
  (a) the full-return path returns `amount`,
  (b) the partial-return path (unbonding period) returns 0 and the
  accounting decrements only by 0,
  (c) `reduceFrom(0)` is rejected (`bad amount` in KHYPE; other legs
  have their own zero checks).
- **`reduceFrom` when `amount > khypeBalance`** — no test. `KHYPELeg`
  has `require(amount > 0 && khypeBalance >= amount, "bad amount")`;
  other legs have their own balance fields but no explicit underflow test.
- **`harvest()` idempotency** — no test that calling `harvest()` twice
  with no yield in between does not crash, does not double-count APY,
  and (for the stake legs) does not transfer zero USDC. There is no
  test that harvest after allocateTo actually increments the returned
  USDC or the APY history.
- **`currentValue()`** — zero tests. This is the value the aggregator
  calls on every withdraw/rebalance to size the `take` amount. If
  `currentValue()` drifts from `allocatedUsd` (KI-1), the aggregator's
  share accounting is wrong. Not directly a `currentValue()` test, but
  the missing test here is: allocate 100 → oracle bumps HYPE price 10%
  → `currentValue()` reflects the new price, `allocatedUsd` is unchanged.
- **`setOracle` / `setRouter` / `setFundingSource` / `setPool`** — these
  functions **do not exist** on any of the four legs. All external
  addresses (`oracle`, `router`, `pool`, `writer`, `tradeOnlyAgent`,
  `fundingSource`) are `immutable`. Only `setFixedApyBps` and
  `bumpNonce` (Perp/Basis) and `claimPending` (KHYPE/Spot) are setters.
  The task prompt asks about `setOracle`/`setRouter`/`setFundingSource`
  owner-gating; the actual gap is the opposite — none of them exist, and
  the *only* setter (`setFixedApyBps`) is covered. The absence of setters
  means a misconfiguration at deploy time is unrecoverable, which is a
  design observation rather than a test gap.
- **`expectedApy()` when the oracle returns a value** — no test. The
  `if (address(oracle) == address(0)) return latestApyBps; try
  oracle.getApy(...) returns (uint256 a) { return a; } catch { return
  latestApyBps; }` has three paths, and only the "oracle unwired" path
  is exercised. Missing: oracle returns value, oracle reverts (catch
  branch).
- **`expectedApy()` when the funding source returns a value** —
  `PerpFundingLeg.expectedApy()` has the same three-path shape but
  with `fundingSource.fundingApyBps("HYPE")` cast from `int64` to
  `uint256`. The negative-funding case is untested: `int64(-50) ->
  uint256` produces a huge unsigned number, which would feed
  `currentApyBps` in the aggregator with a nonsense value.
- **`apyHistory` cap (`MAX_HISTORY = 16`)** — no test that after 20
  `harvest()` calls the history array stays at length 16 with the oldest
  entries shifted out.
- **`claimPending` on KHYPE/Spot** — no test. Called with 0, called with
  non-zero while `pool.creditUnbonded` returns 0, called with non-zero
  while it returns positive.
- **`bumpNonce` on Perp/Basis** — no test. `lastDelegationNonce` starts
  at some value and increments; untested both directions.
- **`_zeroSig()` (KI-2)** — a `writer.openPosition(..., _zeroSig())`
  will always revert on a real `ElysiumCoreWriter`. There is no test
  that catches this on a mock writer that rejects zero signatures.
  This is the M2 production blocker.
- **`_distribute`/`_writeOpen`/`_writeClose` unit-drift (KI-1)** —
  the stake legs track `allocatedUsd` in USDC but `khypeBalance`/
  `spotStakeBalance` in HYPE. `currentValue()` reconciles via price;
  no test perturbs the price and asserts the drift is bounded.

### 2.5 Cross-cutting gaps

- **No invariant tests** — `forge invariant` is not used anywhere.
- **No integration tests** — aggregator ↔ real (or mock) legs with a mock
  writer is only present in the aggregator tests via `MockLeg`, and
  `MockLeg` never reverts or under-returns.
- **No gas benchmarks** — no `--gas-report` output is checked in.
- **No `forge coverage` threshold** — no coverage report or a `minCoverage`
  setting in `foundry.toml`.
- **Event assertions** — only one test asserts an event indirectly
  (`pendingAllocationId`). Every other `emit` is unasserted.
- **`ReentrancyGuard` on the legs themselves** — the aggregator's guard
  reset is tested; the legs' guards are not (the comment in `Legs.t.sol`
  acknowledges this and points at the aggregator tests, which is
  reasonable but leaves the legs' `nonReentrant` untested in isolation).

---

## 3. Prioritized additions (top 10)

Ranked by (bug likelihood × blast radius). `bug likelihood` = how likely
a real implementation or a future change to the current code would
introduce a silent bug without tripping the test; `blast radius` =
how much user value is at risk if the bug ships.

| # | Contract | Function under test | Failure this would catch | Test sketch |
|---|---|---|---|---|
| 1 | `TradeOnlyAgent` | `recordExecution` | `maxPerOrder` is documented as per-order cap but is never enforced against `notional`; a single venue order can blow past it. | Sign `d` with `maxNotional = 10_000, maxPerOrder = 100`. `vm.prank(VENUE); recordExecution(VENUE, DELEGATOR, d, 5000, ...)`. Assert this either rejects or returns false. Currently it returns true and consumes 5000 of the cap. |
| 2 | `YieldAggregator` | `withdraw` share-allowance path | Lines 248–255 pull `assets` from `_owner` using `asset_.allowance`, then `_redeem` transfers `assets` back. A delegated withdrawal burns double the amount from `_owner`. | `vm.prank(BOB); agg.deposit(1000, BOB); vm.prank(BOB); usdc.approve(agg, 500); vm.prank(ALICE); agg.withdraw(500, ALICE, BOB);` — assert BOB's share balance is 1000-500 and BOB's USDC is reduced by 500 total (not 1000). |
| 3 | `YieldAggregator` | `redeem` share-allowance path | Lines 269–273 check `asset_.allowance(_owner, msg.sender) >= newShares` and then call `asset_.safeApprove(msg.sender, current - newShares)`. This is nonsense for ERC-4626 `redeem`, which should check `shareBalances[_owner] >= newShares` (which `_redeem` does, but the outer wrapper does a completely different check first). | `vm.prank(BOB); agg.deposit(1000, BOB); vm.prank(ALICE); agg.redeem(500, ALICE, BOB);` — currently reverts with "insufficient share allowance" even though BOB holds 1000 shares. Test that the intended behaviour works, or that it reverts with a message that matches the intended semantics. |
| 4 | `YieldAggregator` | `executePending` reduce path when a leg reverts | If one leg's `reduceFrom` reverts (unstake window closed with a stuck pool, or a malicious/buggy leg), the whole `executePending` reverts *after* `pendingAllocationId` has been zeroed. Keeper is stuck: nothing to cancel, new request needs to wait for a full timelock. | Deploy a `MockLeg` variant with `reduceFrom` reverting on leg[1]. Run a rebalance that requires reducing leg[1]. Assert either the keeper can recover (via a new request with new pending ID) or that a `try/catch` was added. Currently the whole call reverts and `_weights` and `pendingAllocationId` are in an inconsistent state (weights not applied, id zeroed). |
| 5 | `TradeOnlyAgent` | `recordExecution` replay | `delegationId` is only emitted, never recorded. A venue can submit the same execution twice and consume `2 × notional`. | `vm.prank(VENUE); assert agent.recordExecution(VENUE, DELEGATOR, d, 500, bytes32(0xabc), 0); assert agent.recordExecution(VENUE, DELEGATOR, d, 500, bytes32(0xabc), 0);` — currently both return true and 1000 is consumed. |
| 6 | `RegimeDetector` | `observe()` with a mock feed | `observe()` is the entry point the aggregator's keeper calls. It has never been tested. A bug in `basisBps` computation (signed-division hazard when `perp < spot`) or in the `try/catch` (which is not present here but is in the legs) is silent. | Deploy a `MockMarketDataFeed` (needs to be added to test/mocks). Test: spot=100, perp=110, fundingBps=-5, volBps=500 → expect `lastSnapshot.basisBps == 1000`, `regime == FUNDING_NEG`, `RegimeUpdated` emitted. |
| 7 | `YieldAggregator` | `_distribute` when a leg's `allocateTo` returns less than `amount` | A real leg might round down (e.g. BasisHedgeLeg splits 50/50 and each side's `notional` is `(amount-1)/2`, so a USDC-denominated return may differ from `amount`). Aggregator adds `allocated` to `distributed` and then to `_allocatedTotal`. If `allocated < amount`, some USDC stays in the leg. Not a bug per se, but untested. | Custom `MockLeg` where `allocateTo(100)` returns 90. Assert `_allocatedTotal == 90` after deposit, and `currentValue()` is consistent. |
| 8 | `YieldAggregator` | `deposit` with `leg[i].allocateTo` reverting mid-loop | `deposit` transfers all `assets` into the aggregator first, then calls `safeTransfer(legs[i], portion)`. If leg[1] reverts after leg[0] has received 25% of the deposit, the whole deposit reverts — but leg[0]'s allocation happened. Because the whole transaction reverts, this is atomic; no state leak. Untested. | Custom `MockLeg` for leg[1] that reverts on `allocateTo`. Call `deposit`. Assert `usdc.balanceOf(agg) == 0`, `usdc.balanceOf(leg[0]) == 0`, and Alice's share balance is unchanged. |
| 9 | `TradeOnlyAgent` | Cross-chain replay | `_domainSeparator` includes `block.chainid`. A signature signed on chain A must not validate on chain B. | Sign `d` with `vm.chainId(31337)`, deploy agent on `vm.chainId(1)`, assert `isValidDelegation` returns false. |
| 10 | `YieldAggregator` | `setPaused` gating on `mint`/`withdraw`/`redeem` | Only `deposit` is paused-gated. The other three ERC-4626 entry points should also reject during pause. | `setPaused(true); vm.prank(ALICE); vm.expectRevert("paused"); agg.mint(100, ALICE);` — repeat for `withdraw` and `redeem`. Note: the *current* code applies `notPaused` to `mint`, `withdraw`, and `redeem` (they all carry `notPaused nonReentrant`), so this test would just be a regression. But the current test file never asserts it. |

---

## 4. Invariant tests to add (`forge invariant`)

The invariant runner is not configured in `foundry.toml` and there are
no invariants today. The three below are the ones most likely to catch
real accounting drift.

**Setup contract** (sketch — new file, not part of this doc):

```solidity
contract AggInv is Test, isInvariantBase {
    YieldAggregator agg;
    MockUSDC usdc;
    MockLeg[4] legs;
    address[] depositors;

    function setUpInvariant() public {
        // Deploy aggregator + 4 legs + Alice/Bob/Carol
        // Fund each depositor with 1e6 USDC
    }

    function deposit(address to, uint256 amount) external { /* agg.deposit */ }
    function withdraw(address from, uint256 amount) external { /* agg.withdraw */ }
    function rebalance(uint16[4] calldata w) external { /* request + execute */ }
    function harvest() external { /* harvestFromAllLegs */ }
}
```

**Invariant 1 — Shares are never worth more than the vault holds.**

```solidity
function invariant_shareValueBounded() public view {
    uint256 totalShares = agg.totalShares();
    if (totalShares == 0) return;
    // ERC-4626: no shareholder's pro-rata share of totalAssets may exceed
    // what they would receive.
    uint256 aliceProRata = (agg.shares(ALICE) * agg.totalAssets()) / totalShares;
    assertLe(aliceProRata, agg.totalAssets());
}
```

**Invariant 2 — Weights always sum to BPS_DENOM.**

```solidity
function invariant_weightsSumTo10000() public view {
    uint16[4] memory w = agg.weights();
    assertEq(uint256(w[0]) + w[1] + w[2] + w[3], agg.BPS_DENOM());
}
```

**Invariant 3 — `_allocatedTotal + freeCash ≤ totalAssets()` and
share balances are consistent with the accounting.**

The aggregator does not expose `_allocatedTotal` publicly, so this
requires either a public getter (spec change) or a proxy-invariant
check via the observable state:

```solidity
function invariant_noDoubleCounting() public view {
    // totalAssets = totalLegValue + vault cash. The vault cash should be
    // at least 0 and at most totalAssets. If totalAssets drops after
    // a leg's currentValue collapses, some share holder will get less
    // than expected — which is expected. The real invariant is:
    uint256 legSum = agg.totalLegValue();
    uint256 cash = usdc.balanceOf(address(agg));
    uint256 reported = agg.totalAssets();
    assertEq(legSum + cash, reported);
}
```

**Invariant 4 — Deposit/withdraw round-trip is monotone.**

```solidity
function invariant_exchangeRateMonotone(address depositor) public view {
    if (agg.shares(depositor) == 0) return;
    // A depositor's share balance should never increase their pro-rata
    // claim without a corresponding increase in totalAssets.
    uint256 proRata = (agg.shares(depositor) * agg.totalAssets()) / agg.totalShares();
    // We don't know the depositor's original contribution, so we can only
    // assert non-negativity — useful against silent overflow bugs.
    assertTrue(proRata >= 0);
}
```

---

## 5. Integration tests to add

The aggregator tests today use `MockLeg` which always returns `amount`
from `allocateTo`/`reduceFrom` and never reverts. Add a `MockLegFactory`
in `test/mocks/` with three variants, then run each through the full
happy path with a `MockWriter` for the perp/basis legs (KI-2).

**Happy path (baseline).**

`deposit(1000) → requestAllocation([3000,3000,2000,2000]) → warp(+timelock)
→ executePending → assert leg allocations ≈ targets → withdraw(500) →
assert Alice received 500 USDC`. Existing tests cover most of this in
pieces but not end-to-end with a writer involved.

**Griefing scenario 1 — A leg reverts on `reduceFrom`.**

- Deploy aggregator with a `RevertOnReduceLeg` for slot 1.
- Deposit 1000, then request a rebalance that requires reducing slot 1
  (e.g. move weight from slot 1 to slot 0).
- Assert: `executePending` reverts, `pendingAllocationId == 0`
  (a griefing hazard — the keeper cannot cancel what is already gone),
  `_weights` unchanged, totalShares unchanged, no USDC leaked.
- Follow-up: `setPaused(true)` by owner; assert `deposit` reverts,
  `executePending` still reverts (not paused-gated) — documents that
  pause does not help the keeper here.

**Griefing scenario 2 — A leg under-returns on `reduceFrom`.**

- Deploy with a `PartialReturnLeg` that returns `amount / 2`.
- Deposit 1000, execute a rebalance that reduces leg 1 by 500.
- Assert: `totalAssets()` reflects the actual returned cash, not the
  requested `delta`. Specifically, `_allocatedTotal` should not drop by
  the full 500 — this is the KI-5 fix and no regression test exists.

**Griefing scenario 3 — `cancelPending` mid-execution of a keeper's
request.**

- Keeper calls `requestAllocation`, waits for the timelock, then owner
  calls `cancelPending` in the same block as the keeper's `executePending`.
- Two orderings to test: cancel first, then execute (execute should
  revert with "nothing pending"); execute first, then cancel (cancel
  should revert with "nothing pending"). Both orderings are tested
  partially by `test_cancelPending_rejectsWrongId` but not in
  a same-block timing context.

**Integration with `MockWriter`.**

- Deploy `KHYPELeg` with a real `MockWriter` and a mock `TradeOnlyAgent`.
- Verify that `allocateTo(N)` calls `writer.openPosition` with
  `notional == N`. Verify that `_zeroSig()` is what is passed — the M2
  blocker per KI-2. This test documents *that* KI-2 is real.

---

## 6. Fuzz targets

Pure or nearly-pure functions worth fuzzing (no state dependency, or
state that can be set up once):

- **`RegimeDetector.computeRegime(int64 apySigned, uint256 volBps)`**
  — fuzz the full priority chain across all four branches. Already has
  a trivial fuzz test; replace with the stronger invariant listed in
  §4.
- **`RegimeDetector.weightsForRegime(uint8 regime)`** — fuzz that the
  sum is always 10_000 for `regime ∈ [0..255]`.
- **`TradeOnlyAgent._delegationHash` vs `_delegationKey`** — fuzz that
  two different `Delegation` structs always produce different keys
  (uniqueness under `nonce`, `salt`, and `assetIds`).
- **`TradeOnlyAgent.isValidDelegation`** — fuzz across `(maxNotional,
  maxPerOrder, expiresAt, nonce, salt)`; assert false when any field
  is zero (the field-guard tests cover the single-zero cases but not
  combinations).
- **`YieldAggregator.convertToShares` / `convertToAssets`** — fuzz
  against the exchange-rate relationship: `convertToShares(convertToAssets(x))
  ≈ x` within rounding. This would catch the `mint`/`redeem` accounting
  bugs from §3 items 2–3.
- **`YieldAggregator._distribute` via a fuzzed weight vector** — fuzz
  `(w0, w1, w2, w3)` subject to `sum == 10000`; assert that
  `_allocatedTotal == totalAssets() - vault_cash` after each deposit.
- **`BasisHedgeLeg.allocateTo(uint256 amount)`** — fuzz `amount ∈ [0..1e18]`;
  assert that `allocatedUsd == amount` for `amount ≥ 2` and reverts
  for `amount < 2`. Currently only tested at `amount = 1` and `amount = 0`.
- **`TradeOnlyAgent.recordExecution(uint256 notional)`** — fuzz
  `notional ∈ [0..maxNotional]`; assert monotone `usedNotional`.
- **Non-canonical signatures in `_recover`** — fuzz `v ∈ [27..30]`,
  `r` and `s` in various ranges including 0 and `2^255`. Assert that
  `isValidDelegation` returns false for anything that does not recover
  to `from`.

---

## 7. What NOT to test

Documented here so the next author doesn't burn time on them.

- **Per-venue aggregate notional cap (KI-6).** The `usedNotional[venue][key]`
  keying is deliberate — a single delegation can be used on N venues for
  a total of `N × maxNotional`. This is documented in
  `DELEGATION_SPEC.md §9` and listed as an accepted limitation in
  `ROADMAP.md` §2.5 KI-6. Do not write a test that fails on this
  behaviour; the fix (a cross-venue aggregate cap) is a spec change,
  not a bug fix.
- **`_zeroSig()` failing on a real `ElysiumCoreWriter` (KI-2).** Every
  leg calls `writer.openPosition(..., _zeroSig())` with a placeholder
  signature that will always revert on the real writer. This is the
  M2 production blocker. A test that documents "the writer rejects
  zero signatures" would be documenting the missing feature, not the
  current behaviour. Skip until the `submitIntent` flow lands.
- **Cross-leg `setOracle` / `setRouter` / `setFundingSource`
  owner-gating.** These functions **do not exist**. All external
  addresses on the four legs are `immutable`. There is no setter to
  test and no owner-gate to verify. The only mutable state on a leg
  is `fixedApyBps` (covered by KI-4 tests), `latestApyBps` (covered
  indirectly), `history` (uncovered — trivial), `allocatedUsd`,
  `khypeBalance`/`spotStakeBalance`, and `lastDelegationNonce`
  (uncovered — trivial). If setters are ever added, that is a spec
  change to test at that time.
- **`check_repo.py` regex coverage.** `check_repo.py` covers 13
  documentation regexes and 5 solidity-ABI checks. It does not run
  tests. Do not add tests to satisfy a `check_repo.py` finding —
  if `check_repo.py` reports a doc regex hit, fix the doc.
- **Event-emission on every state change.** The current code emits
  most events but the events are not critical to correctness (no
  downstream contract consumes them yet). Asserting every event on
  every function is test bloat; only assert events for the paths that
  other contracts or off-chain consumers will actually watch (probably
  `AllocationExecuted` and `Revoked`).
- **Gas benchmarks for the leg contracts.** The legs call external
  venues; gas is dominated by venue behaviour, not our code. Only the
  aggregator gas matters for keeper workflows, and that is a
  different exercise (see `tests_plan.md` §8 for the future
  `--gas-report` plan).

---

## Appendix A — What `check_repo.py` covers vs `forge test`

`check_repo.py` is a **static** verifier. It answers: "did we fix the
specific review findings from rounds 1–4?"

| Layer | `check_repo.py` | `forge test` |
|---|---|---|
| Doc regex (D1–D11, I1–I4) | ✅ | ❌ |
| Compiles with solc 0.8.26 | ✅ | ✅ (transitively) |
| ERC-4626 surface present | ✅ (S2) | ❌ |
| `expiresAt == 0` in source | ✅ (S3, string grep) | ✅ (via `test_expiresAtZero_neverExpiresAccepts`) |
| `revoke` in ABI | ✅ (S4) | ✅ (via `test_revoke_*`) |
| README size/ABI drift | ✅ (S5) | ❌ |
| Runtime behaviour | ❌ | ✅ |
| Coverage % | ❌ | ❌ (`forge coverage` not invoked) |
| Fuzz coverage | ❌ | ✅ if `forge test --fuzz-runs=...` runs |
| Invariants | ❌ | ✅ if `forge invariant` runs |

The overlap on FIX-7 (`expiresAt == 0`) is real but shallow:
`check_repo.py` greps for a string, `forge test` runs the function.
If the string survives a refactor that changes the logic, `check_repo.py`
still passes while the behaviour breaks. The test suite is the
ground truth for behaviour; the verifier is the ground truth for
documentation.
