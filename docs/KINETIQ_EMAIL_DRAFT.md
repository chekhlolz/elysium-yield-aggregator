# Draft email to Kinetiq — builders allocation

**To**: Kinetiq builders team (email TBD — see notes below)
**From**: [Your name], HYPE/Elysium builder
**Subject**: Elysium Yield Aggregator + Trade-Only-Agent Protocol — proposal for builders allocation

> Status: **DRAFT, NOT SENT.**
> Read through and adjust before sending. I did not and will not send on
> your behalf without explicit approval — this is external communication.

---

## Subject line

Requesting builders allocation — Elysium Yield Aggregator (dynamic HYPE yield router) and Trade-Only-Agent delegation protocol

## Body

Hi Kinetiq team,

We're building on Elysium and want to apply for a builders allocation under
the ecosystem incentive program. Two products, one Elysium integration,
both at testnet-deployable shape today.

### Product 1 — Yield Aggregator (ERC-4626 vault on Elysium)

Dynamic allocation across four HYPE yield sources — spot staking, kHYPE
LST, perp funding, and delta-neutral basis — spanning HyperEVM and
HyperCore, with regime-driven switching on the Elysium market-data
precompile.

**Why this matters for Elysium specifically** (not HyperEVM):

- The market-data precompile makes the regime decision on-chain, no
  oracle gas, no sequencer round-trip to a price feed. On HyperEVM this
  costs a pull per decision and an oracle trust boundary.
- ElysiumCoreWriter lets us rebalance between legs in 100–200 ms. The
  alpha we measure is small (see below) but the sub-second settle time
  is what makes the keeper's allocation decisions observable to the
  market before they settle — that's where the slippage delta comes from
  on the fast-regime side of the spectrum.
- Kinetiq's "no privileged lanes" fee-market design means the aggregator
  can react without depending on a privileged sequencer relationship;
  the strategy is portable to anyone with a wallet.

The aggregator is Elysium-native by design, but the same architecture
works on HyperEVM or Robinhood Chain — we're choosing Elysium because
the market-data precompile + ElysiumCoreWriter stack shortens the
keeper's decision loop in a way no other chain does.

**Empirical alpha, measured not projected**:

- Regime-aware layer, complementary to — not replacing — a static
  delta-neutral floor.
- **+3.47% APY median vs static** on a 25-cell regime sweep
  (`strong_apr=0.10`, `rebalance_hours=720`), 15 seeds, 100% positive.
- Measured on 15,750 hours of HyperCore funding history (2024-12 →
  2026-09). Sharpe is computed inside our simulator and reflects the
  model's own return series; it does not include basis risk, kHYPE
  depeg risk, bridge/sequencer halt risk, real HyperCore microstructure
  (latency, slippage, queue position), or liquidation cascades under
  correlated moves. Useful for comparing our configs against each
  other, not for portfolio-level risk assessment.

We are **not** claiming this beats a live delta-neutral product on its
own. The honest framing is: a complementary regime-aware layer that
sometimes beats a static strategy by ~3.47% APY in simulation, and we
ship exactly that measurement.

**Solidity reference implementation is compiled** (solc 0.8.26, 0
errors, 0 warnings):

- 7 Solidity contracts totaling **~61.7 KB** of deployed bytecode
  across 21 Solidity artifacts (contracts + interfaces + lib).
- `YieldAggregator.sol` — ERC-4626 vault, keeper + timelock (owner or
  keeper-only `cancelPending`), Stream-A delegation signing with a
  dev-fallback gate.
- `RegimeDetector.sol` — market-data precompile adapter, hardened
  against hostile feeds (int64 saturation, basis underflow, zero-oracle
  prices).
- `TradeOnlyAgent.sol` — EIP-712 trade delegation with canonical
  ECDSA recovery (rejects non-canonical `s` values).
- Four leg contracts: `KHYPELeg`, `SpotStakingLeg`, `PerpFundingLeg`,
  `BasisHedgeLeg` — all four `IYieldLeg`-compliant, all four wired to
  mock-friendly dependency interfaces.
- 10 interfaces in `solidity/src/interfaces/` (14 with `IERC20Minimal`
  and `IMarketDataFeed`).

**Dev tooling also in the repo** (open-source, Apache-2.0):

- `hypeback/` — Python backtester with unit tests, CLI, web UI.
- `hypeback/aggregator.py` — regime-switching simulator (validates the
  alpha claim).
- `hypeback/hypercore.py` — HTTP client for HyperCore + precompile-ready
  client stub.
- `solidity/scripts/verify.py` — ABI + EIP-712 + event verifier.
- `solidity/scripts/deploy.py` — dry-run and live deploy harness with
  real Anvil integration.

**Repo**: <URL — put GitHub link here once you push>

### Product 2 — Trade-Only-Agent Delegation Protocol

An on-chain standard for scoped, revocable trade delegation. This is the
primitive "trade-only agent" (which Kinetiq uses in the ElysiumCoreWriter
marketing) actually means in code.

- EIP-712 signatures, domain-separated by chainId, canonical ECDSA
  recovery.
- Delegation: keeper + assetIds + maxNotional + maxPerOrder + expiresAt
  + nonce + salt.
- Universal revoke: `revoke(keeper)` invalidates all future delegations.
- Portable across venues: any venue implementing the same verifier
  interface accepts the same signature.
- `recordExecution` enforces `maxPerOrder` on the venue side so a
  misbehaving venue can't bypass the small-orders-only semantics of a
  single delegation.

Solidity reference implementation compiles: `TradeOnlyAgent.sol`, part
of the 7-contract suite above, EIP-712 type-hash, venue-local notional
tracking.

**Repo**: <same URL>

### Why we want builders allocation

One specific ask:

- **Builders allocation** — the standard Kinetiq builders-allocation
  slot for testnet + mainnet operation. We're a small team, the
  allocation funds the run-up to mainnet, and it lets us commit to a
  real public deployment timeline.

Not asking for:
- Sequencer revenue share or a bespoke fee split — we don't want a
  privileged lane; Elysium's "no privileged lanes" is the right design
  and we agree with it.
- Priority access to the market-data precompile — we'd rather be a peer
  builder and get the integration docs done the same way everyone else
  does.
- Launch marketing or co-branding — we'll do our own launch.
- The ElysiumCoreWriter slot for trade-only-agent — we'd integrate as
  a consumer of the standard, not replace it.

### What we can commit to

- Testnet deployment on the Elysium chain ID Kinetiq publishes at
  launch, within 2 weeks of precompile landing — **conditional on us
  receiving the market-data precompile address + ABI and the
  ElysiumCoreWriter predeploy address from Kinetiq**, both of which
  are still unpublished. We'll confirm the 2-week commit once those
  are published.
- Full mainnet deployment within 6 weeks of precompile landing.
- Public Foundry test suite for both contracts, in the same repo,
  before mainnet.
- Open-source (Apache-2.0). We will not add any fee on top of
  HyperCore's standard trading fees or sequencer fees.

### What we're not promising

- TVL targets. The aggregator only clears a kill gate, not a growth
  target.
- Audit completion before mainnet. We'll publish a bug bounty and go
  through a third-party audit between testnet and mainnet, but the
  repo is **reference-quality, not audited** — it will be deployed
  without a formal audit report in hand.
- **+3–5% alpha over any live delta-neutral product**. Our measurement
  is +3.47% over a static benchmark (regime sweep, 15 seeds,
  15,750h history, 100% positive). That's the whole delta the model
  currently produces on the best-tuned config. The aggregator is a
  complementary regime-aware layer on top of delta-neutral, not a
  standalone alpha generator that outperforms a live product.

### Current repo state (in case this saves you a link)

- 212 forge tests green across 17 suites.
- `forge invariant` passing on 3 aggregator invariants.
- External verifier (`check_repo.py`) at 0 FAIL.
- Milestone M3 (testnet-deployable aggregator with adversarial security
  review) closed; M4 (audit gate) is the only remaining milestone.
- 8 known issues from an earlier adversarial review (KI-1 through
  KI-8) plus several additional round-9 red-team fixes all closed with
  design docs + implementation + tests.
- Commit history: 15 waves of work, all committed, no uncommitted
  changes.

---

**Repo**: <GitHub URL>
**Docs**: `docs/AGGREGATOR_SPEC.md`, `docs/DELEGATION_SPEC.md`,
`docs/ROADMAP.md`
**Backtester**: `hypeback/` in the same repo (open source, stdlib-only
Python)

We're happy to walk through any of this on a call. Reach out via
<handle or email>.

Thanks,
[Your name]

---

## Notes for you before sending

1. **Replace the placeholders** — `<URL>`, `[Your name]`, `<handle or
   email>`.
2. **Attach or link the repo** before sending. Right now the repo is
   on disk only; it needs to be pushed to a public GitHub (or GitLab,
   or whatever Kinetiq accepts) before the email goes out.
3. **Do not send without pushing first.** Kinetiq will click the link
   before they read the email body. A dead link = dead application.
4. **Tone check.** I wrote this direct, no fluff. If Kinetiq has a
   specific application form or template, mirror that instead of
   pasting this email. The tone ("we can commit / not promising") is
   honest but it assumes Kinetiq reads like an investor, not like a
   fan.
5. **Alpha claim caveat.** The "+3.47% APY vs static" figure is a
   measurement (25-cell sweep winner, 15 seeds, 100% positive,
   15,750h history). It's a regime-sweep median, not a projection.
   The email frames it as a complementary layer, not a standalone
   alpha claim — keep that framing. If you'd rather frame it as a
   direct outperformer of a live delta-neutral product, you need to
   run more sim time and find a config that clears one; the current
   numbers don't support that claim.
6. **Audit framing.** The email says "reference-quality, not
   audited." Do not soften that language. We don't have a formal
   audit report, and we shouldn't imply we do. The M3 milestone is
   about *testnet-deployable aggregator with adversarial security
   review*, not about passing an external audit.
7. **Kill gate note.** The email intentionally drops the old
   "kill gate passed" table that included a live product's TVL and
   APY — those numbers age badly and we don't need a comparison
   anchor to make the ask. If Kinetiq asks for a performance table
   on a call, offer the sweep results; don't lead with a comparison
   to a live product we haven't beaten.
8. **Email address.** I don't know Kinetiq's builders contact.
   Search `elysium.kinetiq.xyz` for "builders allocation" — the
   docs page says "Contact the Kinetiq team for integration questions
   or early access." That's a generic contact, not a
   builders-allocation-specific email. You may need to DM on X or
   reach out via their Discord.
9. **Do not sign with a corporate identity** if you're an individual.
   Sign as yourself. Kinetiq builders programs are for individual and
   small-team builders, not corporates.
10. **Repo state.** All four `IYieldLeg` impl contracts, the
    aggregator, and the delegation verifier are shipped and green.
    The ElysiumCoreWriter predeploy integration is covered by a full
    mock + 23 integration tests, but the real predeploy address
    still needs to be published by Kinetiq. The 2-week testnet commit
    is contingent on that address landing.
11. **License.** The repo is Apache-2.0 (reference implementation).
    Do not accidentally say MIT in the email — that was the earlier
    draft's license and it's stale.
