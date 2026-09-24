# Security Notes

This repository is a **local development harness**. It is safe by design
and intentionally contains none of the following:

- **No secrets.** No API keys, no tokens, no RPC endpoints with
  credentials. The harness talks only to local Foundry/Anvil state.
- **No RPC URLs with credentials.** No `wss://` or `https://` RPC
  endpoints are hardcoded anywhere in this library. If you need a
  live node, wire it up yourself in your own environment.
- **No private keys.** No `pk`, no `seed`, no `mnemonic`, no
  keystore files. The deployer address used in CREATE2 fixtures is
  the standard `vm.prank()` / Foundry default account from your local
  `ANVIL_ACCOUNT_0` / `PRIVATE_KEY` env (which you set yourself).

## The precompile address is a placeholder

The constant used throughout the harness:

```
0x000000000000000000000000000000000000C0DE
```

...is a **placeholder** that mirrors
`hypeback/hypercore.py::HYPERCORE_PRECOMPILE_ADDRESS`. Kinetiq has
not yet published the real HyperCore market-data precompile address
on Elysium mainnet. When they do, the only places that should change
are:

- `src/IHyperCorePrecompile.sol` (comments only; the constant lives
  in the Python client, not here).
- Any test that hardcodes the address for CREATE2 deployment.

The mock contracts themselves do not depend on the address value.

## Report a real vulnerability

If you find a real issue (data exposure, code execution, etc.), do
not open a public GitHub issue. Contact the hypeback maintainers
directly and reference this file.

## Supply chain

The only external dependency is `@forge-std` (pinned via
`lib/forge-std`). Update it like any other Foundry submodule — run
`forge install foundry-rs/forge-std` and pin the SHA.
