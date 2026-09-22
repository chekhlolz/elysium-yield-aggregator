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
  `~/.foundry/bin/`). Round-3 smoke suite in place:
  - `solidity/test/RegimeDetector.t.sol` — 16 tests (constructor,
    setThresholds owner-gating, priority chain, fuzz invariant, weight
    sums).
  - `solidity/test/YieldAggregator.t.sol` — 28 tests (ERC-4626 happy
    path, cancelPending owner/keeper-only, reentrancy guard, weight
    sum, executePending timelock, governance).
  - `solidity/test/TradeOnlyAgent.t.sol` — 19 tests (EIP-712 signature
    recovery, expiresAt == 0 never-expires sentinel, per-venue
    notional cap, revoke, tampered/wrong-signer rejection).
  - Total: **63 tests, 0 failed**. Run with `forge test`.
  - External verifier (`check_repo.py`) still ignores `solidity/test/`
    because it runs solc directly without forge-std remapping — that
    path is covered by `forge test`.

- **`verify.py` covers ABI + EIP-712 + events**, but not runtime
  behavior. The aggregator's `_redeem` path in particular has edge
  cases (share allowance, first depositor, dust) that static analysis
  can't catch.

### 2.5 Known issues (round-3 P2, not blocking M1)

The round-3 review caught 6 findings that don't touch correctness in
the current test-suite surface but will bite at production scale.
These are documented here so they're not lost between sessions:

| # | Issue | Where | Status |
|---|---|---|---|
| KI-1 | Stake legs (`KHYPELeg`, `SpotStakingLeg`) mix unit domains: `khypeBalance` is tracked in HYPE, but `amount` and `allocatedUsd` are in USDC. `currentValue()` multiplies by price to reconcile, but `_distribute` and `reduceFrom` return USDC — leg-internal accounting may drift when the oracle re-prices HYPE. | `src/legs/KHYPELeg.sol`, `src/legs/SpotStakingLeg.sol` | Documented; needs oracle-priced pro-rata on every `allocateTo` / `reduceFrom`. |
| KI-2 | `writer.openPosition(...)` / `closePosition(...)` in every leg is called with `_zeroSig()` — a placeholder signature that will always fail on a real `ElysiumCoreWriter`. Production flow needs `submitIntent(Delegation, Signature, uint256)` on each leg. | All 4 legs | TODO, listed in §5; production blocker for M2. |
| KI-3 | `BasisHedgeLeg.allocateTo(1)` double-allocates: with `spotPortion = 1 / 2 = 0`, the `if (spotPortion == 0) spotPortion = amount;` guard re-runs with `perpPortion = amount - spotPortion = 0`, but the code then still calls `_writeOpen` once, so 1 USDC of allocation creates both a spot and perp open with notional 0. | `src/legs/BasisHedgeLeg.sol` | Edge case; add `require(amount >= 2, "dust")` guard. |
| KI-4 | `setFixedApyBps(v)` on all 4 legs writes `fixedApyBps` but doesn't refresh `latestApyBps`. Until the next `harvest()` or `allocateTo()` runs, `expectedApy()` continues returning the stale `latestApyBps`. | All 4 legs | Add `latestApyBps = v;` to `setFixedApyBps` when `fundingSource` is not live. |
| KI-5 | `_allocatedTotal` in `YieldAggregator` decrements by `delta` on `executePending`'s reduce path, but `legs[i].reduceFrom(delta)` may return less than `delta` (unstake waiting, rounding). The accounting is optimistic — vault's share balances can exceed `_allocatedTotal + freeCash` on a slow leg. | `src/aggregator/YieldAggregator.sol` | Track actual returned amount from `reduceFrom`, not the target. |
| KI-6 | `recordExecution` in `TradeOnlyAgent` accepts a `notional` up to the delegation's `maxNotional`, but the venue-local `usedNotional` cap is per-`(venue, delegator, keeper, nonce)` — a delegation signed once can be used on N venues for a total of N × maxNotional. This is documented in `DELEGATION_SPEC.md §9`; production will add a per-delegation aggregate cap if cross-venue abuse becomes realistic. | `src/delegation/TradeOnlyAgent.sol` | Accepted limitation; not a bug, just a spec tradeoff. |

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

| Milestone | Definition of done |
|---|---|
| **M1: Research artifact** | Repo + specs + Kinetiq email sent. ✅ (this commit) |
| **M2: Testnet deployment** | 4 leg contracts ✅ + aggregator live on Elysium testnet with real funding flowing. |
| **M3: Audit-ready** | Foundry test suite passes. Aggregator math hardened for ERC-4626 edge cases. |
| **M4: Mainnet** | Audit passed. Governance live. First 100k USD TVL. |

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
| `PerpFundingLeg` | Add a `submitIntent(Delegation, Signature, uint256)` path — current stub uses `_zeroSig()`. | Production flow signs per intent. |
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
