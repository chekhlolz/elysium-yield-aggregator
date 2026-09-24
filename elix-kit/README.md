# Elysium Builders Starter Kit

A self-contained template for scaffolding Elysium L2 contracts in
minutes. Copy it out (`git clone hypeback && cd elix-kit`) and start
building on Elysium without hunting through the aggregator's ~20k lines
of Solidity for a working `forge test` scaffold.

Two teaching contracts are included: `HelloElysium.sol` (greet the EVM,
50 LoC) and `VaultStarter.sol` (minimal ERC-4626 vault with a
configurable `targetApyBps`, ~250 LoC). Both are explicitly teaching
contracts — they are not production-ready vaults. See "Common gotchas"
below for the tradeoffs we made.

---

## 1. What this is

The Elysium builder workstream ships two big repos:

- **`hypeback/`** — HYPE delta-neutral vault backtester, Python.
- **`hypeback/solidity/`** — reference aggregator, ~20k LoC of
  production Solidity with a delegated-signing standard, a keeper
  runtime, a Python on-chain simulator, and a docs tree.

This kit is the **scaffold** — the shape a new builder needs to start
shipping their own Elysium contracts. It keeps:

- A Foundry project layout that compiles with Solc 0.8.26, no surprises.
- The two interfaces every Elysium builder will need
  (`IERC20.sol`, `ITradeOnlyAgent.sol`) — copied verbatim from the
  aggregator so a builder does not have to depend on the parent repo
  just to import the delegation standard.
- A minimal TS client (`ElysiumClient`) so builders can deploy via
  ethers without building out an SDK.
- Tests that run **offline** — no Anvil, no RPC, no network calls.

What it does **not** keep:

- Delegated signing / keeper logic. That lives in
  `hypeback/solidity/src/delegation/` and `hypeback/keeper-runtime/`.
- The YieldAggregator reference. That lives in
  `hypeback/solidity/src/aggregator/`.
- The HyperCore market-data harness. That lives in
  `hypeback/dev-harness/`.

If you find yourself needing those, graduate to the parent repo.

---

## 2. Requirements

- **Foundry v1.8.3+** (Solc 0.8.26 is pinned). Install via
  `foundryup`.
- **Node.js 20+** and npm 11+.
- **Elysium RPC** — not published yet. For local development, use an
  Anvil fork with `--chain-id 999` and set `RPC_URL` to
  `http://127.0.0.1:8545`. When Kinetiq publishes the Elysium RPC,
  swap the value.

The Solidity layer has no third-party runtime deps beyond `forge-std`,
which is vendored into `solidity/lib/forge-std/`. The TypeScript layer
has one runtime dep: `ethers ^6.13`.

---

## 3. Quickstart

```bash
# 1. Clone (this kit lives inside hypeback).
git clone <hypeback-url>
cd hypeback/elix-kit

# 2. Run the Solidity tests. Offline.
cd solidity && forge test && cd ..

# 3. Install TypeScript deps and run the client tests.
cd ts && npm install && npm test && cd ..

# 4. Build the Solidity artifacts so the TS client can deploy.
cd solidity && forge build && cd ..

# 5. Deploy the HelloElysium example against local Anvil.
#    (Start `anvil --chain-id 999` first.)
cp ts/.env.example ts/.env
cd ts && npm run example && cd ..
```

Expect ~15 Solidity tests passing and ~10 TypeScript tests passing
in under 30 seconds total.

---

## 4. Repository layout

```
elix-kit/
├── README.md              ← this file
├── LICENSE                ← Apache-2.0
├── SECURITY.md            ← threat model (short)
├── .gitignore
├── solidity/
│   ├── foundry.toml       ← Solc 0.8.26, optimizer 200, fuzz 512
│   ├── remappings.txt     ← @forge-std/=lib/forge-std/src/
│   ├── lib/forge-std/     ← vendored Foundry test framework
│   ├── src/
│   │   ├── interfaces/
│   │   │   ├── IERC20.sol         ← copied verbatim from parent
│   │   │   └── ITradeOnlyAgent.sol ← copied verbatim from parent
│   │   └── examples/
│   │       ├── HelloElysium.sol   ← 50 LoC greeting contract
│   │       └── VaultStarter.sol   ← minimal ERC-4626 vault
│   └── test/
│       ├── HelloElysium.t.sol
│       └── VaultStarter.t.sol
└── ts/
    ├── package.json       ← ethers + vitest only
    ├── tsconfig.json      ← strict, ES2022, Bundler resolution
    ├── .env.example       ← RPC_URL, DEPLOYER_PK (dev key)
    ├── src/
    │   ├── types.ts       ← ABI mirrors + TS interfaces
    │   └── index.ts       ← ElysiumClient
    └── test/
        └── vault.test.ts  ← ABI round-trip tests, offline
```

---

## 5. Elysium specifics

### 5.1 Chain id

Kinetiq has not published the Elysium mainnet chain id. For local
development, use `999` (the Anvil default). Override it via
`CHAIN_ID` in `ts/.env`:

```
CHAIN_ID=999
```

When Kinetiq publishes the value, update this one line. The rest of
the kit is chain-agnostic.

### 5.2 The HyperCore precompile caveat

The HyperCore market-data precompile (which yields
`fundingSnapshot`, `candleSnapshot`, `marketData`) is **not yet
published**. Its ABI and address are both speculative.

The pattern to use: define the precompile interface yourself, put a
**mock** behind it for local dev, and swap the mock for the real
precompile address at deploy time. The aggregator does this in
`hypeback/dev-harness/src/IHyperCorePrecompile.sol` +
`MarketDataFeedAdapter.sol`. This kit does not include the precompile
harness — reach into the parent repo if you need market data in your
contract.

### 5.3 ERC-4626 shape

`VaultStarter.sol` implements the ERC-4626 surface
(`deposit` / `withdraw` / `mint` / `redeem` / `preview*` / `convertTo*`)
but with deliberately simplified share accounting:

- **Linear interest accrual.** `interest = principal * bps * elapsed
  / (10_000 * SECONDS_PER_YEAR)`. No compounding. Real vaults layer
  yield sources that compound on each other; this is teaching-grade.
- **No first-depositor rounding guard.** The classic ERC-4626 dust
  attack (front-run the share rate with a 1 wei deposit) is not
  defended against. Add a minimum first deposit before mainnet.
- **No fees.** No management, no performance. Owner-gated
  `setTargetApyBps` is the only mutation.
- **Immutable owner.** Real vaults should use `Ownable2Step` with a
  timelock so ownership can be transferred without a redeploy.

---

## 6. Deploy checklist

1. **Compile.** `cd solidity && forge build`. Verify no warnings about
   shadowed builtins or unchecked casts.
2. **Fuzz.** `forge test --fuzz-runs 512`. The default 512 runs is a
   sane floor; bump to 1024+ for production.
3. **Read the warnings.** The Solidity linter in Foundry surfaces
   shadowed builtins (e.g., `uint256 now = block.timestamp`). Rename
   them — production auditors will flag these.
4. **Local deploy.** Start Anvil with `anvil --chain-id 999`,
   `cp ts/.env.example ts/.env`, run `npm run example` in `ts/`.
5. **Elysium deploy.** Replace `RPC_URL` with the real Elysium
   endpoint, replace `DEPLOYER_PK` with a dedicated deploy key
   (not your personal wallet, not the dev key), verify with
   `forge verify-contract` (once Etherscan-compatible explorer is
   live).
6. **Post-deploy.** Set `targetApyBps` via
   `vault.setTargetApyBps(1_890)` for ~1.89% APY. Re-read
   `vault.totalAssets()` every block if you are watching live.

---

## 7. Common gotchas

Learned from the aggregator build. These are the traps that cost us
actual work, so they cost you less:

1. **First-depositor rounding in ERC-4626.** The classic attack is to
   front-run the share rate with a 1 wei deposit, which makes the
   exchange rate arbitrarily bad. `VaultStarter.sol` does not defend
   against this. Add a `MIN_FIRST_DEPOSIT` guard before mainnet.
2. **`block.timestamp` shadowing.** Do not write `uint256 now =
   block.timestamp;` — Solidity 0.8.26 warns about shadowing the
   built-in `now`. Use `uint256 ts` or `uint256 nowTs` instead.
3. **Funding rate units.** HyperCore funding rates are 1e6-scaled
   (10000 = 1% per block). RegimeDetector converts to bps
   (`rate / 100`) which is `(rate / 1e6) * 10_000`. Do not mix these
   up — an off-by-100 bug is silent and devastating.
4. **`previewRedeem` is not your UI oracle.** It computes shares
   against the *current* asset rate. Between your preview and your
   `redeem`, the vault may accrue more interest. Compute against
   `totalAssets()` at redeem time, not preview time.
5. **Share balances are not asset balances.** `balanceOf(address)`
   returns shares, not underlying tokens. `convertToAssets(shares)`
   is the way to get the asset value. Mixing these up is the most
   common ERC-4626 UI bug.
6. **`approve(0)` before `approve(N)` on some ERC-20s.** Some legacy
   tokens require zeroing the allowance first when going from a
   non-zero to a different non-zero. `SafeERC20` does not zero first
   — do it manually if you hit this.
7. **Do not put signing keys in `ts/.env` in git.** The dev key is
   fine (it is public), but if you replace it with a real key, check
   `git diff` before committing. The parent's `SECURITY.md` has the
   keeper-key threat model.
8. **`forge test` in the wrong directory.** Run it with `--root` set
   to `solidity/`, not `elix-kit/`. `forge test` from the repo root
   will not find the contracts unless you `cd solidity` first.
9. **Chain id mismatch in EIP-712.** If you eventually add signing
   logic, the chain id baked into the typed-data domain must match
   the chain you are signing against. For Elysium, this is still
   `999` until published. Signing against the wrong chain id produces
   signatures that recover to a different address.
10. **`targetApyBps` is unchecked on write (except `<= 10000`).**
    A malicious owner can still set `targetApyBps = 10_000` (100%
    APY) and drain the vault via `withdraw` after a short warp.
    Add a timelock + max-cap for production.

---

## 8. License

Apache-2.0. See [LICENSE](./LICENSE).

The parent repo (`hypeback/`) is also Apache-2.0. The two
interfaces copied here (`IERC20.sol`, `ITradeOnlyAgent.sol`) carry
their SPDX headers unchanged from the source — both are Apache-2.0.
