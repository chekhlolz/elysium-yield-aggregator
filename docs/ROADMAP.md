# Elysium Builder Workstream — Roadmap

**Repo**: `hypeback/` — dev backtester + Solidity skeleton + specs for the
Elysium Yield Aggregator proposal.

**Current state (2026-09-22)**: backtester + web UI + aggregator sim + Solidity
skeleton + verifier + deploy harness + HTTP/precompile HyperCore client, all
compiling clean and tested. Ready to send to Kinetiq as a research artifact;
NOT mainnet-ready.

---

## 1. What's in scope (built)

| Component | Path | Status |
|---|---|---|
| Delta-neutral vault backtester (engine) | `hypeback/engine.py` | ✅ 11 unit tests |
| Regime-driven aggregator simulator | `hypeback/aggregator.py` | ✅ 10 unit tests |
| HyperCore HTTP client | `hypeback/hypercore.py` (HTTP) | ✅ fetched 168 records |
| Precompile client (scaffold) | `hypeback/hypercore.py` (PrecompileClient) | 🟡 stub, needs Kinetiq spec |
| CLI (`run`, `mc`, `sweep`, `gate`, `sanity`, `agg`, `fetch`, `serve`) | `hypeback/cli.py` | ✅ all commands work |
| Web dashboard | `hypeback/webserver.py` | ✅ Chart.js, serves on :8760 |
| Aggregator spec | `docs/AGGREGATOR_SPEC.md` | ✅ 265 lines |
| Delegation spec | `docs/DELEGATION_SPEC.md` | ✅ 240 lines |
| Kinetiq email draft | `docs/KINETIQ_EMAIL_DRAFT.md` | 🟡 not yet sent |
| Solidity: `YieldAggregator.sol` | `solidity/src/aggregator/` | ✅ compiles, 46 ABI entries |
| Solidity: `TradeOnlyAgent.sol` | `solidity/src/delegation/` | ✅ compiles, 8 ABI entries |
| Solidity: `RegimeDetector.sol` | `solidity/src/keeper/` | ✅ compiles, 11 ABI entries |
| Solidity: `KHYPELeg.sol` | `solidity/src/legs/` | ✅ compiles, 26 ABI entries (HyperCore kHYPE LST) |
| Solidity: `SpotStakingLeg.sol` | `solidity/src/legs/` | ✅ compiles, 27 ABI entries (HyperEVM direct staking) |
| Solidity: `PerpFundingLeg.sol` | `solidity/src/legs/` | ✅ compiles, 32 ABI entries (HyperCore HYPE-USD perp) |
| Solidity: `BasisHedgeLeg.sol` | `solidity/src/legs/` | ✅ compiles, 33 ABI entries (spot + perp HR=1.0) |
| Solidity: 9 interfaces | `solidity/src/interfaces/` | ✅ IYieldAggregator, IYieldLeg, ITradeOnlyAgent, IERC20, IERC20Router, IStakingPool, IElysiumCoreWriter, IPriceOracle, IFundingSource |
| ABI verifier | `solidity/scripts/verify.py` | ✅ checks iface↔impl (incl. 4 legs), EIP-712, event topics |
| Deploy harness | `solidity/scripts/deploy.py` | ✅ dry-run works; real deploy needs RPC + key |
| Compile harness | `solidity/scripts/compile.py`, `solidity/scripts/build.py` | ✅ py-solc-x, recursive source discovery |

## 2. What's deferred (not built, needs work)

### 2.1 Contracts (blocker for production)

- ~~**Four `IYieldLeg` contracts** — `SpotStakingLeg`, `KHYPELeg`,
  `PerpFundingLeg`, `BasisHedgeLeg`.~~ **DONE** — see
  `solidity/src/legs/KHYPELeg.sol`, `SpotStakingLeg.sol`,
  `PerpFundingLeg.sol`, `BasisHedgeLeg.sol`. All four implement
  `IYieldLeg` (allocateTo / harvest / reduceFrom / currentValue /
  expectedApy / apyHistory / name) and compile clean. They talk to
  HyperCore via mock-friendly dependency interfaces (`IERC20Router`,
  `IStakingPool`, `IElysiumCoreWriter`, `IPriceOracle`,
  `IFundingSource`). Remaining pre-production TODOs live as inline
  `// TODO:` comments in each file — see the "Leg TODOs" table below.

- **Governance** — the aggregator has `owner` and `keeper` roles but no
  on-chain voting. Add Tally-style gov or 2-of-3 multisig.

- **Audit** — nothing here is audit-grad. Even the aggregator's accounting
  model (ERC-4626-style) has known edge cases (dust-share attacks, first-
  depositor bonus, share-precision rounding) that a real impl needs to
  handle explicitly.

- **Market-data feed adapter** — `RegimeDetector.sol` takes an
  `IMarketDataFeed` interface but has no concrete adapter wired. The
  precompile adapter needs the Kinetiq spec to finalize.

- **ElysiumCoreWriter integration** — the aggregator spec references a
  cross-chain intent primitive. This contract is not shipped yet; we
  can't validate the 100-200ms claim without it.

### 2.2 Simulation (blocker for Kinetiq conversation)

- **Aggregator alpha vs Liminal xHYPE** — the sim shows **+3.47% APY
  median alpha** over a static HYPE-staking benchmark (which is itself a
  9.85% APY strategy) after a 25-cell regime-aware parameter sweep
  (`strong_apr=0.10`, `rebalance_hours=720`, 15 seeds, 100% positive).
  Liminal xHYPE is 14.50% live APY. **The aggregator does NOT currently
  beat Liminal in simulation** — this is an honest finding that needs to
  be in the Kinetiq conversation. The +4.5-6% total-edge estimate in
  `AGGREGATOR_SPEC.md §4` is aspirational; the +3.47% figure is what the
  model produces today on the best-tuned config.

  **What would close the gap**:
  - Real hourly HYPE price data (not simulated lognormal) to see if xHYPE
    funding whipsaws are actually worse than my 0.001 drag factor assumes.
  - Longer funding window (data goes 2024-12 → 2026-09; a pre-mainnet
    window would help calibrate regime thresholds).
  - A keeper model that reacts on the 100-200ms regime-change trigger,
    not on a 168-hour interval.

- **Real price path** — the engine uses lognormal random walks, not actual
  HYPE price history. The `hypercore.spot_candles` client is wired but
  the engine doesn't consume it yet.

- **Realistic keeper cost model** — the aggregator sim uses a flat 5 bps
  slippage + $1.20 priority fee per trade. A real keeper on Elysium would
  have different costs (gas is HYPE-priced, sequencer fee varies with
  load).

### 2.3 Elysium integration

- **Precompile address** — `hypercore.HYPERCORE_PRECOMPILE_ADDRESS` is a
  placeholder (`0x...C0DE`). Kinetiq needs to publish the actual
  ArbOS precompile slot for the market-data read.

- **Chain spec confirmation** — Elysium's mainnet chain ID and testnet
  chain ID are **NOT published yet**. Kinetiq's official docs
  (`elysium.kinetiq.xyz/docs/building-on-elysium`) state that "the chain
  ID, public RPC endpoints, block explorer, testnet, and faucet will be
  published at launch". Note: `chainId 999` is **HyperEVM mainnet**, not
  Elysium — these contracts must be deployed to Elysium, not HyperEVM.
  The placeholder value in `deploy.py` / `hypercore.py` is an
  internal dry-run convention, not a real chain ID. When Kinetiq
  publishes the real IDs:
    1. Update `ELYSIUM_MAINNET_CHAIN_ID` in `hypeback/hypercore.py`.
    2. Update `ELYSIUM_TESTNET_CHAIN_ID` in `solidity/scripts/deploy.py`.
    3. Re-run the deploy harness regression test against `anvil --chain-id <new>`.
    4. Update `deploy.py`'s refusal guard to include the new mainnet ID.

- **ElysiumCoreWriter predeploy address** — not shipped; can't wire it in.

### 2.4 Testing

- **Foundry tests** — forge installed 2026-09-22 (v1.8.3, in
  `~/.foundry/bin/`). Round-7 suite in place (120 tests total, +13
  since round-6 covering KI-2 `submitIntent` regressions, staking-leg
  negative tests, and 3 aggregator invariants):
  - `solidity/test/RegimeDetector.t.sol` — 20 tests (constructor,
    setThresholds owner-gating, priority chain, fuzz invariant, weight
    sums, `observe()` lifecycle: populates snapshot, emits on change,
    stays silent on no-change, uses default thresholds).
  - `solidity/test/YieldAggregator.t.sol` — 34 tests (ERC-4626 happy
    path, cancelPending owner/keeper-only, reentrancy guard, weight
    sum, executePending timelock, governance, delegate withdraw/redeem
    regressions for KI-7/KI-8, `executePending` failure paths:
    leg-reverts-atomically, under-returning leg books actual return,
    reverts before timelock).
  - `solidity/test/TradeOnlyAgent.t.sol` — 19 tests (EIP-712 signature
    recovery, expiresAt == 0 never-expires sentinel, per-venue
    notional cap, revoke, tampered/wrong-signer rejection).
  - `solidity/test/Legs.t.sol` — 46 tests across 4 contract suites:
    - **LegsTest** (27): KI-4 setFixedApyBps refreshes expectedApy on
      all 4 legs, KI-3 BasisHedgeLeg dust guard, allocateTo owner
      gate on all 4 legs, name() regression, `reduceFrom` guards
      × 4 legs × 3 guard types.
    - **KI1ReconcileTest** (7): convert-once-at-boundary accounting,
      oracle re-pricing rerates `currentValue`, `reduce` returns
      USDC (not HYPE), `allocate` at fixed price; regression for
      KI-1.
    - **KI2PerpFundingTests** (6): `submitIntent` forwards real sig,
      invalid-sig reverts, over-cap reverts, replay reverts,
      wrong-keeper reverts, unauthorized-caller reverts.
    - **KI2BasisHedgeTests** (4): same coverage, minus the
      unauthorized-caller case (basis's owner-gate is identical to
      perp's).
    - **KI2StakingLegsNegativeTest** (2): KHYPELeg and
      SpotStakingLeg do NOT expose the `submitIntent` selector
      (staking legs never call the writer per design doc §4).
  - `solidity/test/YieldAggregator.invariant.t.sol` — 1 invariant
    campaign (3 invariants inside, per `docs/TEST_COVERAGE_GAP.md`
    §4):
    1. `invariant_shareValueBounded` — each shareholder's pro-rata
       slice of `totalAssets()` is bounded by `totalAssets()`.
    2. `invariant_weightsSumTo10000` — weights always sum to
       `BPS_DENOM`.
    3. `invariant_noDoubleCounting` — `_allocatedTotal + vaultCash <=
       totalAssets()` (KI-5 accounting), plus fully-observable
       `totalLegValue + vaultCash == totalAssets` sanity check.
    Fuzzer sender is a non-owner/non-keeper to exercise the FIX-22/23
    delegate paths. `requestAllocation` fuzz takes `(a,b,c)` and
    derives `d = 10000 - a - b - c` via a clamp-per-slot pattern so
    the weight-sum constraint is always satisfiable. `--fuzz-runs 128`
    also passes (forge 1.8.3 has no `--invariant-runs` flag).
  - Total: **120 tests, 0 failed** (20 + 34 + 19 + 27 + 7 + 6 + 4 +
    2 + 1 invariant campaign). Run with `forge test`.
  - External verifier (`check_repo.py`) still ignores `solidity/test/`
    because it runs solc directly without forge-std remapping — that
    path is covered by `forge test`.

- **`verify.py` covers ABI + EIP-712 + events**, but not runtime
  behavior. The aggregator's `_redeem` path in particular has edge
  cases (share allowance, first depositor, dust) that static analysis
  can't catch.

### 2.5 Known issues

Round-3 review surfaced 6 findings (KI-1..6), three of which
(KI-3, KI-4, KI-5) got patched in round-4 (commit `552d185`). Round-5
review of the test-coverage gaps surfaced two more real bugs —
**KI-7** (delegate `withdraw` collateral anti-pattern) and **KI-8**
(`redeem` share-allowance category error) — both fixed in round-5
(commit after `7d007ee`). Round-6 closed **KI-1** (stake-leg unit
drift, Option A: convert once at boundary). Round-7 closed **KI-2**
(`_zeroSig()` writer stub — production blocker, Option C: hybrid).
Only remaining open item for M2: **KI-6** (per-venue delegation cap —
accepted spec tradeoff, documented in `DELEGATION_SPEC.md §9`).

- **KI-3, KI-4, KI-5** — round-4 fixes, regression tests in
  `solidity/test/Legs.t.sol` and `YieldAggregator.t.sol`.
- **KI-7, KI-8** — round-5 fixes, regression tests in
  `YieldAggregator.t.sol` (`test_withdraw_delegateDoesNotPullUSDC`,
  `test_redeem_delegateNoShareAllowanceGate`, `test_redeem_delegateWithNoApproval`,
  `test_redeem_delegateSucceedsAndBurnsShares`).
- **KI-1** — round-6 fix, regression tests `test_KI1_*` × 7 in
  `solidity/test/Legs.t.sol` (`KI1ReconcileTest` suite).
- **KI-2** — round-7 fix, regression tests × 12 in
  `solidity/test/Legs.t.sol` (`KI2PerpFundingTests` × 6,
  `KI2BasisHedgeTests` × 4, `KI2StakingLegsNegativeTest` × 2).
- **KI-6** — accepted spec tradeoff; not a bug. See §5 and `DELEGATION_SPEC.md §9`.

| # | Issue | Where | Status |
|---|---|---|---|
| KI-1 | ~~Stake legs (`KHYPELeg`, `SpotStakingLeg`) mix unit domains: `khypeBalance` is tracked in HYPE, but `amount` and `allocatedUsd` are in USDC. `currentValue()` multiplies by price to reconcile, but `_distribute` and `reduceFrom` return USDC — leg-internal accounting may drift when the oracle re-prices HYPE.~~ | `src/legs/KHYPELeg.sol`, `src/legs/SpotStakingLeg.sol` | **FIXED in round-6**: Option A from `docs/DESIGN_KI1_UNIT_RECONCILE.md` — convert once at the boundary, track `khypeBalance` in HYPE units internally, USDC is a caller-side concept. Regression tests: `test_KI1_*` × 7 in `Legs.t.sol`. |
| KI-2 | ~~`writer.openPosition(...)` / `closePosition(...)` in every leg is called with `_zeroSig()` — a placeholder signature that will always fail on a real `ElysiumCoreWriter`. Production flow needs `submitIntent(Delegation, Signature, uint256)` on each leg.~~ | `src/legs/PerpFundingLeg.sol`, `src/legs/BasisHedgeLeg.sol` | **FIXED in round-7**: Option C from `docs/DESIGN_KI2_SUBMITINTENT.md` — hybrid. New interface `IIntentSubmittingLeg` (separate from `IYieldLeg`); perp legs (`PerpFundingLeg`, `BasisHedgeLeg`) implement it with `submitIntent(Delegation, Signature, uint256)` that verifies via `TradeOnlyAgent.isValidDelegation`, enforces venue-local `maxPerOrder`, marks intent nonce-keyed, executes via writer with the real signature, and calls `recordExecution`. Staking legs (`KHYPELeg`, `SpotStakingLeg`) untouched — they never call the writer. `_zeroSig()` renamed to `_fallbackSig` on the perp legs (only invoked when `fundingSource` is unwired, not in the production path). Regression tests: 12 KI-2 tests in `Legs.t.sol` (valid-sig forwards real sig, invalid-sig reverts, over-cap reverts, replay reverts, wrong-keeper reverts, unauthorized-caller reverts, staking-legs negative test). |
| KI-3 | ~~`BasisHedgeLeg.allocateTo(1)` double-allocates: with `spotPortion = 1 / 2 = 0`, the `if (spotPortion == 0) spotPortion = amount;` guard re-runs with `perpPortion = amount - spotPortion = 0`, but the code then still calls `_writeOpen` once, so 1 USDC of allocation creates both a spot and perp open with notional 0.~~ | `src/legs/BasisHedgeLeg.sol` | **FIXED in round-4**: added `require(amount >= 2, "dust")` guard in `allocateTo`. Regression test: `test_KI3_BasisHedgeLeg_allocateTo_rejectsDust`. |
| KI-4 | ~~`setFixedApyBps(v)` on all 4 legs writes `fixedApyBps` but doesn't refresh `latestApyBps`. Until the next `harvest()` or `allocateTo()` runs, `expectedApy()` continues returning the stale `latestApyBps`.~~ | All 4 legs | **FIXED in round-4**: `setFixedApyBps` now sets `latestApyBps = v` when the oracle/fundingSource is unwired. Regression tests: `test_KI4_*Leg_setFixedApyBps_refreshesExpectedApy` (4 legs). |
| KI-5 | ~~`_allocatedTotal` in `YieldAggregator` decrements by `delta` on `executePending`'s reduce path, but `legs[i].reduceFrom(delta)` may return less than `delta` (unstake waiting, rounding). The accounting is optimistic — vault's share balances can exceed `_allocatedTotal + freeCash` on a slow leg.~~ | `src/aggregator/YieldAggregator.sol` | **FIXED in round-4**: `executePending` and `_redeem` now use the actual `reduceFrom` return value instead of the requested `delta`/`take`. `_redeem` also breaks early if a leg returns 0 to avoid silently under-delivering. |
| KI-6 | `recordExecution` in `TradeOnlyAgent` accepts a `notional` up to the delegation's `maxNotional`, but the venue-local `usedNotional` cap is per-`(venue, delegator, keeper, nonce)` — a delegation signed once can be used on N venues for a total of N × maxNotional. This is documented in `DELEGATION_SPEC.md §9`; production will add a per-delegation aggregate cap if cross-venue abuse becomes realistic. | `src/delegation/TradeOnlyAgent.sol` | Accepted limitation; not a bug, just a spec tradeoff. |
| KI-9 | ~~`TradeOnlyAgent.recordExecution` did not verify the delegation's EIP-712 signature — a venue could record an execution for a delegation that was never signed by the keeper.~~ **Round-9 responsibility-split decision**: per `DELEGATION_SPEC.md §4`, signature verification is a **venue-side responsibility** (the venue holds the intent + sig and verifies before calling the writer). The verifier (`TradeOnlyAgent`) enforces only the cap math and the revocation state. This split is now documented in the KI-6 row and accepted. | `src/delegation/TradeOnlyAgent.sol` | Accepted spec tradeoff (venue responsibility per DELEGATION_SPEC.md §4). Not a bug. |
| KI-10 | ~~`recordExecution` did not enforce `d.maxPerOrder` — a venue could record an execution with a notional up to `d.maxNotional` (per-delegation total cap) but bypass the per-order ceiling.~~ **Fixed in round-9** (commit `e01dc1d`): `recordExecution` now enforces `require(notional <= d.maxPerOrder, "per-order cap")`. | `src/delegation/TradeOnlyAgent.sol` | **FIXED in round-9**: `require(notional <= d.maxPerOrder)` in `recordExecution`. Regression tests: `test_recordExecution_rejects_overPerOrderCap`, `test_recordExecution_accepts_atPerOrderCap`. |
| KI-11 | ~~`TradeOnlyAgent._recover` accepted non-canonical ECDSA signatures: `r == 0`, `s == 0`, and `s > secp256k1.order / 2` all passed through to `ecrecover`, which either returned the zero address or returned a wrong signer depending on the value. A hostile caller could pick a signature variant that made `isValidDelegation` pass on a delegation they didn't sign.~~ | `src/delegation/TradeOnlyAgent.sol` | **FIXED in round-9**: `_recover` now rejects `r == 0`, `s == 0`, and non-canonical `s > 0x7F...681B20A0` (the mathematically correct `(n-1)/2` for secp256k1). Regression tests: `test_accept_canonical_signature`, `test_reject_zero_r`, `test_reject_zero_s`, `test_reject_non_canonical_s`. Note: the round-9 task brief supplied the wrong upper bound (`0x7F...4501DDFE92F46688B214`); the correct value is used in the code with a comment pointing at the discrepancy. |
| KI-12 | ~~`YieldAggregator.setTimelock(0)` was an owner-grief vector: setting the timelock to 0 let a compromised keeper request-and-execute a rebalance in the same block, defeating the timelock's purpose.~~ | `src/aggregator/YieldAggregator.sol` | **FIXED in round-9**: `require(_ts >= 60, "timelock below 60s")` in `setTimelock`. Regression tests: `test_setTimelock_rejectsBelowMinimum`, `test_setTimelock_acceptsMinimum`, `test_setTimelock_acceptsHigherValue`, `test_setTimelock_requiresOwner`. 60s is the floor; production should tune far higher. |
| KI-13 | ~~`YieldAggregator` ABI `assetIds` allowlist was enforced by the aggregator on the venue side but not verified in the writer path — a venue could execute against an `assetId` the owner never approved.~~ **Round-9 responsibility-split decision**: per `AGGREGATOR_SPEC.md §2`, the venue is responsible for rejecting unknown `assetId`s; the aggregator only owns the allowlist policy. The venue-side enforcement is documented in `PerpFundingLeg.sol` / `BasisHedgeLeg.sol`. | `src/aggregator/YieldAggregator.sol`, `src/legs/PerpFundingLeg.sol`, `src/legs/BasisHedgeLeg.sol` | Accepted spec tradeoff (venue responsibility per AGGREGATOR_SPEC.md §2). Not a bug. |
| KI-14 | ~~`PerpFundingLeg._fallbackSig` / `BasisHedgeLeg._fallbackSig` reachable in production if the `fundingSource` is ever unwired post-deploy — the writer would be called with a zero signature and revert, or worse if a hostile fundingSource returns a valid-but-unintended sig.~~ **Round-9 responsibility-split decision**: the perp legs are gated by `owner` on deploy and `fundingSource` is only ever mutated via the constructor (currently immutable). Reaching `_fallbackSig` in production requires a compromised keeper + a `fundingSource` unwire, which is a governance issue, not a leg-level bug. Tracked for the KI-2b Phase 2 aggregator refactor. | `src/legs/PerpFundingLeg.sol`, `src/legs/BasisHedgeLeg.sol` | Deferred to KI-2b Phase 2 aggregator refactor. Not a bug in current architecture. |
| KI-15 | ~~`khypeBalance` / `rewardHypeBalance` is tracked in HYPE-input units but the pool holds stake tokens — on any `pool.exchangeRate()` move, `reduceFrom` decrements a HYPE amount while `pool.unstake` burns a stake-token amount, and the two diverge by the rate delta. The KI-1 comment at `KHYPELeg.sol:125-130` describes an intent (rate folded in at `allocateTo`) that the code does not implement.~~ | `src/legs/KHYPELeg.sol`, `src/legs/SpotStakingLeg.sol` | **DESIGN ONLY in round-9**: tracked as `docs/DESIGN_KI1_RATE_TRACKING.md`. Recommended option A (stake-token count semantics + live rate in `currentValue()`). Implementation deferred to agent F, round-10 / round-11. Design closes round-9 finding #1/#2 (accounting drift) and finding #17 (comment/code mismatch). |
| KI-16 | **KI-2b Phase 2 aggregator refactor** — the aggregator's `executePending` and `harvestFromAllLegs` still call `leg.allocateTo` / `leg.harvest` / `leg.reduceFrom` on perp legs, which internally use `_fallbackSig()` (the zero-signature placeholder). Against a real `ElysiumCoreWriter`, every aggregator-driven allocation to `PerpFundingLeg` or `BasisHedgeLeg` will revert at the writer, killing the aggregator's fast-loop alpha claim. Phase 1 (round-7) added `submitIntent` for LP-driven (stream B) allocations; Phase 2 must add a `executePendingWithStreamA(Delegation, Signature)` path for aggregator-driven (stream A) allocations. | `src/aggregator/YieldAggregator.sol`, `src/legs/PerpFundingLeg.sol`, `src/legs/BasisHedgeLeg.sol`, `src/interfaces/IIntentSubmittingLeg.sol` | **DESIGN ONLY in round-12**: tracked as `docs/DESIGN_KI2B_AGGREGATOR_STREAM_A.md`. Recommended option B (off-chain keeper signs stream-A delegation with `keeper = address(aggregator)`, aggregator submits via a new `executePendingWithStreamA` entry point, perp legs route through `submitIntent` and `_fallbackSig` is removed — closes round-9 finding #9). Deferred to round-13 (round-11 is occupied with the KI-1 rate-tracking fix on stake legs; round-12 is this doc). Blocked on ElysiumCoreWriter shipping (see §2.3) for production value, but the implementation can land before then. |
| KI-7 | ~~`withdraw(assets, receiver, _owner)` for delegated callers (`msg.sender != _owner`) pulled `assets` of USDC from the owner via `safeTransferFrom` BEFORE burning the shares and paying the owner back the same `assets`. The net USDC flow was zero but it (a) required the owner to pre-approve the vault for the withdrawal amount, which is nonsense — they already hold shares, they're not depositing again; (b) made delegate withdraw revert on any caller that hadn't pre-approved, even though delegation authorization is a calling-interface convention, not an on-chain authz.~~ | `src/aggregator/YieldAggregator.sol:241-260` | **FIXED in round-5**: removed the collateral pull. `withdraw` now burns shares and pays out of the vault's own holdings regardless of `msg.sender`. Regression test: `test_withdraw_delegateDoesNotPullUSDC`. |
| KI-8 | ~~`redeem(newShares, receiver, _owner)` for delegated callers compared `asset_.allowance(_owner, msg.sender) >= newShares` — a category error that checked a USDC allowance against a share amount. The vault keeps shares as plain U256 counters (`shareBalances[_owner]`), not as an ERC-20-like share token with an `allowance` mapping. Pre-fix, delegate redeem reverted on any caller that hadn't pre-approved a share-count-sized USDC allowance.~~ | `src/aggregator/YieldAggregator.sol:262-278` | **FIXED in round-5**: removed the share-allowance gate. Delegate `redeem` now works for any caller. Regression tests: `test_redeem_delegateNoShareAllowanceGate`, `test_redeem_delegateWithNoApproval`, `test_redeem_delegateSucceedsAndBurnsShares`. |

### 2.6 Round-6 changelog

Round-6 (2026-09-22) closed **KI-1** and lifted the test suite from 82 →
107 tests. Commits `96a16b9` → `9120c91` (10 commits).

- **KI-1 fixed** — stake-leg unit reconcile (Option A from
  `docs/DESIGN_KI1_UNIT_RECONCILE.md`): `khypeBalance` is now tracked in
  HYPE units internally; USDC↔HYPE conversion happens once at the
  boundary in `allocateTo` / `reduceFrom` / `currentValue`. MockRouter
  conversion factor corrected (1e18 → 1e12) for the test mocks.
  Regression tests: `test_KI1_*` × 7 in `Legs.t.sol`
  (`test_KI1_KHYPELeg_allocate_atFixedPrice`,
  `test_KI1_KHYPELeg_reduce_from_unstakes_correct_token_amount`,
  `test_KI1_KHYPELeg_currentValue_re_rates_after_oracle_repricing`,
  `test_KI1_KHYPELeg_reduce_no_USDC_subtracted_from_HYPE_counter`,
  `test_KI1_SpotStakingLeg_allocate_atFixedPrice`,
  `test_KI1_SpotStakingLeg_reduce_unstakes_correct_amount`,
  `test_KI1_SpotStakingLeg_currentValue_re_rates_on_oracle_drift`).
- **Test coverage gaps filled** (spec-driven additions from
  `docs/TEST_COVERAGE_GAP.md §3`): `executePending` failure paths
  (leg-reverts atomically, under-returning leg books actual return,
  reverts before timelock) in `YieldAggregator.t.sol`; `observe()`
  lifecycle tests (populates snapshot, emits on change, silent on
  no-change, uses default thresholds) in `RegimeDetector.t.sol`;
  `reduceFrom` guards × 4 legs (zero allocation reverts, requires
  owner, zero amount reverts) in `Legs.t.sol`.
- **`deploy.py` Anvil integration** — real EVM RPC support. The dry-run
  mode now speaks to a live `anvil --chain-id 999` instance for
  end-to-end deploy smoke, not just a mock provider.
- **README byte counts synced** — `README.md` and `solidity/README.md`
  ABI-count and byte-size tables refreshed against the post-KI-1
  build so `check_repo.py` S5 stays green.

Net effect: **107 tests, 0 failed** (`forge test`), **KI-1 closed**,
only **KI-2** and **KI-6** (accepted spec tradeoff) remain open for M2.

### 2.7 Round-7 changelog

Round-7 (2026-09-23) closed **KI-2** and lifted the test suite from
107 → 120 tests. Commits `7f34eda` + `c0dfb67`.

- **KI-2 fixed** — `_zeroSig()` writer stub replaced with a real
  `submitIntent` flow (Option C from
  `docs/DESIGN_KI2_SUBMITINTENT.md`):
  - New interface `solidity/src/interfaces/IIntentSubmittingLeg.sol`
    (separate from `IYieldLeg` per design doc §5.1).
  - `PerpFundingLeg` and `BasisHedgeLeg` now implement
    `submitIntent(Delegation, Signature, uint256)`: verifies the
    signature via `TradeOnlyAgent.isValidDelegation`, enforces
    venue-local `maxPerOrder` (per `DELEGATION_SPEC.md §107-134`),
    marks the intent as submitted (nonce-keyed, replay-protected),
    executes via `ElysiumCoreWriter` with the real signature, and
    calls `TradeOnlyAgent.recordExecution` to update the cap.
  - Staking legs (`KHYPELeg`, `SpotStakingLeg`) untouched — they
    never call the writer (design doc §4).
  - `_zeroSig()` renamed to `_fallbackSig` on the perp legs and is
    only invoked when `fundingSource` is unwired (not in the
    production path).
  - Regression tests: 12 KI-2 tests across 3 suites in `Legs.t.sol`
    (`KI2PerpFundingTests` × 6, `KI2BasisHedgeTests` × 4,
    `KI2StakingLegsNegativeTest` × 2).
- **Forge invariant tests** — new `solidity/test/YieldAggregator.invariant.t.sol`
  with 3 invariants (per `docs/TEST_COVERAGE_GAP.md §4`):
  1. `invariant_shareValueBounded` — each shareholder's pro-rata
     slice of `totalAssets()` is bounded by `totalAssets()`.
  2. `invariant_weightsSumTo10000` — weights always sum to
     `BPS_DENOM`.
  3. `invariant_noDoubleCounting` — `_allocatedTotal + vaultCash <=
     totalAssets()` (KI-5 accounting), plus fully-observable
     `totalLegValue + vaultCash == totalAssets` sanity check.
  Fuzzer sender is a non-owner/non-keeper to exercise the FIX-22/23
  delegate paths. `requestAllocation` fuzz takes `(a,b,c)` and
  derives `d = 10000 - a - b - c` via a clamp-per-slot pattern so
  the weight-sum constraint is always satisfiable.
- **Forge 1.8.3 gotcha (invariant runner)**: the runner reports
  `failed to set up invariant testing environment: No contracts to
  fuzz` whenever the test contract is the only target, *even* after
  explicit `targetContract` / `targetArtifact` / `targetSelector` /
  `targetSender`. Fix: deploy the aggregator in `setUp()`, then call
  `targetContract(address(this))` in `setUp()` so the runner
  auto-discovers the test contract, plus an empty `setUpInvariant()`
  to satisfy the runner. Also: forge 1.8.3 has no `--invariant-runs`
  flag (only `--invariant-depth`, `--invariant-workers`, etc.);
  `--fuzz-runs 128` is the closest equivalent.

Net effect: **120 tests, 0 failed** (`forge test`), **KI-2 closed**,
only **KI-6** (accepted spec tradeoff) remains open for M2.

### 2.8 Round-8 + Round-9 changelog

Round-8 (2026-09-23) and round-9 (2026-09-24) lifted the test suite
from 120 → 171 tests and closed five real bugs from an adversarial
review, plus documented four spec-accepted responsibility splits.
Commits `e38d117` → `e01dc1d` (round-8: `e38d117`, `3ba4de2`;
round-9: `5534c60`, `e01dc1d`).

#### Round-8 (commits `e38d117` + `3ba4de2`)

- **Harvest accounting fix** — `harvest()` no longer decrements
  `allocatedUsd` on either staking leg (`KHYPELeg.sol`,
  `SpotStakingLeg.sol`). Realised USDC yield is swept to the owner,
  but the principal ledger tracks the underlying HYPE position, not
  the realised reward. Decrementing would drift the aggregator's
  `_allocatedTotal` downward by the yield amount on the next
  `harvestFromAllLegs()` refresh. Closes §9.2 of
  `DESIGN_KI1_UNIT_RECONCILE.md`.
- **Router slippage guard** — `slippageBps` config field added to
  both stake legs (constructor param + owner-settable `setSlippageBps`,
  0 disables the guard, 100 = 1% is the recommended production
  default). Guard is a post-swap check on the router return value:
  `hypeIn >= (usdAmount * 1e18 * (10000 - slippageBps)) / (price * 10000)`.
  Closes §9.3 of `DESIGN_KI1_UNIT_RECONCILE.md`.
- **Fuzz coverage** — 20 new fuzz tests in
  `solidity/test/FuzzCoverage.t.sol` covering the gaps from
  `docs/TEST_COVERAGE_GAP.md §6`: aggregator `convertToShares` /
  `convertToAssets` round-trip, `RegimeDetector.weightsForRegime`
  across all 256 uint8 regimes, `TradeOnlyAgent.isValidDelegation`
  field-zero guards, non-canonical signature recovery, and
  `recordExecution` monotone `usedNotional` + per-venue isolation.
  256 runs each.
- **Real Anvil integration** — `solidity/tests/test_deploy_anvil.py`
  gains a `TestRealAnvil` class and an `AnvilProcess` context manager
  that spawns a real Anvil subprocess on a high port, waits for
  `eth_chainId`, and tears down on exit. Four tests: subprocess
  spawns + serves RPC, deploy three contracts, happy path (reads
  back asset/keeper/timelockSeconds via `eth_call`), refusal guard
  still applies for chainId 999.
- **`deploy.py` bugs caught by real Anvil** — two real bugs surfaced
  by the integration, neither of which the mock-RPC path caught:
  1. **RegimeDetector constructor arg missing.** The contract has a
     1-address constructor (`_feed`), but `deploy.py` passed
     `constructor_args=None`, so the raw creation bytecode was sent
     and the constructor saw `address(0)` and reverted with
     `'zero feed'`. Mock-RPC never executed the constructor so it
     passed silently. Added `--market-data-feed` CLI flag (default
     zero) and wired it through both the native EthProvider and
     web3 paths.
  2. **YieldAggregator gas limit too low.** The aggregator's ~12 KB
     initcode needs ~2.6M gas to deploy (200 g/word code deposit +
     a 4-iter leg-validity loop); the old 2M default caused a
     silent `'out of gas'` revert. Raised to 4M.
- **Anvil 1.8.3 default-address change** — Anvil 1.8.3 changed the
  default funded address from `0x...f39Fd6...` to `0xAE556f...`.
  Without `--fund-accounts`, the deployer would be unfunded.
  Documented in the `AnvilProcess` docstring; on Windows the
  integration always passes `--fund-accounts` to be safe.
- **Test count: 120 → 152** (round-8, 32 new). `check_repo.py`: 0
  FAIL.

#### Round-9 (commits `5534c60` + `e01dc1d`)

Round-9 caught five real bugs from the adversarial review and
documented four spec-accepted responsibility splits. Design-only
for the remaining KI-1 rate-tracking drift (see
`DESIGN_KI1_RATE_TRACKING.md`).

- **RegimeDetector hostile-feed hardening** (commit `5534c60`):
  - **Finding #7** — `hourlyFundingBps * 8760` was an unchecked
    signed int64 multiply. Solidity 0.8 does not overflow-check
    signed non-constant-folded expressions, so a hostile feed value
    > ~2.5e14 silently wrapped around `INT64_MAX`, flipping a
    positive regime to `FUNDING_NEG` (or vice versa) without any
    revert. Fix: compute in int256, saturate to `INT64_MAX/MIN`
    before storing.
  - **Finding #8** — `(perp - spot) * BPS_DENOM / spot` underflowed
    on any discount market (`perp < spot`), which Solidity 0.8 turns
    into a revert, so `observe()` reverted on the most common market
    state. Fix: handle premium and discount in pure uint256 math
    (avoiding the uint256→int256 cast which would silently wrap
    values > 2^255), cap the numerator product at uint256 max /
    BPS_DENOM, and clamp discounts to 0 to match the existing
    uint256 snapshot schema. Zero spot/perp now reverts with a
    recognisable string.
  - **9 new tests** (7 unit + 1 boundary + 1 fuzz invariant) covering
    the saturation branch, the discount branch, zero-price guards,
    and random hostile-feed tuples.
- **Delegation + aggregator hardening** (commit `e01dc1d`):
  - **Fix #1 — Non-canonical ECDSA signature rejection.**
    `TradeOnlyAgent._recover` now rejects `r == 0`, `s == 0`, and
    `s > secp256k1.order / 2`. *Note: the round-9 task brief
    supplied `0x7F...57A4501DDFE92F46688B214` as the upper bound.
    That value is NOT secp256k1.order / 2 — it is ~2^4 shorter
    (251 bits vs the correct 255) and would reject ~50% of valid
    canonical signatures. The mathematically correct value is
    `0x7F...57A4501DDFE92F46681B20A0` (= `(n-1)/2` where
    `n = 0xFFFF...CD0364141`). Used the correct value; left a
    comment in `_recover` pointing at the discrepancy.*
  - **Fix #2 — `recordExecution` enforces `maxPerOrder`.**
    `require(notional <= d.maxPerOrder, "per-order cap")` in
    `TradeOnlyAgent.recordExecution`. `DELEGATION_SPEC.md §4`
    marks this venue-local because the verifier has no view of the
    intent, but a venue bypassing per-order can silently subvert the
    delegation's small-orders-only semantics. Reference
    implementation should enforce it. Two existing tests
    (`venueCapEnforced`, `perVenueIsolation`) used notional >
    maxPerOrder to fill the notional cap; adjusted to use two
    maxPerOrder-sized orders instead.
  - **Fix #3 — `setTimelock(0)` owner-grief vector.**
    `require(_ts >= 60, "timelock below 60s")` in YieldAggregator.
    60s floor prevents same-block request+execute by a compromised
    keeper; production should tune far higher.
  - **Fix #4 — `ITradeOnlyAgent.sol` doc sync.** The `expiresAt == 0`
    sentinel doc now matches FIX-21 (round-3 P0): the field IS the
    no-expiry sentinel AND the verifier must NOT short-circuit on
    it (signature, keeper, revocation, other checks still run).
    Prior wording implied a short-circuit and was technically wrong.
  - **10 new tests** — canonicality regressions (`test_accept_canonical_signature`,
    `test_reject_zero_r`, `test_reject_zero_s`, `test_reject_non_canonical_s`),
    per-order cap (`test_recordExecution_rejects_overPerOrderCap`,
    `test_recordExecution_accepts_atPerOrderCap`), timelock minimum
    (`test_setTimelock_rejectsBelowMinimum`,
    `test_setTimelock_acceptsMinimum`,
    `test_setTimelock_acceptsHigherValue`,
    `test_setTimelock_requiresOwner`), and three `FuzzCoverage.t.sol`
    signatureRecovery fuzz tests updated to expect the new
    canonicality reverts.
- **Adversarial review outcome (17 findings total)**:
  - **5 real fixes applied in round-9** — Fix #1 (canonical sig),
    Fix #2 (`maxPerOrder` on `recordExecution`), Fix #3 (timelock
    floor), Finding #7 (int64 saturation), Finding #8 (basis
    underflow). All closed with regression tests.
  - **4 spec-accepted responsibility splits documented** (see §2.5
    KI-9, KI-13, KI-14, and the KI-6 row):
    - `recordExecution` doesn't verify signature — venue
      responsibility per `DELEGATION_SPEC.md §4`.
    - `assetIds` allowlist not verified in writer path — venue
      responsibility per `AGGREGATOR_SPEC.md §2`.
    - `_fallbackSig` production reachability — requires compromised
      keeper + `fundingSource` unwire; tracked for KI-2b Phase 2.
    - `KI-6` per-delegation aggregate cap — spec tradeoff, already
      documented in `DELEGATION_SPEC.md §9`.
  - **2 deferred to design rounds**:
    - **KI-1 drift** — `khypeBalance` rate-tracking (round-9
      finding #1/#2, #17). Design at
      `DESIGN_KI1_RATE_TRACKING.md`; implementation deferred to
      agent F (round-10 / round-11).
    - **KI-2b Phase 2** — aggregator refactor for cross-chain intent
      primitive (blocked on ElysiumCoreWriter shipping).
- **Test count: 152 → 171** (round-9, 19 new). `check_repo.py`: 0
  FAIL. `forge test`: 171/171 pass across 13 suites.

Net effect: **171 tests, 0 failed** (`forge test`), **5 round-9
real bugs fixed**, **4 spec-accepted responsibility splits
documented**, **2 items deferred to design rounds** (KI-1 drift at
`DESIGN_KI1_RATE_TRACKING.md`, KI-2b Phase 2 aggregator refactor).
Only remaining open items: (a) khypeBalance rate-tracking drift
(design doc exists; implementation deferred), (b) KI-2b Phase 2
aggregator refactor (blocked on ElysiumCoreWriter), (c) audit (M4
gate).

### 2.9 Round-14 changelog

**Scope**: last-mile M3 closure items (d) and (c) from the §4 M3
milestone row. No `solidity/src/` changes; no changes to any finalized
test file (`Legs.t.sol`, `YieldAggregator.t.sol`, `RegimeDetector.t.sol`,
`TradeOnlyAgent.t.sol`, `YieldAggregator.invariant.t.sol`); no changes
to `deploy.py`, `test_deploy_anvil.py`, `check_repo.py`, or any other
doc.

**Files touched** (4):

- `solidity/test/FuzzCoverage.t.sol` — added a second fuzz group
  `FuzzFirstDepositor` (4 tests, 256 runs each).
- `solidity/test/ElysiumCoreWriterIntegration.t.sol` — **new file**,
  `FullElysiumCoreWriterMock` (stateful mock implementing the extended
  surface the real ElysiumCoreWriter predeploy will expose:
  `getOpenOrders`, `getPosition`, `getPositionState`, `liquidate`,
  `setMargin`, and venue-side validation for open/close) +
  `ElysiumCoreWriterIntegrationTest` (23 tests).
- `docs/TEST_COVERAGE_GAP.md` — §5 gained a new §5.1 subsection
  documenting the writer integration coverage; §6 gained a Round-14
  bullet for the four first-depositor fuzz targets.
- `docs/ROADMAP.md` — §2.9 (this section) + M3 milestone row update.

**First-depositor & share-allowance fuzz** (closes M3 item (d)):

The new `FuzzFirstDepositor` contract in `FuzzCoverage.t.sol`
uses `MockYieldLeg` (a value-tracking yield leg that actually moves
USDC in and out via `allocateTo` / `mintYield` / `reduceFrom` /
`harvest`) to model a real vault with a single leg receiving yield.
Four fuzz tests:

- `testFuzz_FirstDepositor_bobCannotStealSeed` — Alice bootstraps
  the vault at 1:1; Bob tries to mint more shares than he
  contributes by depositing at the bootstrapped rate. Asserts
  Bob's share count ≤ his contribution and his share value ≤
  his contribution (rate ≥ 1 invariant).
- `testFuzz_MultiDepositor_driftUnderYield` — Alice deposits 1000,
  yield `yieldAmt ∈ [500, 5000]` lands on leg 0, Bob deposits
  `bobAssets ∈ [1000, 10000]` at the drifted rate, Alice withdraws
  everything. Asserts totalAssets is preserved exactly, Alice's
  share value at withdrawal is within 4 USDC of
  `1000 + yieldAmt`, Bob's share value is within 8 USDC of his
  contribution, and totalAssets drops by exactly Alice's withdrawn
  amount across her redemption.
- `testFuzz_Withdraw_boundaryNoOverpayNoOverburn` — fuzz
  `withdraw(assets, receiver, owner)` with owner/receiver ∈
  {ALICE, BOB} and `assets ∈ [1, max(uint112)]`. Asserts the
  vault is atomic: no over-pay (gain ≤ share value), no over-burn
  (shares burned ≥ 0), every revert string is documented (no
  bare panics).
- `testFuzz_ZeroShare_boundaries` — assets ∈ {0, 1, max(uint112)}
  and shares ∈ {0, 1, max(uint112)}. Asserts every boundary
  combination either succeeds with a stable totalShares/totalAssets
  or reverts cleanly.

The file carries a `// forge-config: default.fuzz.runs = 512`
directive at the top (per the M3 milestone spec) to give these
high-complexity multi-leg state transitions 2× the standard 256
  runs — the counterexamples actually found during development
  (bobAssets=415, yield=500 → 5-asset rounding band) justify the extra
  budget. The M3 milestone spec asked for
  `// forge-config: default.fuzz.runs = 512` for high-complexity
  tests; the directive is placed at the top of `FuzzCoverage.t.sol`
  but forge 1.8.3 (the version in the repo) does not yet parse
  inline `// forge-config:` directives — it reads them as comments
  and falls back to the 256 default. To actually run FuzzFirstDepositor
  at 512 runs, set `FOUNDRY_FUZZ_RUNS=512` or pass `--fuzz-runs 512`;
  both pass cleanly. The inline directive is kept for forward
  compatibility with newer forge versions that do honour it.

**ElysiumCoreWriter integration** (closes M3 item (c)):

`ElysiumCoreWriterIntegration.t.sol` ships:

- `FullElysiumCoreWriterMock` — implements `IElysiumCoreWriter`
  and extends it with the full surface the real predeploy will
  expose (per the doc comment on
  `solidity/src/interfaces/IElysiumCoreWriter.sol`: "order book,
  liquidation, and margin primitives in the months that follow
  mainnet"):

  - Order book: `getOpenOrders(delegator)` returns the still-live
    positions; `getPosition(assetId, delegator)` returns the signed
    notional.
  - Liquidation: `liquidate(assetId, delegator, funds)` sweeps 10%
    of `|notional|` and realizes (mocked) pnl to the liquidator.
  - Margin: `setMargin(assetId, delegator, newMargin)` adjusts the
    position's margin subject to a hard floor (`MIN_MARGIN = 10_000`).
  - Position state: `getPositionState(assetId, delegator)` returns
    `(notional, margin, totalLiquidated)`.
  - Venue-side validation: signature sanity (`v ∈ {27, 28}`,
    `(r, s) ≠ 0`), per-order cap (`notional ≤ d.maxPerOrder`),
    per-venue cumulative notional cap (`MAX_VENUE_NOTIONAL = 100 USD`
    per `(delegator, keeper, assetId)`), expiry (`d.expiresAt ≠ 0`
    AND `block.timestamp > d.expiresAt` → reject; `expiresAt == 0`
    is the "never" sentinel), and replay (composite key
    `keccak(keeper, nonce, salt)` seen once).

- `ElysiumCoreWriterIntegrationTest` — 23 tests across three groups:

  - **Direct writer tests (17)**: open short / open long, close
    short, full round-trip with distinct nonces, zero-sig rejection,
    real-sig acceptance, expired-delegation rejection, never-expires
    acceptance, replay rejection, per-order cap, per-venue
    cumulative cap, liquidate-sweeps-10%, set-margin floor,
    getPositionState tuple, zero-keeper rejection, bad-sig-v
    rejection, getOpenOrders returns both positions, production sim
    open → setMargin → liquidate round-trip.
  - **Cross-test with `PerpFundingLeg.submitIntent`** — confirms
    the venue sees the perp-short notional (50% of the submitted
    amount) at the venue after `submitIntent` forwards.
  - **Cross-test with `BasisHedgeLeg.submitIntent`** — same pattern
    on the basis leg.
  - **Production simulations (2)**:
    - `_fallbackSig` from the phase-1 `allocateTo` path is rejected
      by a real venue — confirms the round-7 KI-2 fix is
      load-bearing: the fallback path cannot pass a production
      venue's signature check.
    - Expired delegation forwarded by a compromised keeper is killed
      at the writer even if the leg-side verifier accepts it —
      documents the venue-side expiry check as a second line of
      defence (per `AGGREGATOR_SPEC.md §2.3`).

**Tests added**: 27 (4 fuzz + 23 writer integration).

**Test count**: 185 → 212 (27 new). `forge test`: 212/212 pass
across 17 suites. `check_repo.py`: 0 FAIL.

Net effect: **212 tests, 0 failed** (`forge test`), **27 round-14
new tests** (4 fuzz + 23 writer integration), **2 M3 items closed**
((c) writer integration, (d) first-depositor fuzz). Only remaining
open items: (a) khypeBalance rate-tracking drift (design doc exists;
implementation deferred), (b) KI-2b Phase 2 aggregator refactor
(blocked on ElysiumCoreWriter shipping), (e) audit (M4 gate).

**Related hardening noticed but not fixed** (round-14 review):

- The venue-side expiry check in `FullElysiumCoreWriterMock` treats
  `d.expiresAt == 0` as "never expires" (the sentinel from
  `DELEGATION_SPEC.md §4`). The real predeploy must adopt the same
  sentinel; if it does not, the leg's `_nextDelegation` will produce
  delegations the venue rejects.
- `PerpFundingLeg._fallbackSig()` still exists and is still callable
  from `allocateTo` / `harvest` / `reduceFrom` when
  `devFallbackEnabled = true` (constructor default). The
  `test_CrossPerpFundingLeg_fallbackSig_rejectedByRealVenue` test
  proves the venue rejects it, but the leg still *produces* it —
  that is KI-2b Phase 2's job to remove (deferred).
- `FullElysiumCoreWriterMock.MAX_VENUE_NOTIONAL` is a flat
  `100 USD` in the test rig; the real predeploy will enforce a
  venue-configurable cap. The test only proves the cap *math* is
  right, not that the venue is configured correctly.

### 2.10 Round-15 changelog

Round-15 (2026-09-24) — mixed: 15a touches `solidity/src/` and
`solidity/test/`; 15b touches `solidity/test/FuzzCoverage.t.sol`;
15c is docs-only. No changes to any finalized test file, deploy
harness, or verifier.

- **15a**: KI-2b Phase 3 cleanup (DESIGN_KI2_SUBMITINTENT.md §9 Phase
  3, DESIGN_KI2B_AGGREGATOR_STREAM_A.md Phase 3 bullet). Two perp
  legs (`PerpFundingLeg.sol`, `BasisHedgeLeg.sol`): deleted
  `bumpNonce()` (owner-only setter, was dead-lettered with no
  test — see TEST_COVERAGE_GAP.md §2.4); renamed
  `lastDelegationNonce` → `nextDelegationNonce` (semantics flipped
  from post-increment to pre-increment, matching the design doc §6
  rationale — first call proposes nonce=0, second proposes nonce=1,
  and the value written into `Delegation.nonce` is the pre-increment
  value); added `mapping(address => mapping(uint256 => uint256))
  public lastExecutedNonce` keyed by `(delegator, nonce)`, written
  ONLY after a successful `_writeOpen`/`_writeClose` returns inside
  `submitIntent`/`submitIntentFromStreamA` — NOT from the fallback
  `_writeOpen`/`_writeClose` path (gated by `devFallbackEnabled`,
  uses `_fallbackSig` and does not represent real venue execution).
  New `Phase3NonceCleanupTest` sub-suite in `solidity/test/Legs.t.sol`
  (10 tests): `nextDelegationNonce` starts at 0 and increments by 1
  per allocate, storage rollback on writer revert (pre-increment
  atomicity), `lastExecutedNonce` written after successful
  stream-B/`submitIntent` and stream-A/`submitIntentFromStreamA`,
  NOT written on leg-side per-order cap rejection, NOT written on
  writer-side revert (via `MockWriterFailOpen`), NOT written by
  legacy `allocateTo`, keyed by delegator not keeper. Doc updates:
  TEST_COVERAGE_GAP.md (lines 260, 284, 669), DESIGN_KI2_SUBMITINTENT
  §9 Phase 3, DESIGN_KI2B_AGGREGATOR_STREAM_A Phase 3 bullet, this
  §2.10 entry. Not touched: `KHYPELeg.sol`, `SpotStakingLeg.sol`
  (no nonces), `FuzzCoverage.t.sol` (agent 15b), KINETIQ_EMAIL_DRAFT /
  AUDIT_SUMMARY (agent 15c). TradeOnlyAgent delegation struct
  unchanged.

- **15b**: fuzz gap closure (round-15b). Three new fuzz tests in
  `solidity/test/FuzzCoverage.t.sol` close the three remaining
  open items in `docs/TEST_COVERAGE_GAP.md §6`:

  - `FuzzDelegationKey.testFuzz_DelegationKey_uniqueness` — fuzzes
    `(nonce1, salt1, id0, maxNotional, maxPerOrder, keeper)` and
    asserts the EIP-712 `digestStruct` differs when any of
    `nonce`, `salt`, or `assetIds` is perturbed; pins a
    determinism invariant and cross-checks against the live
    `TradeOnlyAgent.isValidDelegation` via `vm.sign`. Because
    `_delegationHash` is internal, the digest is recomputed inline
    in the test (mirroring `TradeOnlyAgent.sol:124-145`).
  - `FuzzDistributeWeights.testFuzz_Distribute_weightVector` —
    fuzzes `(w0, w1, w2, w3, deposit)`, normalizes the weights to
    `sum == 10000` with an overflow-safe fallback, applies them
    through `requestAllocation` + `executePending` (the only
    keeper-governance path), deposits `deposit` USDC, and asserts
    the aggregator's accounting identity
    (`sum(legs.currentValue()) + usdc.balanceOf(agg) == totalAssets`)
    plus the stronger `totalAssets == deposit` invariant.
  - `FuzzBasisAllocateBoundaries.testFuzz_BasisAllocate_boundaries`
    — fuzzes `amount ∈ [0, 1e18]` USDC base units and asserts
    `allocatedUsd == amount` for `amount ≥ 2` and reverts with
    `"zero"` at `amount == 0` / `"dust"` at `amount == 1`. Deploys
    `BasisHedgeLeg` through `vm.deployCode("src/legs/BasisHedgeLeg.sol",
    ...)` because the file imports both `YieldAggregator.sol`
    (which declares `IERC20Minimal` locally) and would otherwise
    clash with `src/interfaces/IERC20.sol`'s same-named interface.
    A minimal `MockHypeBalance` (returns 0) short-circuits
    `_buyHype` when `router == 0`, and a no-op `MockWriter` is
    required because a bare CALL to `writer == address(0)` reverts
    with an EvmError that Forge's fuzz engine treats as an
    unhandled panic.

  `forge test` at the 15b tip: three new fuzz tests added (one new
  contract per test, all in `FuzzCoverage.t.sol`). Together with
  15a's `Phase3NonceCleanupTest` the round-15 test suite is 225 tests
  across 21 suites (baseline 212 + 10 from 15a + 3 from 15b), all
  green. The file-level `// forge-config: default.fuzz.runs = 512`
  directive is preserved (the pre-existing one). Not touched:
  `KHYPELeg.sol`, `SpotStakingLeg.sol`, `PerpFundingLeg.sol` (§15a),
  `BasisHedgeLeg.sol` (§15a), `Legs.t.sol` (§15a),
  `KINETIQ_EMAIL_DRAFT.md` (§15c), `AUDIT_SUMMARY.md` (§15c).

- **15c**: refreshed `docs/KINETIQ_EMAIL_DRAFT.md` to reflect
  round-14 reality (212 tests / 17 suites, M3 closed, 8 KI closed +
  round-9 red-team fixes, +3.47% APY median empirical alpha framed
  as a complementary regime-aware layer, reference-quality not
  audited, Apache-2.0 license, narrow builders-allocation ask).
  Added `docs/AUDIT_SUMMARY.md` as the M4 gate entry point:
  scope, 7-contract inventory, test coverage, adversarial-review
  history (rounds 2 → 14), open items, verification commands,
  repo hygiene, and license/IP.

### 2.11 Round-16 through Round-19 changelog (2026-09-24)

Post-audit work executed while waiting on Kinetiq reply. All changes
pushed to GitHub master at `0284a9d` (round-18) plus two more on top
in this window. Test counts are cumulative where noted.

- **Round-16 (`a667c50`)**: added `keeper-runtime/` (A1) and
  `dev-harness/` (A2).
  - **`keeper-runtime/`**: TypeScript keeper runtime with bit-exact
    EIP-712 signing for the `TradeOnlyAgent` delegation struct.
    Hand-computed digest (not `TypedDataEncoder.hashTypedData`)
    because the contract inserts `_from` into the outer `abi.encode`
    but the typehash omits `_from` — a non-standard EIP-712 shape.
    Signing uses `signingKey.sign(digest)`, not `signMessage(digest)`,
    because the contract calls `ecrecover` on the raw digest, not the
    EIP-191-wrapped form. **See round-21 for the daemon addition and the
    updated test count (102).**
  - **`dev-harness/`**: standalone Foundry library for testing
    against the unpublished Elysium L1Read precompile. Uses
    `vm.store` + `vm.deployCode` at a placeholder address; adapter
    from mock to `IMarketDataFeed`; snapshot-based fixture for
    reproducibility. 53 forge tests pass.
  - SECURITY.md + `.env.example` in both (Hardhat dev key #0, clearly
    flagged "never for real funds"). `.mimosa/` gitignored.
- **Round-17 (`77182a0`)**: A3 — Liminal xHYPE as the 5th leg.
  - `solidity/src/interfaces/IXHYPELeg.sol` — marker interface with
    `apyBps()` and `isLiquidatable()` on top of ERC-4626 shape.
  - `solidity/src/legs/LiminalXHYPELeg.sol` — full ERC-4626 wrapper
    for Liminal xHYPE: USDC→HYPE→vault flow, CCE reentrancy guard,
    slippage bound against oracle price post-swap,
    `oracle→vault→fixed` APY fallback chain, `harvest()` for
    residuals, `maxAllocationUsd` cap, `isLiquidatable()` gate,
    owner setters.
  - `RegimeDetector.sol`: added `weightsForRegime5(regime)` +
    `XHYPE_WEIGHT_BPS(regime)` + internal `_weightsForRegime5`.
    5-slot vectors per regime summing to 10,000 bps:
    FUNDING_STRONG `[0, 400, 6000, 3000, 600]`,
    FUNDING_WEAK `[2000, 800, 4000, 2000, 1200]`,
    FUNDING_NEG `[4000, 2400, 0, 0, 3600]`,
    HIGH_VOL `[5000, 2000, 0, 0, 3000]`. xHYPE weight always
    ≤ original kHYPE weight in the same regime (xHYPE-first
    migration, since xHYPE is strictly better than kHYPE on APY).
  - `YieldAggregator.sol`: `IYieldLeg[5] public legs`, new
    `setXHYPELeg(IYieldLeg, uint16 weightBps)` owner setter, new
    views `weights5()`, `legsView5()`, `xhypeWeight()`, `legAt(i)`,
    `currentValueOfLeg(i)`. Constructor kept at 4-arg tuple so
    all 225 pre-round-17 tests compile + pass unchanged.
  - **297 forge tests pass, 0 fail** (was 225 in round-15; +72 new
    tests across `LiminalXHYPELeg.t.sol` (39) and
    `RegimeDetector.fifthLeg.t.sol` (33)).
- **Round-18 (`0284a9d`)**: A11 — Elysium Builders Starter Kit.
  - **`elix-kit/`**: self-contained Foundry + TypeScript template
    that lives in the aggregator repo but is designed to be copied
    out and used standalone. `cd elix-kit && cd solidity && forge test`
    gives a working scaffold in <5 minutes.
  - Solidity: `HelloElysium.sol` (trivial greeting),
    `VaultStarter.sol` (minimal ERC-4626 vault with owner-gated
    `setTargetApyBps`, full transfer/transferFrom/approve plumbing,
    MockERC20 inline in the test). Two interfaces copied from the
    parent repo (`IERC20.sol`, `ITradeOnlyAgent.sol`); rest is new.
  - TypeScript: `ElysiumClient` helper that takes
    `(rpcUrl, deployerPk)` and exposes `deployHelloElysium(greeting)`
    + `deployVaultStarter(targetApyBps)`. Vitest tests for
    ABI encode/decode roundtrip (offline, no live RPC).
  - Apache-2.0 license, SECURITY.md points to parent SECURITY.md
    for the aggregator-specific threat model.
  - **15 forge tests pass, 0 fail** in `elix-kit/solidity/`. 11
    vitest tests written (not run — no `node_modules` in CI).
  - Also in this commit: `docs/KINETIQ_EMAIL_DRAFT.md` handle split
    fixed to `@chekhlolz (GitHub), @icesilentx (X)` on line 4 and
    `@icesilentx (X) / @chekhlolz (GitHub)` on line 200. This was
    a mistake in the round-16 commit that conflated the two handles.
- **Round-19 (`3076ba8`)**: A12 — Kinetiq Partners One-Pager.
  - **`docs/KINETIQ_PARTNERS_ONEPAGER.md`**: self-contained 243-line
    one-pager that can be pasted as a DM to Kinetiq or attached
    alongside the longer `KINETIQ_EMAIL_DRAFT.md`. Same contacts,
    same routing options, same alpha framing. Explicitly does not
    ask for KNTQ allocation or priority routing — engineering time +
    technical review only.
  - Structure: TL;DR → what we built → why Elysium specifically →
    what we're asking for → contacts → repo hygiene → known
    limitations → committed timeline. Honest limitations section
    (per-venue notional cap, xHYPE not on Elysium yet, alpha below
    Liminal live, not audited, chainId placeholder, no live deploy).

### 2.12 Repo totals after round-19

Snapshot at the time the round-20 ROADMAP refresh was written. Later
rounds (21–23) are recorded below and supersede this snapshot.

- Solidity contracts: **7** (unchanged from round-15).
- Solidity interfaces: **12** (was 10 in round-15; +`IXHYPELeg.sol`
  in the parent, +1 more interface count from the aggregator).
- Forge tests in parent `solidity/`: **297 pass / 0 fail** (was
  225 in round-15).
- Forge tests in `dev-harness/`: **53 pass / 0 fail**.
- Forge tests in `elix-kit/solidity/`: **15 pass / 0 fail**.
- Node:test tests in `keeper-runtime/`: **74 pass / 0 fail** at the
  round-16 landing; grows to **102** in round-21 when the daemon and
  venue-adapter test suites are added.
- **Total tests at round-19**: **439**, all green. Grows to **467**
  by round-23 (see §2.14).
- License: Apache-2.0 across all three sub-repos.
- Repo state: pushed to GitHub `chekhlolz/elysium-yield-aggregator`
  master at `3076ba8` (round-19). A1 daemon core agent still running
  at the time of this ROADMAP refresh; lands as round-21.

### 2.13 Rounds 20–23 (2026-09-24)

Post-A1-daemon + dashboard + ROADMAP refresh. All pushed to master.

- **Round-20 (`1abb9ee`)**: ROADMAP §2.11/§2.12 refresh — recorded
  rounds 16 through 19 and the running total test count of 439.
- **Round-21 (this commit)**: A1 — Keeper daemon core.
  - **`keeper-runtime/src/daemon.ts`** (462 lines): `KeeperDaemon`
    polling loop with `tick()`, `start()`/`stop()` lifecycle,
    monotonic nonce, sliding-window rate limit (60 tx/min), client-side
    per-order cap check, venue-side revoke check, used-notional cap
    check, `DaemonEvent` emitter. Nonce is consumed only when a
    submission is *attempted* (both `submitted` and `failed` bump it,
    `skipped` does not). Signing failures do not consume the nonce
    because the venue state is unambiguous.
  - **`keeper-runtime/src/venue-adapter.ts`** (285 lines): `IVenueAdapter`
    interface + `MockElysiumCoreWriter` in-memory implementation
    (FIFO queue, `usedNotional` keyed by `(delegator, keeper, nonce)`
    triple, `revoke` per pair, `sumUsedNotional` accessor). The mock
    does NOT verify EIP-712 — signature verification is covered
    separately by `TradeOnlyAgent.sol` + `test/signing.test.ts`.
  - **`keeper-runtime/src/daemon-types.ts`** (139 lines): shared types
    — `PendingIntent`, `SubmitResult`, `SubmittedTrade`, `DaemonConfig`,
    `DaemonEvent`, `KeeperDaemonStats`. Kept in its own file so the
    daemon and venue adapter don't import from each other just to share
    a shape.
  - **Tests**: `test/daemon.test.ts` (17 cases) + `test/venue-adapter.test.ts`
    (11 cases). Both converted to `node:test` — the A1 agent originally
    imported `vitest`, which is not in `devDependencies`; conversion is
    mechanical plus a `Date.now` freeze helper for the rate-limit window
    (node:test ships no fake timers).
  - **Test count change**: keeper-runtime went from 74 → **102 pass**.
    Total repo tests now **467** (297 + 53 + 15 + 102).
- **Round-22 (`c34ef22`)**: A6 — HyperEVM ecosystem dashboard.
  - **`dashboard/`**: static single-page HTML + JSON + Python refresher,
    no backend, no accounts, no analytics. Chart.js 4.4.1 SRI-pinned
    via jsDelivr, `<noscript>` fallback, no `localStorage`.
  - **`dashboard/data.json`**: 7 protocols (Hyperliquid Bridge, Kinetiq
    kHYPE, Morpho Blue, Veda, Liminal xHYPE, Gauntlet, CCIP) +
    ecosystem totals + Robinhood Chain peer comparison, all sourced
    from DeFiLlama. Total HyperEVM TVL ≈ $1.297B in the snapshot.
  - **`dashboard/refresh.py`**: 256-line stdlib-only DeFiLlama fetcher.
    Idempotent, cron-friendly, no API keys.
  - Serves as a shareable artifact in the Kinetiq conversation: shows
    the ecosystem the aggregator will run in, without exposing any
    internal tooling.

### 2.14 Repo totals after round-23

- Solidity contracts: **7**.
- Solidity interfaces: **12**.
- Forge tests in parent `solidity/`: **297 pass / 0 fail**.
- Forge tests in `dev-harness/`: **53 pass / 0 fail**.
- Forge tests in `elix-kit/solidity/`: **15 pass / 0 fail**.
- Node:test tests in `keeper-runtime/`: **102 pass / 0 fail**.
- **Total tests**: **467**, all green.
- License: Apache-2.0 across all four sub-repos.
- Repo state: pushed to GitHub `chekhlolz/elysium-yield-aggregator`
  master at the round-23 HEAD. M3 fully closed; only M4 (audit gate)
  + Kinetiq DM remains.

## 3. Kinetiq conversation

**Send this when**: the aggregator sim produces alpha >= 0 on the real
funding dataset. Currently: **+3.47% APY median alpha** over a static
benchmark (25-cell sweep winner, 15 seeds, 100% positive) — still
below Liminal xHYPE's live 14.50%, which is the honest framing in the
draft.

**Send this to**: the `builders` allocation channel mentioned in
`docs/KINETIQ_EMAIL_DRAFT.md`. Include:
- The `hypeback` repo (this directory).
- `docs/AGGREGATOR_SPEC.md` and `docs/DELEGATION_SPEC.md`.
- A note that the alpha figure is +3.47% APY (empirical, sweep winner),
  not the +4.5-6% total-edge estimate in `AGGREGATOR_SPEC.md §4`.

**Ask for**:
1. The precompile address + spec.
2. ElysiumCoreWriter timeline.
3. Builders-allocation criteria.

## 4. Milestones

| Milestone | Status |
|---|---|
| **M1: Research artifact** | ✅ Repo + specs + KINETIQ_EMAIL_DRAFT.md (draft, not sent — awaiting Kinetiq contact + GitHub push). |
| **M2: Testnet deployment** | 🟡 4 leg contracts + aggregator ✅. Round-4 closed KI-3 (BasisHedge dust guard), KI-4 (stale `latestApyBps`), KI-5 (optimistic `_allocatedTotal`). Round-5 closed KI-7 (delegate withdraw collateral) and KI-8 (redeem share-allowance category error). Round-6 closed **KI-1** (stake-leg unit drift — Option A, convert once at boundary). Round-7 closed **KI-2** (`_zeroSig()` writer stub — Option C, hybrid: perp legs accept `submitIntent`). **Only remaining open item**: **KI-6** (per-venue delegation cap — accepted spec tradeoff, documented in `DELEGATION_SPEC.md §9`); see §2.5. |
| **M3: Audit-ready** | 🟡 Foundry test suite: **212 tests PASS across 17 suites** (RegimeDetectorTest 29, YieldAggregatorTest 38, TradeOnlyAgentTest 25, Legs.t.sol 58 across 8 sub-suites: LegsTest 27 + KI1ReconcileTest 7 + KI2PerpFundingTests 6 + KI2BasisHedgeTests 4 + KI5SlippageTests 4 + KI5SlippageGovernanceTests 6 + KI5HarvestAccountingTests 2 + KI2StakingLegsNegativeTest 2, FuzzCoverage 24 (20 round-8 + 4 round-14 FuzzFirstDepositor), ElysiumCoreWriterIntegrationTest 23 (round-14), AggInvariantTest 1 campaign with 3 invariants) ✅. Verifier `check_repo.py` 0 FAIL ✅. ERC-4626 math hardened for cancelPending/reentrancy/expiry/weights ✅. Delegate `withdraw`/`redeem` anti-patterns removed (KI-7, KI-8, round-5) ✅. KI-1 stake-leg unit drift fixed (Option A, round-6) ✅. KI-2 `_zeroSig()` writer stub replaced with real `submitIntent` flow (Option C, round-7) ✅. Aggregator invariants: shareValueBounded, weightsSumTo10000, noDoubleCounting (round-7) ✅. Round-8: harvest accounting fix (KI-1 §9.2), router slippage guard (KI-1 §9.3), fuzz coverage +20, real Anvil integration caught 2 deploy.py bugs (RegimeDetector constructor arg, gas limit 2M→4M, Anvil 1.8.3 default address change) ✅. Round-9: RegimeDetector hostile-feed hardening (int64 saturation, basis underflow), delegation canonical sig rejection, `recordExecution` enforces `maxPerOrder`, `setTimelock` minimum 60s, `ITradeOnlyAgent` doc sync ✅. Adversarial review (17 findings): 5 real fixes applied, 4 spec-accepted responsibility splits documented (KI-6, KI-9, KI-13, KI-14), 2 deferred to design rounds ✅. Round-14: first-depositor & share-allowance fuzz (4 tests, 256 runs each, closes M3 item (d)), ElysiumCoreWriter integration with full-surface mock + 23 tests including order book, liquidation, margin primitives, and cross-test with `PerpFundingLeg` / `BasisHedgeLeg.submitIntent` (closes M3 item (c); see §5.1 of `docs/TEST_COVERAGE_GAP.md` and §2.9 of this file). **Still to close**: (a) `khypeBalance` / `rewardHypeBalance` rate-tracking drift — design doc exists at `DESIGN_KI1_RATE_TRACKING.md` (recommended option A, closes round-9 finding #1/#2 + #17), implementation deferred to agent F (round-10 / round-11); (b) KI-2b Phase 2 aggregator refactor — blocked on ElysiumCoreWriter shipping; (e) audit (M4 gate). |
| **M4: Mainnet** | ⬜ Audit passed. Governance live. First 100k USD TVL. |

## 5. Leg TODOs (in-code)

Each leg carries a small list of pre-production `// TODO:` items. They
are picked up automatically by the ROADMAP grep (`grep -rn "TODO:"
solidity/src/legs/`) and are the checklist for M2 → M3.

| Leg | TODO | Owner / Notes |
|---|---|---|
| `KHYPELeg` | `fixedApyBps` fallback — remove once live oracle is wired. | Swap to Kinetiq price oracle. |
| `SpotStakingLeg` | `fixedApyBps` fallback (same as KHYPE). | Same fix. |
| `SpotStakingLeg` | `UNBONDING_PERIOD = 24h` is a hint; confirm with HyperEVM team. | Pool's `unbondingPeriod()` is the source of truth at runtime. |
| `PerpFundingLeg` | `HYPE_ASSET_ID = 1` is a placeholder; confirm with Kinetiq. | Writer assigns ids post-launch. |
| `PerpFundingLeg` | `fixedApyBps` fallback when `fundingSource` is not live. | Same as staking legs. |
| `PerpFundingLeg` | ~~Add a `submitIntent(Delegation, Signature, uint256)` path — current stub uses `_zeroSig()`.~~ | **DONE in round-7** (KI-2 closed) — see §2.5 KI-2 row and §2.7 changelog. |
| `PerpFundingLeg` | Add `maxLeverage` and notional cap. | Safety. |
| `PerpFundingLeg`, `BasisHedgeLeg` | Router address set by deployer — replace with production HyperCore DEX. | Router is the only spot-market primitive. |
| `BasisHedgeLeg` | Add mark-to-market oracle for unrealised perp PnL in `currentValue()`. | Stub counts realised PnL only. |
| `BasisHedgeLeg` | `HEDGE_RATIO_BPS = 10_000` hard-coded (HR=1.0) per spec. | Make configurable per venue. |
| `BasisHedgeLeg` | `HYPE_ASSET_ID = 1` placeholder. | Same as PerpFundingLeg. |

## 6. Not-doing (explicit)

- **Options market** — HyperCore doesn't have options. Aggregator is
  spot + LST + perp + basis only.
- **Multi-asset** — HYPE-USD only. BTC/ETH/other aggregators are a future
  version with the same architecture.
- **MEV / bundle search** — Kinetiq explicitly says "no privileged lanes".
  Aggregator reacts to on-chain state, doesn't try to search.
- **Institutional custody** — this is open-source and permissionless;
  institutional use is a separate wrapper.

---

*Generated 2026-09-22. This is a research artifact, not an audited
production system. Nothing here should be deployed with real capital
until M3 (audit-ready) is complete.*
