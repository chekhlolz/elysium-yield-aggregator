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
| **M3: Audit-ready** | 🟡 Foundry test suite: **120 tests PASS** (RegimeDetector 20, YieldAggregator 34, TradeOnlyAgent 19, Legs 46 across 5 suites: LegsTest 27 + KI1ReconcileTest 7 + KI2PerpFundingTests 6 + KI2BasisHedgeTests 4 + KI2StakingLegsNegativeTest 2, AggInvariantTest 1 campaign with 3 invariants) ✅. Verifier `check_repo.py` 0 FAIL ✅. ERC-4626 math hardened for cancelPending/reentrancy/expiry/weights ✅. Delegate `withdraw`/`redeem` anti-patterns removed (KI-7, KI-8, round-5) ✅. KI-1 stake-leg unit drift fixed (Option A, round-6) ✅. KI-2 `_zeroSig()` writer stub replaced with real `submitIntent` flow (Option C, round-7) ✅. Aggregator invariants: shareValueBounded, weightsSumTo10000, noDoubleCounting (round-7) ✅. **Still to close**: integration coverage against a real `ElysiumCoreWriter` (the MockWriter covers the verifier-verification path, but not the real predeploy), first-depositor & share-allowance fuzz, deploy.py Anvil integration is in-tree but the real Anvil binary is not installed on this machine (mock RPC smoke-tested instead), audit (M4 gate). |
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
