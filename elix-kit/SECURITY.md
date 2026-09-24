# Security

Elysium Builders Starter Kit — threat model summary.

This kit is a **teaching template**, not a production deployment target. It
ships no signing code, no delegated-authorisation primitives, and no keeper
logic. The surface is intentionally small.

## What this kit is NOT

- No delegated-signing code. There is no EIP-712 signer, no TradeOnlyAgent
  verifier, no keeper. That lives in the parent repo
  (`../solidity/src/delegation/`, `../keeper-runtime/`).
- No aggregator logic. The YieldAggregator reference lives in the parent
  repo. `VaultStarter.sol` is a stripped-down ERC-4626 for teaching.
- No third-party runtime dependencies in the Solidity layer. `foundry.toml`
  remaps only `@forge-std` from the local `lib/` checkout.
- No network calls in tests. All tests run offline against Anvil-equivalent
  in-process EVM state.

## What this kit IS

- A trivial contract (`HelloElysium.sol`) for testing the toolchain.
- A minimal ERC-4626 vault (`VaultStarter.sol`) with a single owner-settable
  `targetApyBps` parameter. Explicitly not for production: no fee model, no
  share rounding hardening, no timelock, no governance, no rebalance logic.

## Threat model (short version)

| Attack | Mitigation |
|---|---|
| Deployer key compromise | Use a dedicated deploy key, not a wallet with other funds. |
| `targetApyBps` set to absurd value | Owner-gated, but no range check. In a real vault, add a max cap and timelock. |
| `previewRedeem` used to compute a bad UI | `previewRedeem` and `redemptionRate` use the same integer math; sanity tests pin the arithmetic. |
| Share rounding griefing | Explicitly out of scope — see README gotchas. |
| Supply-chain (deps) | Solidity: single dep (`@forge-std`) checked into `lib/`. TypeScript: `ethers` only. Pin via `package-lock.json` when you ship. |

## Vulnerability reporting

This kit has no delegated-signing logic, so the meaningful security surface
lives in the parent repo. Please report security issues to
`../SECURITY.md` in the aggregator repo (or the parent's public security
contact if it exists). Do not open public issues for security concerns —
email first.

## License

Apache-2.0 — see [LICENSE](./LICENSE).
