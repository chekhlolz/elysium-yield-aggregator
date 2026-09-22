"""Deploy hypeback contracts to an EVM RPC endpoint.

Targets:
    Elysium testnet (chainId 99801, placeholder — real ID TBA at launch)
    Elysium mainnet (chain ID published by Kinetiq at mainnet launch)
    Any local Anvil/Hardhat/Foundry node for smoke tests

NOTE on chain IDs: HyperEVM mainnet uses chainId 999. Elysium's own
chain ID is published by Kinetiq at mainnet launch and has NOT been
confirmed yet. The testnet placeholder 99801 is our internal convention
for the dry-run default; production deploys must pass --chain-id
explicitly and verify against the published value.

Requirements:
    pip install web3 py-solc-x
    Set ENV var: DEPLOYER_PK=0x...      (private key)
                RPC_URL=https://...    (or --rpc-url)

Usage:
    python scripts/deploy.py --rpc-url https://testnet-rpc.elysium.kinetiq.xyz
    python scripts/deploy.py --rpc-url http://localhost:8545 --chain-id 31337
    python scripts/deploy.py --dry-run  # build artifacts, don't send tx

Safety:
    - Refuses to deploy to any chain ID other than the testnet placeholder
      without --yes-i-mean-it AND an explicit --chain-id.
    - Explicitly refuses chainId 999 (HyperEVM mainnet) — these contracts
      are designed for Elysium, not HyperEVM.
    - Emits a JSON deployment manifest at output/deployments/<timestamp>.json
      recording chain id, contract addresses, and the tx hashes.

Note: the aggregator constructor requires non-zero leg addresses. For a
skeleton deploy, --leg-addr-1..4 can be passed as placeholder addresses
(leg contracts are deferred; see docs/ROADMAP.md).

Testing:
    `main(argv=..., provider=<web3.Web3>)` accepts both an explicit
    argument list and a pre-built Web3 instance so unit tests can
    inject a mock provider (see tests/mock_provider.py) without ever
    opening a socket. The default code path still builds a real
    `Web3(Web3.HTTPProvider(...))` exactly as before.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

PROJECT_ROOT = Path(__file__).resolve().parent.parent

SOLC_VERSION = "0.8.26"
ELYSIUM_TESTNET_RPC_DEFAULT = "https://testnet-rpc.elysium.kinetiq.xyz"
ELYSIUM_MAINNET_RPC_DEFAULT = "https://rpc.elysium.kinetiq.xyz"
# 99801 is a PLACEHOLDER chain ID, not a confirmed value. Kinetiq's docs
# (elysium.kinetiq.xyz/docs/chain-specifications) say the real chain ID
# will be published at mainnet launch. This value is only used as a
# default in dry-run mode and for the testnet RPC; production deploys
# must pass --chain-id explicitly and verify against Kinetiq's published
# value. Note: 999 is HyperEVM's mainnet chain ID, NOT Elysium's.
ELYSIUM_TESTNET_CHAIN_ID = 99801  # placeholder; verify at launch
HYPEREVM_MAINNET_CHAIN_ID = 999  # HyperEVM, NOT Elysium — refuse deploys here


def _compile_standard(sources: dict) -> dict:
    import solcx
    from packaging.version import Version
    if Version(SOLC_VERSION) not in solcx.get_installed_solc_versions():
        solcx.install_solc(SOLC_VERSION)
    solcx.set_solc_version(SOLC_VERSION)
    return solcx.compile_standard({
        "language": "Solidity",
        "sources": sources,
        "settings": {
            "optimizer": {"enabled": True, "runs": 200},
            "outputSelection": {"*": {"*": ["abi", "evm.bytecode.object"]}},
        },
    })


def _all_sources() -> dict:
    sources = {}
    for p in PROJECT_ROOT.joinpath("src").rglob("*.sol"):
        rel = str(p.relative_to(PROJECT_ROOT)).replace("\\", "/")
        sources[rel] = {"content": p.read_text(encoding="utf-8")}
    return sources


def _find_contract(result: dict, name: str) -> tuple[list, str]:
    """Return (abi, creation_bytecode_hex) for a contract by name."""
    for src, info in result.get("contracts", {}).items():
        for cname, blob in info.items():
            if cname == name:
                return blob["abi"], blob["evm"]["bytecode"]["object"]
    raise RuntimeError(f"contract {name} not found in compile output")


# ---- Cache compile output so we don't recompile for every deploy. ----
_COMPILE_CACHE: dict[str, tuple[list, str]] = {}


def _build_cache():
    global _COMPILE_CACHE
    if _COMPILE_CACHE:
        return
    result = _compile_standard(_all_sources())
    for e in result.get("errors", []):
        if e.get("severity") == "error":
            raise RuntimeError(f"solc error: {e.get('formattedMessage')}")
    _COMPILE_CACHE = {
        "RegimeDetector":   _find_contract(result, "RegimeDetector"),
        "TradeOnlyAgent":   _find_contract(result, "TradeOnlyAgent"),
        "YieldAggregator":  _find_contract(result, "YieldAggregator"),
    }


def _deploy(web3, name: str, abi: list, bytecode_hex: str,
            constructor_args: tuple | None, dry_run: bool) -> dict:
    """Deploy a single contract given pre-compiled abi + bytecode."""
    if not dry_run:
        from web3 import Web3

    if constructor_args:
        data = _encode_constructor(bytecode_hex, abi, constructor_args)
    else:
        data = "0x" + bytecode_hex

    print(f"[{name}] creation data = {len(data) - 2} hex chars ({(len(data) - 2) // 2} bytes)")

    if dry_run:
        return {
            "name": name,
            "address": None,
            "tx_hash": None,
            "creation_data_length": (len(data) - 2) // 2,
            "dry_run": True,
            "abi": abi,
        }

    pk = os.environ.get("DEPLOYER_PK")
    if not pk:
        raise RuntimeError("DEPLOYER_PK env var not set")
    acct = web3.eth.account.from_key(pk)

    nonce = web3.eth.get_transaction_count(acct.address)
    try:
        gas = web3.eth.estimate_gas({"from": acct.address, "data": data})
    except Exception as e:
        print(f"[{name}] gas estimate failed ({e}); using 1_000_000")
        gas = 1_000_000
    gas += int(gas * 0.2)

    tx = {
        "from": acct.address,
        "value": 0,
        "gas": gas,
        "maxFeePerGas": web3.eth.max_priority_fee,
        "maxPriorityFeePerGas": 1 * 10**9,
        "nonce": nonce,
        "chainId": web3.eth.chain_id,
        "data": data,
    }
    signed = acct.sign_transaction(tx)
    raw_tx = getattr(signed, "raw_transaction", None) or getattr(signed, "rawTransaction")
    tx_hash = web3.eth.send_raw_transaction(raw_tx)
    print(f"[{name}] sent tx 0x{tx_hash.hex()}")
    receipt = web3.eth.wait_for_transaction_receipt(tx_hash, timeout=240)
    if receipt.status != 1:
        raise RuntimeError(f"{name} deployment reverted: {receipt}")
    address = receipt.contractAddress
    print(f"[{name}] deployed at {address}")
    return {
        "name": name,
        "address": address,
        "tx_hash": "0x" + tx_hash.hex(),
        "block_number": receipt.blockNumber,
        "gas_used": receipt.gasUsed,
        "chain_id": web3.eth.chain_id,
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }


def _encode_constructor(bytecode_hex: str, abi: list, args: tuple) -> str:
    """Encode the constructor args + append to creation bytecode.

    We handle the aggregator's specific signature manually since we
    don't require web3 for dry-runs:
        (address asset, address keeper, address[4] legs, uint32 timelock, uint16[4] weights)
    """
    if len(args) != 5:
        raise ValueError(f"aggregator constructor expects 5 args, got {len(args)}")
    asset, keeper, legs, timelock, weights = args
    from eth_abi import encode as enc
    payload = enc(
        ["address", "address", "address[4]", "uint32", "uint16[4]"],
        [asset, keeper, list(legs), int(timelock), [int(w) for w in weights]],
    )
    return "0x" + bytecode_hex + payload.hex()


def _build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--rpc-url", default=None)
    ap.add_argument("--chain-id", type=int, default=None)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--out", default=None)
    ap.add_argument("--yes-i-mean-it", action="store_true",
                    help="required for any non-testnet (mainnet) deploy; "
                         "must be paired with an explicit --chain-id")
    ap.add_argument("--asset", default="0x0000000000000000000000000000000000000000",
                    help="ERC-20 asset address for the aggregator")
    ap.add_argument("--keeper", default="0x0000000000000000000000000000000000000000",
                    help="keeper address for the aggregator")
    ap.add_argument("--timelock-seconds", type=int, default=86400)
    ap.add_argument("--weights", default="2000,6000,1500,500",
                    help="initial leg weights in bps, comma-separated (sum=10000)")
    ap.add_argument("--leg-addr", action="append", default=[],
                    help="leg address; pass 4 times for the aggregator")
    return ap


def main(argv: Optional[list] = None, provider=None) -> int:
    """Run the deploy harness.

    Args:
        argv: argument vector for argparse. Defaults to ``sys.argv[1:]``
              so the CLI entry point keeps working as before. Tests can
              pass an explicit list to avoid depending on ``sys.argv``.
        provider: a pre-built ``web3.Web3`` instance to inject. When
              provided, this short-circuits the default
              ``Web3(Web3.HTTPProvider(...))`` construction. This is
              the documented injection point for
              ``tests/mock_provider.py`` — no code changes are needed
              elsewhere in the deploy path.
    """
    args = _build_parser().parse_args(argv)

    rpc = args.rpc_url or os.environ.get("RPC_URL") or ELYSIUM_TESTNET_RPC_DEFAULT
    print(f"RPC: {rpc}")

    _build_cache()

    # Resolve RPC and chain id.
    if args.dry_run:
        chain_id = args.chain_id or ELYSIUM_TESTNET_CHAIN_ID
        web3 = None
    else:
        if provider is not None:
            # Injected Web3 instance (test hook). Do NOT rebuild it.
            web3 = provider
        else:
            from web3 import Web3
            web3 = Web3(Web3.HTTPProvider(rpc, request_kwargs={"timeout": 30}))
        chain_id = args.chain_id or web3.eth.chain_id
        print(f"Connected. chainId={chain_id}")

    # Non-testnet guard. Elysium's mainnet chain ID has not been
    # published as of 2026-09-22 (see docs/AGGREGATOR_SPEC.md).
    # We refuse to deploy to any chain ID other than the testnet
    # placeholder without --yes-i-mean-it AND an explicit --chain-id
    # (so a stale default can't slip through). The HyperEVM mainnet
    # ID 999 is refused outright — these contracts are designed for
    # Elysium, not HyperEVM.
    if chain_id != ELYSIUM_TESTNET_CHAIN_ID:
        if chain_id == HYPEREVM_MAINNET_CHAIN_ID:
            print(f"REFUSING: chainId {chain_id} is HyperEVM mainnet, NOT Elysium. "
                  "These contracts are designed for Elysium. Double-check "
                  "your RPC URL.", file=sys.stderr)
            sys.exit(2)
        if not args.yes_i_mean_it:
            print(f"REFUSING: chainId {chain_id} is not the testnet placeholder "
                  f"({ELYSIUM_TESTNET_CHAIN_ID}). Elysium mainnet chain ID is "
                  "TBA (per Kinetiq docs). Verify against the published value, "
                  "then re-run with --yes-i-mean-it.", file=sys.stderr)
            sys.exit(2)
        if not args.chain_id:
            print(f"REFUSING: chainId {chain_id} was inferred from the RPC. "
                  "Pass --chain-id explicitly to confirm you know which chain "
                  "you're deploying to.", file=sys.stderr)
            sys.exit(2)

    # Parse aggregator args.
    weights = [int(x) for x in args.weights.split(",")]
    if len(weights) != 4 or sum(weights) != 10_000:
        print("Weights must be 4 integers summing to 10000.", file=sys.stderr)
        sys.exit(2)
    if len(args.leg_addr) != 4:
        print("Pass --leg-addr exactly 4 times for the aggregator.", file=sys.stderr)
        sys.exit(2)

    deploys = []
    deploys.append(_deploy(web3, "RegimeDetector", *_COMPILE_CACHE["RegimeDetector"],
                           constructor_args=None, dry_run=args.dry_run))
    deploys.append(_deploy(web3, "TradeOnlyAgent", *_COMPILE_CACHE["TradeOnlyAgent"],
                           constructor_args=None, dry_run=args.dry_run))
    deploys.append(_deploy(web3, "YieldAggregator", *_COMPILE_CACHE["YieldAggregator"],
                           constructor_args=(args.asset, args.keeper, args.leg_addr,
                                             args.timelock_seconds, weights),
                           dry_run=args.dry_run))

    manifest = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "chain_id": chain_id,
        "chainId": chain_id,
        "rpc_url": rpc,
        "dry_run": args.dry_run,
        "asset": args.asset,
        "keeper": args.keeper,
        "timelock_seconds": args.timelock_seconds,
        "timelockSeconds": args.timelock_seconds,
        "weights": weights,
        "leg_addrs": args.leg_addr,
        "contracts": deploys,
        "contractAddresses": [c.get("address") for c in deploys],
    }

    out = args.out or (PROJECT_ROOT / "output" / "deployments" /
                       f"{chain_id}-{int(time.time())}.json")
    out = Path(out)
    out.parent.mkdir(parents=True, exist_ok=True)
    # Strip ABIs from the manifest to keep it small (they're reproducible from solc).
    manifest_out = dict(manifest)
    manifest_out["contracts"] = [
        {k: v for k, v in c.items() if k != "abi"} for c in deploys
    ]
    out.write_text(json.dumps(manifest_out, indent=2), encoding="utf-8")
    print(f"\nDeployment manifest: {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
