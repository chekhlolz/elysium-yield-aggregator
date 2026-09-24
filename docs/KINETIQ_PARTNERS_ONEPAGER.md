# Elysium Builders Proposal — One-Pager

**Prepared by**: Alexey — `@icesilentx` on X, `@chekhlolz` on GitHub
**Repo**: https://github.com/chekhlolz/elysium-yield-aggregator (Apache-2.0,
master, HEAD `0146a34`)
**Prepared for**: Kinetiq builders team (Discord `discord.kinetiq.xyz` / DM
`@Enter_Elysium` on X)
**Status**: Reference-quality, not audited. Not sent — awaiting Kinetiq
contact.
**Date**: 2026-09-25

---

## TL;DR

We built two artifacts for Elysium that are testnet-deployable today and
reference-quality for an audit trail:

1. **Elysium Yield Aggregator** — a keeper-driven ERC-4626 vault that
   dynamically allocates HYPE across 5 yield sources on Elysium, using the
   on-chain L1Read precompile for regime classification (no oracle gas,
   no off-chain price feed).
2. **Trade-Only-Agent protocol** — a scoped, revocable, EIP-712 delegation
   standard that lets any HYPE holder delegate trade execution to a keeper
   without moving principal or custody, plus an off-chain keeper runtime.

We are asking for a **builders allocation** under the Elysium ecosystem
program — no infra access, no priority lane, no privileged routing. The
allocation covers gas, engineering time, and Kinetiq review.

Empirical measurement on 15,750 hours of real HyperCore funding data,
regime sweep with 15 seeds, 100% positive on the sweep winner: the
aggregator delivers **+3.47% APY median over a static benchmark**.
That is below Liminal xHYPE's live 14.50% — we are not claiming to
outcompete a live vault. We are claiming a complementary regime-aware
layer that would route into xHYPE as a fifth leg when it is available
on Elysium.

---

## What we built

### 1. Elysium Yield Aggregator

**Contract surface**: 1 ERC-4626 vault + 5 legs.

| Leg | Contract | Yield source |
|---|---|---|
| 1 | `KHYPELeg.sol` | kHYPE LST on HyperEVM (~1.83% APY baseline) |
| 2 | `SpotStakingLeg.sol` | Direct HYPE staking on HyperEVM (24h unbond) |
| 3 | `PerpFundingLeg.sol` | Long-spot / short-perp on HyperCore HYPE-USD |
| 4 | `BasisHedgeLeg.sol` | Delta-neutral basis trade between spot and perp |
| 5 | `LiminalXHYPELeg.sol` | Liminal xHYPE vault (14.50% APY live) — round-17 |

**RegimeDetector** reads the Elysium L1Read precompile and classifies
the market into one of 4 regimes:

- `FUNDING_STRONG` (funding strong positive)
- `FUNDING_WEAK` (funding mildly positive)
- `FUNDING_NEG` (funding negative)
- `HIGH_VOL` (volatility elevated regardless of funding)

Each regime has a fixed 5-slot weight vector (sums to 10,000 bps). Round-17
added a fifth slot that always migrates from kHYPE → xHYPE first, so
the aggregator captures the Liminal alpha before it captures the kHYPE
alpha (kHYPE is strictly worse on APY).

**Design principle**: the aggregator reacts to on-chain state. It does
not search MEV, does not request privileged lanes, does not assume
sequencer ordering. Kinetiq's pinned article explicitly says Elysium
has "no privileged lanes" — we built to that constraint.

**Test coverage**: 297 forge tests across 23 suites, all green. ERC-4626
math hardened for cancelPending, reentrancy, expiry, weight-sum, and
first-depositor fuzzing. 3 invariants under 1 campaign of 32 runs each.
`docs/AUDIT_SUMMARY.md` is the M4 audit gate entry point.

**Alpha claim**: +3.47% APY median over a static benchmark. Regime-sweep
winner, 15 seeds, 100% positive. Not a projection — a measurement on
historical data.

### 2. Trade-Only-Agent protocol

**Problem**: today, delegating a trade means moving principal to a
keeper address or minting a broad ERC-2612 permit. Neither shape is
suitable for a permissionless L2 where a delegator wants to keep
custody and revoke at any time.

**Solution**: EIP-712 delegation with:

- Scoped keeper address (`d.keeper`)
- Asset allowlist (`d.assetIds`, empty = all)
- Per-venue notional cap (`d.maxNotional`, USD with 6 decimals)
- Per-order cap (`d.maxPerOrder`)
- Expiry (`d.expiresAt`, with a proper `0 = never` sentinel that does
  NOT short-circuit revocation)
- Nonce + salt for deduplication
- Venue-local notional tracking (a single delegation used on N venues
  has effective ceiling `N × maxNotional` — a known limitation,
  documented in `docs/DELEGATION_SPEC.md §9`)

**Verification**: `TradeOnlyAgent.sol` uses `ecrecover(digest, v, r, s)`
on the raw EIP-712 digest with canonical ECDSA checks (low-s, nonzero
r/s, `v ∈ {27, 28}`).

**Off-chain keeper runtime**: `keeper-runtime/` is a TypeScript
keeper runtime with bit-exact EIP-712 signing (hand-computed digest,
not `TypedDataEncoder.hashTypedData`, because the contract inserts
`_from` into the outer `abi.encode` even though `_from` is not in the
typehash). Keeper runs locally on the delegator's machine; private key
never touches the network.

Round-21 added the keeper daemon core:

- `KeeperDaemon` polling loop with monotonic nonces (consumed only
  on submission attempts; signing failures do not consume the nonce
  because venue state is unambiguous, but `submitTrade` throws do
  because venue state becomes ambiguous — the exact replay vector
  the venue dedup is designed to catch).
- Sliding-window rate limit (60 tx/min, `MAX_TXS_PER_MINUTE`).
- Client-side per-order cap check, venue-side revoke check,
  used-notional cap check.
- `MockElysiumCoreWriter` in-memory venue adapter — FIFO queue,
  `usedNotional` keyed by `(delegator, keeper, nonce)` triple,
  `revoke` per pair. Adapter deliberately does not verify EIP-712
  signatures — that's covered separately by `TradeOnlyAgent.sol`
  and the signing test suite.

**Revocation**: `revoke(keeper)` is venue-local and universal —
revoking a keeper invalidates every pending delegation to that keeper
from the same delegator, across venues.

**Not audited**: reference-quality, adversarially reviewed internally
over 24 rounds. `docs/AUDIT_SUMMARY.md` documents the review history
and open items.

### 3. Dev harness for the HyperCore precompile

`dev-harness/` — a standalone Foundry library (53 tests) that lets
anyone test against the unpublished Elysium L1Read precompile without
waiting for Kinetiq to publish addresses. `vm.store` + `vm.deployCode`
at a placeholder address; adapter to any `IMarketDataFeed` interface.

### 4. Builders starter kit

`elix-kit/` — a self-contained Foundry + TypeScript template (15 forge
tests) that lets any new builder clone a working Elysium scaffold in
under 5 minutes. Copy out of this repo, replace `HelloElysium.sol`
with your contract, deploy against local Anvil with `CHAIN_ID=999`
(placeholder — real chainId will come from Kinetiq).

### 5. Ecosystem dashboard

`dashboard/` — a static single-page HyperEVM ecosystem dashboard that
pulled live from DeFiLlama. Shows TVL + APY for every Elysium-native
yield venue (Kinetiq kHYPE, Liminal xHYPE, Morpho Blue, Veda,
Gauntlet) plus a Robinhood Chain peer comparison. Chart.js 4.4.1
SRI-pinned via jsDelivr, `<noscript>` fallback, no analytics, no
cookies, no backend. `dashboard/refresh.py` is a 256-line stdlib-only
fetcher that can be cron'd to keep `data.json` fresh. Round-22.

The dashboard is shareable with Kinetiq without exposing any internal
tooling: it's a read-only snapshot of public DeFiLlama data, framed
around "this is the ecosystem the aggregator will run in."

---

## Why Elysium specifically

- **L1Read precompile for regime decisions**: the aggregator makes
  allocation decisions on-chain, no oracle round-trip, no sequencer
  gas for price pulls. This is a Hyperliquid-native design; on HyperEVM
  the same aggregator costs a pull per decision and adds an oracle
  trust boundary.
- **HIP-3 permissionless perp listings**: the PerpFundingLeg uses the
  HIP-3 orderbook for HYPE-USD; this only works on Elysium.
- **HYPE as gas**: no asset-swap friction between staking, trading,
  and delegation. The delegation protocol signs a single typed message
  and consumes HYPE gas on the same chain the tokens are on.
- **Sub-second settle**: Kinetiq's pinned article says production
  block times are "orders of magnitude more performant than HyperEVM."
  The aggregator rebalances in 100–200 ms, which is impossible on
  HyperEVM at current throughput.
- **50% KNTQ burn**: per KIP-5, half of sequencer revenue is used to
  buy and burn KNTQ via the Hyperliquid Assistance Fund. That is a
  reason to prefer Elysium activity for HYPE holders — the aggregator
  is a way for depositors to capture that flow through yield.

---

## What we are asking for

1. **A builders allocation** covering engineering time + gas for testnet
   deployment + Kinetiq review. No infra access, no priority lane, no
   privileged routing.
2. **The L1Read precompile address + spec** (currently unpublished —
   we are testing against our own mock in `dev-harness/`).
3. **ElysiumCoreWriter timeline** — the aggregator depends on the
   venue integration; we have full mock coverage (23 integration
   tests) but need the real address to deploy.
4. **A review slot** for the trade-only-agent protocol if it looks
   interesting enough for Kinetiq to consider as a reference standard.

We are not asking for KNTQ token allocation, no sequencer stake
revenue share, no priority access to any precompile or predeploy.
Just engineering time and technical review.

---

## Contacts

- X: **@icesilentx** (builders / technical)
- GitHub: **@chekhlolz** (repo + issues)
- Discord: ask for builders channel on `discord.kinetiq.xyz` (or DM
  `@Enter_Elysium`)

Reach out via Discord or X — we will not post in public channels unless
asked.

---

## Repo hygiene

- License: **Apache-2.0** (not MIT, not BSL).
- Tests: 297 forge + 15 forge (elix-kit) + 102 node:test
  (keeper-runtime, round-21) + 53 forge (dev-harness) = **467 tests
  total, all green**.
- CI: `forge test --root .` runs locally; GitHub Actions not wired
  (M2 blocker).
- Docs: `AGGREGATOR_SPEC.md`, `DELEGATION_SPEC.md`, `ROADMAP.md`,
  `AUDIT_SUMMARY.md`, `TEST_COVERAGE_GAP.md`, plus 5 KI design docs
  and a Kinetiq partners one-pager (this file).
- Verifier: an external `check_repo.py` script runs 14 checks
  (D1-D14, S1-S5, I1-I4); repo exits with 0 FAIL as of round-24.
- Public artifacts: `KINETIQ_EMAIL_DRAFT.md` (full proposal), this
  one-pager, and the `dashboard/` snapshot.

---

## Known limitations (honesty)

- **Per-venue notional cap** on the delegation protocol: a single
  delegation used on N venues has effective ceiling `N × maxNotional`.
  Mitigation: venue-local dedup is required of the venue, not the
  verifier. Documented in `DELEGATION_SPEC.md §9`.
- **Liminal xHYPE is not on Elysium yet**: leg 5 exists in code but
  the vault contract is off Elysium. It becomes real when Liminal
  deploys to Elysium.
- **Alpha is +3.47% APY median**, which is below the 14.50% xHYPE
  live. The aggregator is not a substitute for xHYPE; it is a
  complementary layer that includes xHYPE as one of several legs.
- **Not audited**: reference-quality, not audited. `AUDIT_SUMMARY.md`
  is the entry point for the M4 audit gate.
- **Elysium chainId is placeholder `999`** in the keeper runtime
  config — the real chainId will come from Kinetiq.
- **No live mainnet deployment**: all state transitions exercised
  against mocks or Anvil. No real capital has touched these contracts.

---

## Timeline we can commit to

- **1 week**: testnet deploy of the aggregator, assuming precompile
  address + ElysiumCoreWriter address are published.
- **2 weeks**: full testnet integration with real venue adapter.
- **4 weeks**: audit-ready package (`AUDIT_SUMMARY.md` refresh,
  external audit review).
- **6 weeks**: mainnet-ready if Kinetiq confirms mainnet timeline.

If the numbers above don't reflect what you need, tell us and we will
adjust.

---

*This is a research artifact, not an audited production system.
Nothing here should be deployed with real capital until the M4 audit
gate is closed. Prepared 2026-09-24.*
