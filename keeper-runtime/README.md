# Trade-Only-Agent Keeper Runtime

Off-chain TypeScript service that signs **Stream-A** [TradeOnlyAgent](../solidity/src/delegation/TradeOnlyAgent.sol)
EIP-712 delegations and submits them to venues.

This repo is intentionally minimal and boring: one `keeper-runtime/` package that wraps the
exact digest the Solidity contract computes, so a keeper process can produce signatures that
verify on-chain with zero drift.

> **Security first:** the keeper private key is your worst failure mode. Read
> [SECURITY.md](./SECURITY.md) before touching `.env`.

---

## What this is, and why it exists

The Elysium aggregator runs in two modes:

- **Stream A (short-lived, keeper-signed):** a delegated keeper holds a narrowly-scoped
  delegation (maxNotional, asset allowlist, expiry, nonce) and submits intents to venues on
  behalf of the delegator. This is what `keeper-runtime/` does.
- **Stream B (long-lived, delegator-signed):** the delegator signs directly. This runtime
  also supports it (`from != keeper`) but that path is not the default.

The design contract is `solidity/src/delegation/TradeOnlyAgent.sol`; the human-facing spec is
`../docs/DELEGATION_SPEC.md`. **This runtime is a byte-exact client of that contract**, not a
reimplementation of it.

## Architecture

```
                  ┌─────────────────────────────────────────┐
                  │            keeper-runtime                │
                  │                                          │
   ┌──────────────►│  config.ts   .env → KeeperConfig        │
   │              │     │                                     │
   │              │     ▼                                     │
   │              │  keeper.ts   KeeperWallet                 │
   │              │     │       (pk from .env, never logged) │
   │              │     │         │                           │
   │              │     │         ▼                           │
   │              │     │   signing.ts                        │
   │              │     │       │  EIP-712 digest            │
   │              │     │       │  bit-for-bit == contract   │
   │              │     │       ▼                            │
   │              │     │   Signature {v, r, s}              │
   │              │     ▼                                    │
   │              │  mock-venue.ts                           │
   │              │     │   verify offline / on Anvil       │
   │              │     │   track usedNotional (in-memory)  │
   │              │     ▼                                    │
   │              │   (real venue adapter, later phase)     │
   │              └─────────────────────────────────────────┘
   │
   ▼
   TradeOnlyAgent.sol on Anvil / HyperEVM L2
     .isValidDelegation(from, d, sig) → ecrecover(...)
```

## Setup

Requirements: Node.js 20+ (dev target is Node 24), npm 11+.

```bash
cd keeper-runtime
cp .env.example .env          # then edit AGENT_ADDRESS to your deployment
npm install
npm run typecheck             # strict TS, no emit
npm test                      # vitest-style node:test suite
npm run build                 # emits dist/
npm run example               # offline demo, no Anvil needed
```

## EIP-712 correctness

The contract computes (paraphrased):

```solidity
digestStruct = keccak256(abi.encode(
    from,
    DELEGATION_TYPEHASH,
    d.keeper,
    keccak256(abi.encode(d.assetIds)),   // <-- dynamic array, see below
    d.maxNotional,
    d.maxPerOrder,
    d.expiresAt,
    d.nonce,
    d.salt
));

digest = keccak256(abi.encodePacked(
    "\x19\x01",
    domainSeparator,                       // keccak256(abi.encode(
    digestStruct                           //   keccak256(DOMAIN_TYPE),
));                                        //   keccak256("TradeOnlyAgent v1"),
                                          //   keccak256("1"),
                                          //   block.chainid,
                                          //   address(this)));
```

`src/signing.ts` reproduces this exactly. Two things that matter bit-for-bit:

1. **`assetIds` encoding.** Solidity's `abi.encode` of a dynamic `uint256[]` writes a
   32-byte length prefix followed by each element padded to 32 bytes. An **empty**
   array encodes to a single zero word, so
   `keccak256(abi.encode(uint256[](0))) = keccak256(bytes32(0))`. The runtime mirrors
   this: empty arrays produce `keccak256(0x0000…0000)`.
2. **`v` value.** The contract's `_recover` requires `v == 27 || v == 28`. Ethers v6's
   `Wallet.signTypedData` already returns 27/28, so we pass it through; we reject any
   other value defensively.

The test `test/signing.test.ts` recomputes the digest **manually on JS** — no
`SignTypedData` API — and asserts the hand-rolled digest matches
`TypedDataEncoder.hashTypedData`. That is the guard against silent drift.

## Configuration

All runtime inputs come from `.env` (or the environment when running in a container).
The template lives at [.env.example](.env.example) and is checked in; the real `.env` is
gitignored.

| Variable | Required | Notes |
|---|---|---|
| `CHAIN_ID` | yes | Number; `999` for local Anvil-HyperEVM. |
| `RPC_URL` | yes | JSON-RPC endpoint. |
| `KEEPER_PK` | yes | 32-byte hex, with or without a leading `0x`. Never logged. |
| `DELEGATOR_ADDRESS` | yes | The address whose delegations we sign. |
| `AGENT_ADDRESS` | yes | Deployed `TradeOnlyAgent`. Used as `verifyingContract`. |
| `AGGREGATOR_ADDRESS` | no | `YieldAggregator`; used by venue adapters. |
| `WATCH_INTERVAL_MS` | no | Poll interval; default 1000. |
| `MAX_TXS_PER_MINUTE` | no | Rate limit; enforced client-side. |

## Running the example

`npm run example` runs an end-to-end flow **offline** (no Anvil, no RPC):

1. Load `.env`, construct a `KeeperWallet` (or a fresh random wallet when no pk is
   set, so the example still runs on a clean clone).
2. Build a small delegation: `maxNotional = 1e6` (1 USD in 6-decimal units),
   `maxPerOrder = 1e5`, `expiresAt = now + 60s`, random nonce and salt.
3. Sign it, print the digest and signature.
4. Verify the signature offline using `ethers.verifyTypedData`.

Nothing leaves the machine. It exists so a contributor can eyeball a valid delegation in
two minutes.

## Testing

`npm test` uses the built-in Node test runner (`node:test`) via `tsx`. The suite is
small and fast:

- `test/signing.test.ts` — recomputes the EIP-712 digest by hand in JS and asserts it
  matches `TypedDataEncoder.hashTypedData` for a range of inputs including empty
  `assetIds`, huge `assetIds`, and `expiresAt = 0` (the never-expires sentinel).
- `test/keeper.test.ts` — wallet construction, address derivation, secret-masking
  invariants, and the `revoke` transaction builder (mocked provider, no network).
- `test/daemon.test.ts` — polling loop lifecycle, monotonic nonces, sliding-window
  rate limit (via a `Date.now` freeze helper — node:test ships no fake timers),
  venue rejection and exception handling.
- `test/venue-adapter.test.ts` — MockElysiumCoreWriter behaviour: FIFO queue,
  used-notional accumulation, revoke, pre-populated state.

There is deliberately no integration test against a live Anvil here; that arrives with
the venue adapter work. The correctness contract that matters (bit-for-bit digest)
is tested offline.

## Running the daemon

The daemon is the polling loop that signs delegations and submits them to a venue.
It is fully offline — the mock venue adapter keeps all state in memory.

```ts
import { KeeperDaemon, KeeperWallet, MockElysiumCoreWriter } from 'keeper-runtime';

const keeper = new KeeperWallet(process.env.KEEPER_PK!);
const venue = new MockElysiumCoreWriter({
  pendingIntents: [
    { delegator: '0xf39F…2266', assetId: 1n, side: 'Long', size: 100n, notionalUsd: 1_000_000n },
  ],
});
const daemon = new KeeperDaemon(keeper, venue, '0xf39F…2266', {
  domain: { name: 'TradeOnlyAgent v1', version: '1', chainId: 999n, verifyingContract: AGENT },
  watchIntervalMs: 1000, maxTxsPerMinute: 60, ttlSeconds: 300,
  onEvent: (e) => console.log(e.type, e.nonce, e.result?.accepted),
});
await daemon.start();
```

See `SECURITY.md` for the daemon threat model.

## Roadmap

- [x] Phase 1 (this): types, signing, keeper wallet, tests, docs.
- [ ] Phase 2: venue adapter that calls `YieldAggregator.submitIntent`.
- [ ] Phase 3: multi-venue fan-out with rate limits and per-venue cap tracking.
- [ ] Phase 4: KMS / hardware-wallet signer backend.

## References

- [`../docs/DELEGATION_SPEC.md`](../docs/DELEGATION_SPEC.md) — the spec this runtime implements.
- [`../solidity/src/delegation/TradeOnlyAgent.sol`](../solidity/src/delegation/TradeOnlyAgent.sol) —
  the on-chain verifier; the single source of truth for the digest.
- [`../solidity/src/aggregator/YieldAggregator.sol`](../solidity/src/aggregator/YieldAggregator.sol) —
  the venue-side consumer.
- [`SECURITY.md`](./SECURITY.md) — key handling, rotation, incident response.

## License

MIT.
