# Audit Summary — Elysium Yield Aggregator + Trade-Only-Agent

**Status**: Reference-quality, not audited.
**Milestone**: M3 (testnet-deployable aggregator with adversarial security
review) closed round-14. This summary is the entry point for the M4 audit
gate.
**License**: Apache-2.0, reference implementation.
**Repo**: `hypeback/` — 15 waves of committed work, working tree clean
at commit `19efedc`.

---

## 1. Scope

### In scope (this audit)

- 7 Solidity contracts under `solidity/src/` (aggregator, delegation,
  keeper, and the four yield legs).
- 10 Solidity interfaces under `solidity/src/interfaces/` plus the
  `IMarketDataFeed` interface defined inline in `RegimeDetector.sol`.
- The `SafeERC20` library inlined in `YieldAggregator.sol`.

### Out of scope

- Test suite (`solidity/test/*.t.sol`, `solidity/test/*.invariant.t.sol`)
  and test mocks (`FullElysiumCoreWriterMock`, `MockYieldLeg`,
  `MockRouter`, `MockPool`, `MockWriter`, etc.) — these are the
  auditor's verification inputs, not audit subjects.
- Python dev tooling: `hypeback/` backtester, `solidity/scripts/verify.py`,
  `solidity/scripts/deploy.py`, `solidity/scripts/compile.py`,
  `solidity/scripts/build.py`, `solidity/tests/test_deploy_anvil.py` —
  none of these are deployed.
- The external verifier (`~/Downloads/check_repo.py`) — the auditor's
  pre-flight checklist, not an audit subject.
- Bundled historical funding records (referenced from
  `hypeback/cli.py` as `data/hype_funding_full.json` /
  `data/hype_candles_1h.json`; fetched on demand, not committed to
  the repo) — test data, not a deployed dependency.

### Explicit non-audit boundaries

- No real capital has touched these contracts. All state transitions
  in this repo have been exercised against mocks or Anvil.
- No live mainnet precompile or predeploy addresses are in scope —
  only Elysium testnet is available as of this writing.
- This repo has never been through a formal external audit. This
  document is the *input* to the audit, not the *result* of one.

---

## 2. Contract inventory

| # | Contract | Path | Deployed bytes | Purpose |
|---|---|---|---|---|
| 1 | `YieldAggregator` | `solidity/src/aggregator/YieldAggregator.sol` | 17,880 | ERC-4626 vault; keeper + timelock rebalance; delegate `withdraw`/`redeem` (KI-7/KI-8 patched); Stream-A delegation signing with a dev-fallback gate; round-17 added the 5th slot for Liminal xHYPE via `setXHYPELeg`. |
| 2 | `TradeOnlyAgent` | `solidity/src/delegation/TradeOnlyAgent.sol` | 3,103 | EIP-712 trade delegation verifier; canonical ECDSA recovery; universal `revoke(keeper)`; venue-local notional cap with per-order enforcement. |
| 3 | `RegimeDetector` | `solidity/src/keeper/RegimeDetector.sol` | 3,334 | Elysium market-data precompile adapter; regime classification across FUNDING_STRONG / WEAK / NEG / HIGH_VOL; hardened against hostile feeds; round-17 added `weightsForRegime5` for the 5-slot vectors. |
| 4 | `KHYPELeg` | `solidity/src/legs/KHYPELeg.sol` | 7,743 | Wraps the kHYPE LST on HyperCore; yield accrues via the pool's exchange rate; KI-1 Option A2 rate-tracking; KI-3 through KI-6 patched. |
| 5 | `SpotStakingLeg` | `solidity/src/legs/SpotStakingLeg.sol` | 7,767 | Direct HYPE staking on HyperEVM (24h unbonding hint); KI-1 Option A2 rate-tracking; same shape as `KHYPELeg` for the accounting path. |
| 6 | `PerpFundingLeg` | `solidity/src/legs/PerpFundingLeg.sol` | 13,149 | Long-spot / short-perp on HyperCore HYPE-USD perp to capture funding; `submitIntent` for Stream-B LP intents; `_fallbackSig` gated by `devFallbackEnabled`. |
| 7 | `BasisHedgeLeg` | `solidity/src/legs/BasisHedgeLeg.sol` | 13,137 | Same long-spot / short-perp shape at HR = 1.0 but targets basis carry; same `submitIntent` / `_fallbackSig` gate as `PerpFundingLeg`. |
| 8 | `LiminalXHYPELeg` | `solidity/src/legs/LiminalXHYPELeg.sol` | 7,849 | ERC-4626 wrapper for Liminal xHYPE vault (14.50% APY live, off-Elysium as of writing). USDC→HYPE→vault flow with CCE reentrancy guard, slippage bound against oracle price post-swap, `oracle→vault→fixed` APY fallback chain, `harvest()` for residuals, `maxAllocationUsd` cap, `isLiquidatable()` gate, owner setters. Round-17. |

**Total deployed bytecode**: 73,962 bytes across 8 contracts
(including `SafeERC20`, `RegimeId` enum, and the minimal
`IERC20Minimal` facade).

**Interfaces** (22 Solidity artifacts total across contracts + interfaces
+ lib): `IYieldAggregator`, `ITradeOnlyAgent`, `IYieldLeg`,
`IIntentSubmittingLeg`, `IXHYPELeg`, `IERC20`, `IERC20Router`,
`IElysiumCoreWriter`, `IFundingSource`, `IPriceOracle`, `IStakingPool`,
plus the inline `IMarketDataFeed` in `RegimeDetector.sol` and the
`IERC20Minimal` facade. See the full table in `README.md §Contracts`.

---

## 3. Test coverage

**297 forge tests green across 23 suites (round-23 refresh; was 212 /
17 in the round-15 snapshot). `forge invariant` passes on 3 aggregator
invariants. External verifier (`check_repo.py`) at 0 FAIL.**

### Suite breakdown (round-15 snapshot, superseded)

| Suite | File | Count |
|---|---|---|
| `RegimeDetectorTest` | `solidity/test/RegimeDetector.t.sol` | 29 |
| `YieldAggregatorTest` | `solidity/test/YieldAggregator.t.sol` | 38 |
| `StreamATests` | `solidity/test/YieldAggregator.t.sol` | 8 |
| **`YieldAggregator.t.sol` subtotal** | — | **46** |
| `TradeOnlyAgentTest` | `solidity/test/TradeOnlyAgent.t.sol` | 25 |
| `LegsTest` | `solidity/test/Legs.t.sol` | 27 |
| `KI1ReconcileTest` | `solidity/test/Legs.t.sol` | 7 |
| `KI1aRateTrackingTest` | `solidity/test/Legs.t.sol` | 6 |
| `KI2PerpFundingTests` | `solidity/test/Legs.t.sol` | 6 |
| `KI2BasisHedgeTests` | `solidity/test/Legs.t.sol` | 4 |
| `KI5SlippageTests` | `solidity/test/Legs.t.sol` | 4 |
| `KI5SlippageGovernanceTests` | `solidity/test/Legs.t.sol` | 6 |
| `KI5HarvestAccountingTests` | `solidity/test/Legs.t.sol` | 2 |
| `KI2StakingLegsNegativeTest` | `solidity/test/Legs.t.sol` | 2 |
| **`Legs.t.sol` subtotal** | — | **64** |
| `FuzzCoverageTest` | `solidity/test/FuzzCoverage.t.sol` | 20 |
| `FuzzFirstDepositor` | `solidity/test/FuzzCoverage.t.sol` | 4 |
| **`FuzzCoverage.t.sol` subtotal** | — | **24** |
| `ElysiumCoreWriterIntegrationTest` | `solidity/test/ElysiumCoreWriterIntegration.t.sol` | 23 |
| `AggInvariantTest` | `solidity/test/YieldAggregator.invariant.t.sol` | 1 campaign / 3 invariants |

**Total: 212 tests across 17 suites (round-15 snapshot).**

### Round-13 through round-23 additions (post-snapshot)

- **Round-13 (KI-1 rate-tracking fix, Option A2)**: added the
  rate-tracking invariants already folded into the `LegsTest` /
  `KI1aRateTrackingTest` counts above.
- **Round-14 (last-mile M3 fuzz + ElysiumCoreWriter integration)**:
  expanded `FuzzCoverage.t.sol` (24 → still 24 counted, but broader
  parameter sweeps inside the existing tests) and the
  `ElysiumCoreWriterIntegrationTest` (23).
- **Round-17 (Liminal xHYPE 5th leg)**:
  - `solidity/test/LiminalXHYPELeg.t.sol` — **39 tests**: deposit /
    withdraw / withdrawFor / convert / preview / `setXHYPELeg` /
    `harvest` / `isLiquidatable` / `maxAllocationUsd` cap / slippage
    bound / CCE reentrancy / oracle→vault→fixed fallback / fuzz over
    oracle price and vault exchange-rate deltas.
  - `solidity/test/RegimeDetector.fifthLeg.t.sol` — **33 tests**:
    5-slot weight vectors sum to 10,000 bps for all 4 regimes;
    `XHYPE_WEIGHT_BPS` ≤ kHYPE weight per regime; `weightsForRegime5`
    / `_weightsForRegime5` / `weights5` roundtrips; owner-only setter;
    events.
  - **+72 new forge tests**, bringing the parent forge total from 225
    (round-15) to 297 (round-17 through 23).
- **Round-21 (keeper daemon core)**: +28 node:test cases in
  `keeper-runtime/test/` (17 daemon + 11 venue-adapter). Total
  repo-wide tests now 467.

**Current totals (round-23)**:
- `solidity/`: **297 forge pass** across 23 suites.
- `dev-harness/`: **53 forge pass**.
- `elix-kit/solidity/`: **15 forge pass**.
- `keeper-runtime/`: **102 node:test pass** (round-21).
- **Repo-wide total: 467 tests, all green.**

### Invariant campaign

`AggInvariantTest` runs 3 invariants against a fuzzed non-owner /
non-keeper sender:

1. `invariant_shareValueBounded` — each shareholder's pro-rata slice of
   `totalAssets()` is bounded by `totalAssets()`.
2. `invariant_weightsSumTo10000` — weights always sum to `BPS_DENOM`.
3. `invariant_noDoubleCounting` — `_allocatedTotal + vaultCash <=
   totalAssets()` (KI-5 accounting), plus fully-observable
   `totalLegValue + vaultCash == totalAssets` sanity check.

### External verifier

`~/Downloads/check_repo.py` (232 lines) is a Python verifier that
checks ABI ↔ interface conformance, EIP-712 type hashes, event topics,
byte-count consistency between `README.md` and the build, and the
`check_repo` structural invariants (S1–S6). Currently exits 0 FAIL.

### What tests do *not* cover

- Live HyperCore microstructure (latency, slippage, queue position) —
  not modelled in the mock writer.
- Live kHYPE pool behaviour under real stake / unstake /
  exchange-rate transitions — mock pool only.
- Real ElysiumCoreWriter predeploy semantics — mocked at
  `FullElysiumCoreWriterMock`, which implements the *expected* surface
  per the doc comment in `IElysiumCoreWriter.sol`.

---

## 4. Adversarial review history

Rounds 2 through 14 surfaced 17+ findings across five adversarial passes.
All 8 originally-tracked known issues (KI-1 through KI-8) are closed
with design docs, implementation, and regression tests. Four additional
round-9 findings were fixed as code-level hardening (not on the original
KI list). Two items are documented as design-only follow-ups tracked in
design docs (see §5).

### Round-2 (adversarial review, 6 findings)

- **KI-1** — stake-leg unit drift (`khypeBalance` in HYPE units,
  `amount` / `allocatedUsd` in USDC). Fixed round-6 (Option A from
  `docs/DESIGN_KI1_UNIT_RECONCILE.md`). Design doc references §1–§9
  including the round-8 follow-up §9.2 (harvest accounting) and §9.4
  (rate-tracking drift — became KI-1(b)).
- **KI-2** — `_zeroSig()` writer stub. Fixed round-7 (Option C, hybrid,
  from `docs/DESIGN_KI2_SUBMITINTENT.md`).
- **KI-3** — `BasisHedgeLeg.allocateTo(1)` double-allocates. Fixed
  round-4 with a `require(amount >= 2)` dust guard.
- **KI-4** — `setFixedApyBps` does not refresh `latestApyBps`. Fixed
  round-4 on all four legs.
- **KI-5** — `_allocatedTotal` decremented by requested `delta` even
  when `reduceFrom` returned less. Fixed round-4 with actual return
  value.
- **KI-6** — per-venue notional cap is venue-local, not global.
  Accepted spec tradeoff (see `docs/DELEGATION_SPEC.md §9`, Q2);
  not a bug.

### Round-5 (test-coverage-gap review, 2 findings)

- **KI-7** — delegate `withdraw(assets, receiver, _owner)` pulled
  `assets` of USDC from the owner via `safeTransferFrom` before
  burning shares. Category error (owner already holds shares; not
  depositing). Fixed round-5 by removing the collateral pull.
- **KI-8** — delegate `redeem(newShares, receiver, _owner)` compared
  `asset_.allowance(_owner, msg.sender) >= newShares` — checked a USDC
  allowance against a share amount. Category error (vault tracks
  shares as plain `uint256` counters, not ERC-20-like shares). Fixed
  round-5 by removing the share-allowance gate.

### Round-6 → Round-7 (KI-1 → KI-2 fixes, design-driven)

- **KI-1** (round-6) — Option A from `DESIGN_KI1_UNIT_RECONCILE.md`:
  convert once at the boundary, track `khypeBalance` in HYPE units
  internally, USDC is a caller-side concept. Regression tests: 7
  `test_KI1_*` in `Legs.t.sol`.
- **KI-2** (round-7) — Option C from `DESIGN_KI2_SUBMITINTENT.md`:
  hybrid. New `IIntentSubmittingLeg` interface (separate from
  `IYieldLeg`); perp legs (`PerpFundingLeg`, `BasisHedgeLeg`)
  implement `submitIntent(Delegation, Signature, uint256)` that
  verifies via `TradeOnlyAgent.isValidDelegation`, enforces
  venue-local `maxPerOrder`, marks intent nonce-keyed, executes via
  writer with the real signature, and calls `recordExecution`.
  Staking legs untouched (never call the writer). Regression tests:
  12 KI-2 tests across 3 subgroups in `Legs.t.sol`.

### Round-8 (harvest accounting + fuzz coverage)

- Harvest no longer decrements `allocatedUsd` on staking legs — closes
  `DESIGN_KI1_UNIT_RECONCILE.md §9.2`.
- Router slippage guard (`slippageBps`) on both stake legs — closes
  §9.3.
- 20 new fuzz tests in `FuzzCoverage.t.sol`.
- Real Anvil integration caught 2 deploy.py bugs (RegimeDetector
  constructor arg; gas limit 2M → 4M). Not contract bugs.

### Round-9 (red-team pass, 17 findings, 5 real code fixes)

The four "additional adversarial fixes" from the round-9 pass, none
originally on the KI list:

- **Non-canonical ECDSA signature rejection** — `TradeOnlyAgent._recover`
  now rejects `r == 0`, `s == 0`, and `s > secp256k1.order / 2`
  (`0x7F...4501DDFE92F46681B20A0`, the mathematically correct
  `(n-1)/2`). *Note: the round-9 task brief supplied `0x7F...57A4501DDFE92F46688B214`;
  that is ~2^4 shorter (251 bits vs the correct 255) and would reject
  ~50% of valid canonical signatures. The mathematically correct value
  is used in the code; a comment in `_recover` points at the
  discrepancy.* Regression: `test_accept_canonical_signature`,
  `test_reject_zero_r`, `test_reject_zero_s`,
  `test_reject_non_canonical_s`.
- **`recordExecution` enforces `maxPerOrder` on the venue side** —
  `require(notional <= d.maxPerOrder, "per-order cap")`. Regression:
  `test_recordExecution_rejects_overPerOrderCap`,
  `test_recordExecution_accepts_atPerOrderCap`.
- **`setTimelock` enforces a 60-second minimum** —
  `require(_ts >= 60, "timelock below 60s")` on `YieldAggregator`.
  60s is the floor; production should tune far higher. Regression:
  `test_setTimelock_rejectsBelowMinimum`,
  `test_setTimelock_acceptsMinimum`,
  `test_setTimelock_acceptsHigherValue`,
  `test_setTimelock_requiresOwner`.
- **`RegimeDetector` hardened against hostile feeds** —
  - `hourlyFundingBps * 8760` was an unchecked signed int64 multiply;
    compute in int256, saturate to `INT64_MAX/MIN` before storing.
  - `(perp - spot) * BPS_DENOM / spot` underflowed on any discount
    market; now pure uint256 math with clamp-to-zero on discount, plus
    zero-oracle price guards that revert with a recognisable string.
  - 9 new tests: 7 unit + 1 boundary + 1 fuzz invariant.

Additionally, 4 spec-accepted responsibility splits were documented
(KI-6, KI-9, KI-13, KI-14) and 2 items deferred to design rounds
(KI-1(b) rate-tracking; KI-2b Phase 2 aggregator refactor).

### Round-11 (KI-1(b) rate-tracking, Option A2)

- **KI-1(b)** — stake-token balance drift across pool `exchangeRate()`
  moves. Fixed with **Option A2** (balance delta) from
  `docs/DESIGN_KI1_RATE_TRACKING.md`. Track `khypeBalance` in
  stake-token count semantics; capture
  `pool.balanceOf(address(this), address(this))` before / after
  `pool.stake` and `pool.unstake` and store the delta.
- **Deviation from §5 pseudocode**: §5 originally wrote a rate-derived
  update; §11.1 documents that the pool's `credit` path inverts that
  relationship and §5 was rewritten (Option A2) to use the balance
  delta. See `docs/DESIGN_KI1_RATE_TRACKING.md §11.1` and §11.2 for
  the rounding-tolerance follow-up. This is an **open auditor-facing
  item** — see §5 below.

### Round-13 (KI-2b Phase 2 — Stream-A delegation refactor)

- **KI-2b Phase 2** — the aggregator now signs its own Stream-A
  delegations and executes pending rebalances on-chain, removing the
  off-chain keeper step. Design at
  `docs/DESIGN_KI2B_AGGREGATOR_STREAM_A.md`, Option B.
- **Dev-fallback gate** — `_fallbackSig()` remains callable from
  `allocateTo` / `harvest` / `reduceFrom` on `PerpFundingLeg` and
  `BasisHedgeLeg` when `devFallbackEnabled = true` (constructor
  default). Flipping it off is owner-controlled
  (`setDevFallbackEnabled`); production must flip it. This is an
  **open auditor-facing item** — see §5 below.

### Round-14 (last-mile M3 closure)

- **First-depositor & share-allowance fuzz** — 4 fuzz tests in
  `FuzzCoverage.t.sol` (`FuzzFirstDepositor`) covering rate-invariant
  deposit, multi-depositor drift, withdraw boundary, and zero-share
  boundary cases. Runs at 256 by default; 512 via
  `FOUNDRY_FUZZ_RUNS=512` passes cleanly.
- **ElysiumCoreWriter integration** — new
  `solidity/test/ElysiumCoreWriterIntegration.t.sol` with a
  `FullElysiumCoreWriterMock` (order book, liquidation, margin,
  position state, venue-side validation) + 23 integration tests,
  including cross-tests with `PerpFundingLeg.submitIntent` and
  `BasisHedgeLeg.submitIntent`, and two production simulations
  (`_fallbackSig` rejected by a real venue; expired delegation killed
  at the writer). See `docs/TEST_COVERAGE_GAP.md §5.1`.

---

## 5. Open items (M4 blockers)

The following are known limitations and design deviations that the
auditor should focus on. Each is documented in the repo; none of them
block M3 but all of them are in-scope for M4.

1. **Per-venue notional cap is venue-local, not global.** `TradeOnlyAgent.recordExecution`
   tracks `usedNotional` per `(venue, delegator, keeper, nonce)`; a
   delegation signed once can therefore be used on N venues for a total
   of N × `maxNotional`. Documented in
   `docs/DELEGATION_SPEC.md §9` Q2 as an accepted tradeoff for the
   current single-venue use case. If cross-venue aggregation becomes
   realistic, the verifier needs a global `usedNotional` mapping.

2. **KHYPELeg / SpotStakingLeg rate-tracking (Option A2) — deviation
   from §5 pseudocode.** `docs/DESIGN_KI1_RATE_TRACKING.md §5`
   originally proposed a rate-derived update at `allocateTo`; §11.1
   documents that the pool's `credit` path inverts that relationship
   and that the §5 pseudocode was refined to a balance-delta update
   (Option A2) at round-11. §11.2 documents the rounding tolerance on
   repeated rate moves. §11.3 flags that the real `IStakingPool`
   interface confirmation (does `balanceOf(address, address)` exist
   in the pool's stake-relevant form?) is deferred to mainnet.
   **Auditor focus**: verify the balance-delta invariant holds under
   the real pool's `credit` / `unstake` / `unstake` semantics and
   under the pool's rounding behaviour.

3. **Stream-A dev-fallback gate (`devFallbackEnabled`).** On
   `PerpFundingLeg` and `BasisHedgeLeg`, `_fallbackSig()` is gated by
   the `devFallbackEnabled` bool, currently `true` by default
   (constructor) and mutable via owner `setDevFallbackEnabled`.
   Production must flip it off. This is an **owner-controlled gate
   today and has no governance review**; an auditor should treat it as
   a governance gap, not a leg-level bug. Round-14 test
   `test_CrossPerpFundingLeg_fallbackSig_rejectedByRealVenue` proves
   the venue rejects the fallback sig at the writer even if the leg
   produces it, but the leg still *produces* it when the gate is on.

4. **No live mainnet precompile or predeploy addresses.** Elysium
   testnet only, as of this writing. `HYPERCORE_PRECOMPILE_ADDRESS`
   in `hypeback/hypercore.py` is a placeholder (`0x...C0DE`).
   `ELYSIUM_MAINNET_CHAIN_ID` and `ELYSIUM_TESTNET_CHAIN_ID` are
   unpublished by Kinetiq; the deploy harness uses an internal dry-run
   placeholder (999 is HyperEVM mainnet, not Elysium — the deploy
   script refuses 999). Kinetiq must publish the real IDs and the
   predeploy addresses before M4 mainnet.

5. **Adversarial-review finding #17 comment/code mismatch** — the
   KI-1 comment at `KHYPELeg.sol:125-130` / `SpotStakingLeg.sol:126-130`
   originally described intent the code did not implement. The
   round-11 Option A2 fix rewords the comment. **Auditor focus**:
   verify the current comment matches the current code.

6. **Sharpe ratio model caveat** — the `+3.47% APY median alpha`
   claim is a regime-sweep measurement (25-cell sweep winner,
   `strong_apr=0.10`, `rebalance_hours=720`, 15 seeds, 100% positive,
   15,750h HyperCore funding history). The simulator's Sharpe reflects
   its own lognormal return series and does not include basis risk,
   kHYPE depeg risk, bridge/sequencer halt risk, real HyperCore
   microstructure, or liquidation cascades. The email draft is
   framed as a complementary regime-aware layer, not a standalone
   alpha claim.

---

## 6. Verification commands

Reproduce a clean build from scratch:

```bash
# From the repo root (clone this repo first)
export PATH="$PATH:/c/Users/helpy/.foundry/bin"

# Compile all Solidity
forge build

# Run the full forge test suite (297 tests, 23 suites; round-23)
forge test

# Run the aggregator invariant campaign (3 invariants)
forge invariant

# Run the external verifier (0 FAIL expected)
python ~/Downloads/check_repo.py .
```

Expected outcomes:

- `forge build` — 0 errors, 0 warnings.
- `forge test` — 297/297 pass, 23 suites.
- `forge invariant` — AggInvariantTest passes with 3 invariants
  (shareValueBounded, weightsSumTo10000, noDoubleCounting).
- `check_repo.py` — 0 FAIL.

Python dev tooling (out of audit scope but should still work):

```bash
# From the repo root
python -m hypeback sanity                # invariant checks
python -m hypeback gate --hr 1.0 --lev 3 # kill-gate pre-commit check
```

---

## 7. Repo hygiene

- **Commit history**: 15 waves of work, all committed on the master
  branch. Latest commit: `19efedc` (round-14: last-mile M3 fuzz +
  ElysiumCoreWriter integration).
- **Working tree**: clean. `git status` shows nothing to commit at the
  time this summary is written.
- **External verifier**: `~/Downloads/check_repo.py` (232 lines),
  runs outside the repo and inspects it via a filesystem walk. Not
  committed to the repo.
- **Test-count reconciliation**: the number of tests per suite in §3
  should reconcile against `forge test` output at commit `19efedc`.
  Any drift is a repo-hygiene issue, not a spec issue.
- **No `.env`, no secret files, no credential files** in the tree. The
  deploy harness reads credentials from the environment at runtime;
  they are not committed.

---

## 8. License & IP

- **License**: Apache-2.0, applied to the full repo (Solidity source,
  Python backtester, docs, tests).
- **Reference implementation only.** This repo is a reference
  implementation for the Elysium builder workstream, not a
  production deployment. The four contracts and one delegation
  verifier should be treated as reference-quality, not audited.
- **Not investment advice.** All APY / Sharpe / alpha figures are
  simulation outputs from a synthetic lognormal price path seeded on
  real HyperCore funding history. Real vaults will diverge.
- **Elysium / Kinetiq / HyperCore / HyperEVM / Robinhood Chain** are
  trademarks of their respective owners. The aggregator is a
  third-party consumer of the Elysium precompile + ElysiumCoreWriter
  predeploy stack.

---

## Related documents

- `docs/ROADMAP.md` — build status, milestones, M3 closure record.
- `docs/AGGREGATOR_SPEC.md` — Yield Aggregator architectural spec.
- `docs/DELEGATION_SPEC.md` — Trade-Only-Agent delegation spec (§9
  Q2 documents the venue-local cap limitation).
- `docs/DESIGN_KI1_UNIT_RECONCILE.md` — KI-1 (a) unit-domain
  reconciliation design (§5 pseudocode, §9.2 / §9.4 follow-ups).
- `docs/DESIGN_KI1_RATE_TRACKING.md` — KI-1 (b) rate-tracking
  design (Option A2, §11.1 pseudocode deviation, §11.2 rounding,
  §11.3 real-interface confirmation deferred).
- `docs/DESIGN_KI2_SUBMITINTENT.md` — KI-2 `submitIntent` design
  (Option C, hybrid).
- `docs/DESIGN_KI2B_AGGREGATOR_STREAM_A.md` — KI-2b Phase 2
  aggregator Stream-A refactor design (Option B, off-chain keeper
  signs).
- `docs/TEST_COVERAGE_GAP.md` — test-coverage gap analysis (§5.1
  writer integration coverage).
- `docs/KINETIQ_EMAIL_DRAFT.md` — draft builders-allocation email
  (not sent).
- `README.md` — repo entry point; contract inventory table.

---

*Generated 2026-09-24. This is the auditor's entry point for the M4
audit gate. Nothing here should be deployed to mainnet with real
capital until a formal external audit report is in hand.*
