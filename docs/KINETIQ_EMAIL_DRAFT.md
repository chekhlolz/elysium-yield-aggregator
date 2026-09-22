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
the ecosystem incentive program. Two products, one shared on-chain primitive.

### Product 1 — Yield Aggregator (ERC-4626 vault on Elysium)

Dynamic allocation across the four HYPE yield sources on HyperCore —
spot staking, kHYPE LST, perp funding, and delta-neutral basis — with
regime-driven switching on the Elysium market-data read precompile.

**Why this matters for Elysium specifically** (not HyperEVM):

- 100–200ms blocks let the vault react to funding regime changes on a
  15-hour negative funding streak (the longest in 15,750 hours of HyperCore
  history). HyperEVM 1s blocks are too slow for this class of strategy.
- The market-data read precompile makes the regime decision on-chain,
  no oracle gas. On HyperEVM this costs a pull per decision.
- ElysiumCoreWriter lets us rebalance between legs in 100–200ms, faster
  than the venue can adapt to our own rebalancing — that's where the alpha
  comes from.

**Kill gate passed** (measured against 15,750 hours of HyperCore funding
history, 2024-12 → 2026-09, before deployment):

| Config | Net APY | Max DD | Sharpe | Liquidated |
|---|---|---|---|---|
| Delta-neutral baseline (HR=1.0, Lev=3) | **13.28%** | 0.23% | 19.67 | no |
| Liminal xHYPE (live competitor, TVL $7.04M) | 14.50% | — | — | — |
| Our Monte-Carlo median edge over Liminal (500 paths) | **+1.41% APY** | 0.44% | 17.56 | 0/500 |
| Aggregator simulator (regime switching, 15 seeds) | **+2.10% APY vs static** | 0.04% | — | 0/15 |

The last row is the aggregator's own alpha vs a static benchmark — a
+2.10% APY lift from regime switching, measured on the real funding
dataset. This is **not yet** enough to beat Liminal's 14.50% on its own;
the aggregator would sit as a delta-neutral floor that occasionally
outperforms a static strategy. We're shipping the alpha we can measure,
not the +3–5% we'd like to claim.

**Solidity reference implementation is compiled** (solc 0.8.26, 0 errors,
0 warnings):

- `YieldAggregator.sol` — ERC-4626 vault, 12.3 KB bytecode, keeper + timelock + open cancelPending
- `RegimeDetector.sol` — market-data precompile adapter, 2.5 KB
- `TradeOnlyAgent.sol` — EIP-712 trade delegation, 2.8 KB
- 3 interfaces (`IYieldAggregator`, `IYieldLeg`, `ITradeOnlyAgent`)
- 4 leg contracts specified but not yet implemented (they implement `IYieldLeg`)

**Dev tooling also in the repo** (open-source, MIT):

- `hypeback/` — Python backtester with 21 unit tests, CLI, web UI
- `hypeback/aggregator.py` — regime-switching simulator (validates the alpha claim)
- `hypeback/hypercore.py` — HTTP client for HyperCore + precompile-ready client stub
- `solidity/scripts/verify.py` — ABI + EIP-712 + event verifier
- `solidity/scripts/deploy.py` — dry-run and live deploy harness

**Repo**: <URL — put GitHub link here once you push>

### Product 2 — Trade-Only-Agent Delegation Protocol

An on-chain standard for scoped, revocable trade delegation. This is the
primitive "trade-only agent" (which Kinetiq uses in the ElysiumCoreWriter
marketing) actually means in code.

- EIP-712 signatures, domain-separated by chainId.
- Delegation: keeper + assetIds + maxNotional + maxPerOrder + expiresAt + nonce + salt.
- Universal revoke: `revoke(keeper)` invalidates all future delegations.
- Portable across venues: any venue implementing the same verifier interface
  accepts the same signature.

Solidity reference implementation compiles: `TradeOnlyAgent.sol`, 2.8 KB
bytecode, EIP-712 type-hash, venue-local notional tracking.

**Repo**: <same URL>

### Why we want builders allocation

Two specific asks, both modest:

1. **Sequencer revenue share for 90 days of TVL** on the Yield Aggregator.
   We're a small team and this funds development through mainnet + the
   4-week precompile window.
2. **Priority access to the market-data precompile** during the
   integration window. We want to be the first external protocol wired to
   the precompile so the docs and integration notes we write during
   integration are useful for the next builder.

Not asking for:
- Launch marketing or co-branding — we'll do our own launch.
- Sequencer exclusivity or any privileged lane — we read the docs, Elysium
  is "no privileged lanes" by design, and we agree with that.
- The ElysiumCoreWriter slot for trade-only-agent — we'd integrate as a
  consumer of the standard, not replace it.

### What we can commit to

- Testnet deployment on chainId 99801 within 2 weeks of precompile landing.
- Full mainnet deployment within 6 weeks of precompile landing.
- Public Foundry test suite for both contracts, in the same repo, before
  mainnet.
- Open-source (MIT), no fee capture beyond standard 10% KNTQ cut through
  HyperCore.

### What we're not promising

- TVL targets. The aggregator only clears a kill gate, not a growth target.
- Audit completion before mainnet. We'll publish a bug bounty and go
  through a third-party audit between testnet and mainnet, but the repo
  will be deployed without a formal audit report in hand.
- **+3–5% alpha over Liminal**. Our measurement is +2.1% over a static
  benchmark. If the regime-switching story is the whole value prop, it's
  thinner than we'd like to advertise.

---

**Repo**: <GitHub URL>
**Docs**: `docs/AGGREGATOR_SPEC.md`, `docs/DELEGATION_SPEC.md`, `docs/ROADMAP.md`
**Backtester**: `hypeback/` in the same repo (open source, stdlib-only Python, 21 unit tests)

We're happy to walk through any of this on a call. Reach out via <handle or email>.

Thanks,
[Your name]

---

## Notes for you before sending

1. **Replace the placeholders** — `<URL>`, `[Your name]`, `<handle or email>`.
2. **Attach or link the repo** before sending. Right now the repo is on
   disk only; it needs to be pushed to a public GitHub (or GitLab, or
   whatever Kinetiq accepts) before the email goes out.
3. **Do not send without pushing first.** Kinetiq will click the link
   before they read the email body. A dead link = dead application.
4. **Tone check.** I wrote this direct, no fluff. If Kinetiq has a
   specific application form or template, mirror that instead of pasting
   this email. The tone ("we can commit / not promising") is honest but
   it assumes Kinetiq reads like an investor, not like a fan.
5. **Alpha claim caveat.** The "+2.10% APY vs static" figure is a
   measurement, not a hypothesis. It's still thin: Liminal has $7.04M
   TVL and 14.50% live APY, so the aggregator needs to either (a) beat
   that on its own, or (b) position itself as a complementary strategy
   (regime-aware layer on top of delta-neutral), not a replacement.
   The email now frames it as (b). If you'd rather frame it as (a),
   you need to run more sim time and find a config that clears Liminal.
6. **Email address.** I don't know Kinetiq's builders contact. Search
   `elysium.kinetiq.xyz` for "builders allocation" — the docs page says
   "Contact the Kinetiq team for integration questions or early access."
   That's a generic contact, not a builders-allocation-specific email.
   You may need to DM on X or reach out via their Discord.
7. **Do not sign with a corporate identity** if you're an individual.
   Sign as yourself. Kinetiq builders programs are for individual and
   small-team builders, not corporates.
8. **Repo state.** The four `IYieldLeg` impl contracts are deferred
   (see `docs/ROADMAP.md §2.1`). The deploy harness ships placeholder
   leg addresses; a real testnet deploy needs those four contracts
   first. If you send the email with "testnet deploy within 2 weeks of
   precompile landing" in it, that's contingent on shipping the legs.
