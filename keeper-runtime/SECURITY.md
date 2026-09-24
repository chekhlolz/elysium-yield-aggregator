# TradeOnlyAgent Keeper — private key handling

The keeper private key is the single highest-impact secret in this system. A
leaked keeper key lets anyone exercise the delegations you have signed until
the delegation expires or you revoke.

This file is the policy. The code is written to enforce it. If you're about to
write code that touches `KeeperWallet.pk`, read this first.

## Threat model

- **What a keeper key can do.** Spend up to `maxNotional` per venue under any
  delegation that names this keeper, up to `maxPerOrder` per trade. That is
  bounded by the delegation, but the bound is chosen by the delegator — and
  delegation signing and key custody usually live in the same repo / team /
  laptop.
- **What a keeper key cannot do.** Transfer the delegator's tokens directly.
  Call `revoke` on behalf of the delegator. Change the delegator's balances.
  The signature recovers to the keeper address, not to the delegator.
- **What a keeper key does do on compromise.** Keep acting under any
  delegation that is still valid and not revoked. The only universal stop
  button is `revoke(keeper)` called by the delegator, which is a normal
  on-chain transaction the delegator must submit.

## Where the key lives

Order of preference, highest to lowest:

1. **KMS / HSM** (AWS KMS, GCP KMS, Azure Key Vault, Vault PKI, AWS KMS,
   TSS signing hardware). The keeper process calls an HTTP signing endpoint
   and never sees the private key bytes. **This is the target for production.**
2. **Hardware wallet** (Ledger, Safe-T, X1). Keeper signs in a
   hardware-mediated session; the pk never touches the OS. Good for
   semi-production.
3. **Keystore file** (encrypted at rest, decrypted in-process only). A
   `keystore.json` with a passphrase from a secrets manager. The keeper
   decrypts at boot and holds the pk in memory for the process lifetime.
4. **`.env` file** (this repo's default). Gitignored, world-unreadable
   (`chmod 600`), read once at startup and never re-read. **This is
   appropriate for local development only.**

The `KEEPER_PK` env var in `.env` is fine for local testing with the Hardhat
#0 dev key. It is not fine for real funds.

## Invariants the code enforces

- **Never log the private key.** No code path logs `pk`. `KeeperWallet`
  exposes only `address`, never the key material.
- **Never write the key to disk.** The keeper does not persist pk to a
  file, cache, or log. `KeeperWallet.pk` is held in a class-private
  field and never assigned anywhere else.
- **Never put the key in a URL, query string, or error message.** Error
  messages and stack traces are scrubbed of anything matching a
  64-hex-char pattern before being reported.
- **Mask addresses in logs.** Anywhere an address appears in a log, use
  `maskAddress(addr)` → `0xf39F…92266`. The full address is reserved for
  debug logs at trace level, never at info.
- **Fail closed on missing config.** If `KEEPER_PK` is absent,
  `ConfigError` is thrown. We do not fall back to a default or generate a
  random key.

## Rotation

- **Scheduled rotation.** Rotate on a calendar (e.g. 90 days). Keep the
  old key until the next rotation window closes.
- **Emergency rotation.** If you suspect the key is compromised:
  1. The delegator submits `revoke(keeper)` on-chain — this immediately
     invalidates all future delegations to that keeper from the same
     delegator. See `TradeOnlyAgent.revoke`.
  2. Deploy a new keeper with a new pk.
  3. Re-issue delegations. Existing delegations signed with the old pk
     are void (revocation is keyed by `(delegator, keeper)`).
- **Never reuse a keeper address for a different team.** Key rotation
  must produce a new address; re-using an address after a compromise
  hides the audit trail.

## Rate limits

Rate limits are not a substitute for revocation, but they cap blast
radius during an incident:

- `MAX_TXS_PER_MINUTE` — client-side limiter; enforced by
  `KeeperWallet`. Default: 60. The keeper refuses to submit a revoke or
  a delegation-sign request if the budget is exhausted.
- `MAX_DELEGATIONS_PER_HOUR` — soft cap on how many distinct delegations
  a single keeper may sign per hour. Useful against runaway signing
  loops. Not yet implemented; add in Phase 3.

Rate limits live in `.env` because they are operational, not secret.
Bumping them is a config change; the code does not change.

## Incidents

If you suspect compromise:

1. **Pause venues.** Do not rely on `revoke` as the only mitigation if
   the delegator's key is also suspected — venue-side pause is the
   stronger action.
2. **Rotate the keeper pk** before doing anything else. Do not wait for
   forensics.
3. **Submit `revoke(keeper)`** from the delegator's signer (not from
   the compromised keeper). `revoke` is a delegator call; the keeper
   cannot self-revoke.
4. **Audit delegations.** Query `TradeOnlyAgent` for outstanding
   delegations named to the old keeper address across every venue;
   verify each is either expired or covered by `revoke`.
5. **Re-issue.** New keeper, new pk, new delegations.

## What we do not do

- We do not encrypt `.env` in the repo. Use a secrets manager.
- We do not commit `.env`, `*.pem`, `*.key`, `keyring-*`, or
  `keystore.json` to this repo. The `.gitignore` blocks them.
- We do not put the pk in a CI/CD secret that also has repo write
  access. Signer secrets and CI secrets are different identities.
- We do not accept pk from stdin or from an HTTP request at runtime.
  The pk is loaded once at boot from a single trusted source.

## Daemon threat model

The keeper daemon (`src/daemon.ts`) is the polling loop that ties the keeper
wallet to a venue. It runs locally on the delegator's machine, not on-chain.
The threat model below complements — and does not replace — the key-handling
policy above.

### Rate limit is defense-in-depth, not a substitute for revoke

`MAX_TXS_PER_MINUTE` caps how many submissions the daemon emits per rolling
60-second window. It is a *soft* control:

- A compromised keeper can still submit up to the cap per minute.
- The cap only bounds blast radius per unit of time; it does not bound
  total notional.
- If the keeper key is leaked, the attacker has the same cap the operator
  does.

The hard stop is `TradeOnlyAgent.revoke(keeper)`, which is called by the
delegator (not the keeper) and immediately invalidates every outstanding
delegation to that keeper. If you suspect compromise, do not rely on the
rate limit; revoke.

### Why nonce monotonicity matters

The venue's used-notional book is keyed by `(delegator, keeper, nonce)`.
A replayed delegation with a reused nonce looks like a re-delivery of an
earlier submission and is silently accepted. The daemon therefore:

- Starts the nonce at `config.nonceSeed` and increments by 1 for every
  submission attempt (accepted or rejected, but not for skipped intents
  that never reached the venue).
- Persists the counter in-memory across `start()`/`stop()` cycles.
- Exposes `getStats().lastNonce` so an operator can persist the counter
  across a process restart (write it to a file, load it on boot).

**Rule:** never restart the daemon with a lower `nonceSeed` than the last
nonce it used. If you lose the counter, revoke the keeper and start fresh
with a new keeper address — do not guess at where to resume.

### TTL as a soft safety net vs revoke as a hard one

The daemon stamps every delegation with `expiresAt = now + ttlSeconds`
(default 300s). This is a soft ceiling: after `expiresAt`, the on-chain
verifier rejects the delegation, so even a stolen signature becomes
useless after five minutes.

- **TTL** caps the window in which a stolen signature is useful.
- **Revoke** caps the set of keepers that can sign at all, retroactively.

TTL is cheap and automatic; revoke is manual and on-chain. Use TTL to
shrink the blast radius of an incident that has already happened; use
revoke to stop the bleeding.

### "Daemon runs locally on the delegator's machine"

The daemon process holds the keeper private key, signs delegations, and
talks to the venue. A compromised host therefore compromises the keeper.
The threat model is:

- **Assume the daemon is not on the operator's laptop.** It runs on a
  dedicated VM, container, or KMS-backed signer service.
- **Assume any host that has the keeper pk is compromised until
  proven otherwise.** The keeper does not distinguish between a
  legitimate operator and a malware instance that loaded the pk.
- **Compromised host = revoke immediately.** Do not wait for forensics.
  Submit `revoke(keeper)` from the delegator's signer, deploy a new
  keeper with a new pk, re-issue delegations.
- **Rate limits and TTLs do not help against a compromised host.** The
  attacker has the same budget as the operator, and can wait out the
  TTL just as easily as the operator can.

The only defense against a compromised host is to shrink the set of
keepers that can act, which is what revoke does. Everything else is
damage control.

## Local development

The `.env.example` ships with the Hardhat dev key `0xac0974…62318`
(Hardhat account #0). This key is:

- Public knowledge (in Hardhat's source).
- Worth $0 on any real chain.
- Safe for local Anvil testing.

**Never** put a real funded key into a repo, a log, or a CI secret.
Test with the Hardhat key; sign production intents with KMS.

## Sign-off checklist (pre-merge)

Before merging a PR that touches `KeeperWallet`, `signing.ts`,
`config.ts`, or any code that reads `KEEPER_PK`:

- [ ] No new `console.log` / `console.error` / logger call references
      `pk` or `.privateKey` or `KEEPER_PK`.
- [ ] No new field on `KeeperWallet` holds the key material in a place
      other than the class-private `pk` field.
- [ ] `address.slice(0,6) + '…' + address.slice(-4)` is used for any
      log output mentioning a keeper or delegator address.
- [ ] `maskAddress` and `maskPk` are used consistently.
- [ ] `ConfigError` is thrown when any required secret is missing.
- [ ] Tests pass without a live `.env` (i.e. the test suite is
      hermetic).
