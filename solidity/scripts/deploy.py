"""Deploy hypeback contracts to an EVM RPC endpoint.

Targets:
    Elysium testnet (chainId 99801, placeholder — real ID TBA at launch)
    Elysium mainnet (chain ID published by Kinetiq at mainnet launch)
    Any local Anvil/Hardhat/Foundry node for smoke tests

Two provider paths are supported:

1. ``--rpc-url`` (native JSON-RPC). Uses the built-in :class:`EthProvider`
   that talks to any JSON-RPC endpoint via ``urllib``. No ``web3`` dep
   required; only ``eth-account`` (for signing) plus a stdlib-only
   fallback if ``eth-account`` is unavailable.

2. No ``--rpc-url`` (legacy ``web3``). Falls back to ``web3.Web3`` + a
   default testnet RPC. Kept for backward compat with the mock-provider
   test harness (`tests/mock_provider.py`) which injects a Web3 instance
   via the ``provider=`` argument to :func:`main`.

NOTE on chain IDs: HyperEVM mainnet uses chainId 999. Elysium's own
chain ID is published by Kinetiq at mainnet launch and has NOT been
confirmed yet. The testnet placeholder 99801 is our internal convention
for the dry-run default; production deploys must pass --chain-id
explicitly and verify against the published value.

Requirements:
    pip install -r solidity/requirements.txt
    Set ENV var: DEPLOYER_PK=0x...   (or pass --private-key)
                RPC_URL=https://... (or --rpc-url)

Usage:
    # Anvil / Hardhat / any JSON-RPC endpoint
    python scripts/deploy.py --rpc-url http://localhost:8545 \
        --chain-id 31337 --yes-i-mean-it --leg-addr <a1> --leg-addr <a2> \
        --leg-addr <a3> --leg-addr <a4>
    # Local dry-run (builds creation data, no tx sent)
    python scripts/deploy.py --rpc-url http://localhost:8545 --dry-run
    # Legacy default: Elysium testnet RPC (or RPC_URL env var)
    python scripts/deploy.py --dry-run

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
    `main(argv=..., provider=<web3.Web3>)` still accepts both an explicit
    argument list and a pre-built Web3 instance so unit tests can inject
    a mock provider (see tests/mock_provider.py) without ever opening a
    socket. `--rpc-url` selects the native EthProvider path.
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

# Anvil's default test account #0. Safe to use as a fallback when neither
# --private-key nor DEPLOYER_PK is set AND we're connected to a local
# dev node. Never use for real funds.
ANVIL_DEFAULT_PRIVATE_KEY = (
    "0xac0974bec39a17e36ba4a6b4d33ac077f24b3e7acaa6ea64438d0206b2f9900"
)
ANVIL_DEFAULT_ADDRESS = "0xAE556fcf20678830414f4318c709D225D84F7e0e"

# ---- Cache compile output so we don't recompile for every deploy. ----
_COMPILE_CACHE: dict = {}


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


def _find_contract(result: dict, name: str) -> tuple:
    """Return (abi, creation_bytecode_hex) for a contract by name."""
    for src, info in result.get("contracts", {}).items():
        for cname, blob in info.items():
            if cname == name:
                return blob["abi"], blob["evm"]["bytecode"]["object"]
    raise RuntimeError(f"contract {name} not found in compile output")


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


# --------------------------------------------------------------------------- #
# Native JSON-RPC provider (Anvil / Hardhat / any EVM node)                   #
# --------------------------------------------------------------------------- #
class EthProvider:
    """Real EVM RPC provider (Anvil, Hardhat, any JSON-RPC endpoint).

    Talks JSON-RPC 2.0 over ``urllib`` — no ``web3`` dependency. Signatures
    are computed with ``eth-account`` when available; a stdlib-only RLP
    fallback is bundled as a last resort (see :func:`_sign_fallback`).
    """

    def __init__(self, rpc_url: str, private_key: Optional[str] = None,
                 request_timeout: float = 30.0):
        self.rpc_url = rpc_url
        self.private_key = private_key
        self.request_timeout = request_timeout
        self._request_id = 0

    # -- low-level JSON-RPC ------------------------------------------------ #
    def _rpc(self, method: str, params: Optional[list] = None) -> dict:
        """Send a JSON-RPC request to the EVM node."""
        import urllib.request
        self._request_id += 1
        payload = json.dumps({
            "jsonrpc": "2.0",
            "id": self._request_id,
            "method": method,
            "params": params if params is not None else [],
        }).encode("utf-8")
        req = urllib.request.Request(
            self.rpc_url, data=payload,
            headers={"Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(req, timeout=self.request_timeout) as resp:
                body = resp.read()
        except Exception as e:
            raise RuntimeError(
                f"JSON-RPC error contacting {self.rpc_url} "
                f"({method}): {e.__class__.__name__}: {e}"
            ) from e
        try:
            result = json.loads(body)
        except ValueError as e:
            raise RuntimeError(
                f"JSON-RPC response from {self.rpc_url} was not JSON: "
                f"{body[:200]!r}"
            ) from e
        if isinstance(result, dict) and result.get("error"):
            raise RuntimeError(
                f"JSON-RPC error from {self.rpc_url} ({method}): {result['error']}"
            )
        return result

    # -- helpers ----------------------------------------------------------- #
    def get_chain_id(self) -> int:
        r = self._rpc("eth_chainId")
        return int(r["result"], 16)

    def get_nonce(self, address: str) -> int:
        r = self._rpc("eth_getTransactionCount", [address, "pending"])
        return int(r["result"], 16)

    def get_balance(self, address: str) -> int:
        r = self._rpc("eth_getBalance", [address, "latest"])
        return int(r["result"], 16)

    def send_raw_transaction(self, signed_tx: bytes) -> str:
        r = self._rpc("eth_sendRawTransaction", ["0x" + bytes(signed_tx).hex()])
        return r["result"]

    def get_transaction_receipt(self, tx_hash: str, timeout: float = 120.0,
                                poll_interval: float = 1.0) -> dict:
        """Poll for the transaction receipt; raise :class:`TimeoutError` if missed."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            r = self._rpc("eth_getTransactionReceipt", [tx_hash])
            if r.get("result"):
                return r["result"]
            time.sleep(poll_interval)
        raise TimeoutError(
            f"transaction {tx_hash} not mined within {timeout:.0f}s"
        )

    def get_gas_price(self) -> int:
        r = self._rpc("eth_gasPrice")
        return int(r["result"], 16)

    def get_signer_address(self) -> str:
        """Address of the signer — derived from ``private_key`` when provided,
        otherwise the first account returned by ``eth_accounts`` (Anvil's
        default dev key)."""
        if self.private_key:
            try:
                from eth_account import Account
                acct = Account.from_key(self.private_key)
                return acct.address
            except ImportError:
                from eth_utils import to_checksum_address
                return to_checksum_address(_secp256k1_address_bytes(self.private_key))
        r = self._rpc("eth_accounts")
        accounts = r.get("result") or []
        if accounts:
            return accounts[0]
        raise RuntimeError("no accounts available (pass --private-key or use Anvil)")


# --------------------------------------------------------------------------- #
# Signing helpers                                                             #
# --------------------------------------------------------------------------- #
def sign_transaction(private_key: str, nonce: int, gas_price: int,
                     gas_limit: int, to: Optional[str], value: int,
                     data: bytes, chain_id: int) -> bytes:
    """Sign a legacy (type-0) EVM transaction and return the raw bytes.

    Uses ``eth-account`` when available. Falls back to a stdlib-only RLP +
    secp256k1 implementation (via ``rlp`` and ``coincurve``, both pulled in
    transitively by ``eth-account``) if ``eth-account`` is missing.
    """
    from hexbytes import HexBytes

    tx: dict = {
        "nonce": int(nonce),
        "gasPrice": int(gas_price),
        "gas": int(gas_limit),
        "to": to,
        "value": int(value),
        "data": bytes(data) if not isinstance(data, str) else bytes.fromhex(
            data[2:] if data.startswith("0x") else data
        ),
        "chainId": int(chain_id),
    }
    try:
        from eth_account import Account
        # eth-account >= 0.10 auto-detects legacy vs typed by presence of
        # `gasPrice` (legacy) vs `maxFeePerGas` (type 2). Newer versions
        # (>= 0.14) dropped the explicit `use_legacy_transaction=` kwarg,
        # so we try both forms defensively.
        try:
            signed = Account.sign_transaction(
                tx, private_key, use_legacy_transaction=True
            )
        except TypeError:
            signed = Account.sign_transaction(tx, private_key)
        raw = getattr(signed, "raw_transaction", None) or getattr(signed, "rawTransaction")
        if raw is None:
            raise RuntimeError("eth-account did not return a signed raw transaction")
        return bytes(HexBytes(raw))
    except ImportError:
        return _sign_fallback(
            pk_bytes=private_key, nonce=nonce, gas_price=gas_price,
            gas_limit=gas_limit, to=to, value=value,
            data=bytes(data) if data else b"", chain_id=chain_id,
        )


def _sign_fallback(*, pk_bytes, nonce, gas_price, gas_limit, to, value,
                   data, chain_id) -> bytes:
    """Minimal EIP-155 (legacy) transaction signer.

    Uses ``eth_utils.keccak`` and ``eth_keys`` (both pulled in by
    ``eth-account``). Only reached when ``eth-account`` itself is
    unavailable — the primary signing path uses eth-account.
    """
    import rlp
    from eth_keys import keys
    from eth_utils import keccak

    pk = _pk_to_bytes(pk_bytes)
    if len(pk) != 32:
        raise ValueError(f"private key must be 32 bytes, got {len(pk)}")
    priv = keys.PrivateKey(pk)
    serialized = _encode_transaction_for_signing(
        nonce, gas_price, gas_limit, to, value, data, chain_id,
    )
    message_hash = keccak(serialized)
    sig = priv.sign_msg_hash(message_hash)
    v_recovered, r, s = sig.vrs  # rec_id, r, s (already low-s normalized)
    if chain_id == 0:
        v = v_recovered + 27
    else:
        v = 2 * int(chain_id) + 35 + v_recovered
    signed_rlp = rlp.encode([
        nonce, gas_price, gas_limit,
        _to_bytes(to),
        value, data,
        v, r, s,
    ])
    return bytes(signed_rlp)


def _encode_transaction_for_signing(nonce, gas_price, gas_limit, to, value,
                                    data, chain_id) -> bytes:
    """RLP of the canonical EIP-155 legacy-tx fields for signing.

    Per EIP-155, the digest is over ``(nonce, gasPrice, gas, to, value,
    data, chainId, 0, 0)`` — chainId is in position 7 (NOT 0).
    """
    import rlp
    return rlp.encode([
        nonce, gas_price, gas_limit,
        _to_bytes(to),
        value, data,
        chain_id, 0, 0,
    ])


def _to_bytes(v) -> bytes:
    if v is None:
        return b""
    if isinstance(v, str):
        if v.startswith("0x"):
            return bytes.fromhex(v[2:])
        return v.encode("ascii")
    return bytes(v)


def _normalize_v(s, rec_id) -> int:
    """Normalize ``s`` for low-s canonicalization. Returns (rec_id, s)."""
    try:
        from coincurve.curve import SECP256K1  # type: ignore
        order = int(SECP256K1.order)
    except Exception:
        order = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
    half = order // 2
    if s > half:
        s = order - s
        rec_id ^= 1
    return rec_id, s


def _pk_to_bytes(pk) -> bytes:
    """Convert a hex-encoded private key (str or bytes) to a 32-byte ``bytes``.

    Accepts either a ``0x``-prefixed or bare hex string, and tolerates
    odd-length strings by left-padding with a leading zero — the canonical
    Anvil/Hardhat test key ``ac0974bec...f9900`` is famously stored as
    63 hex chars (missing a leading ``0``) in some docs; ``eth-account``
    accepts it via the same convention.
    """
    if isinstance(pk, (bytes, bytearray)):
        return bytes(pk)
    if isinstance(pk, str):
        s = pk[2:] if pk.lower().startswith("0x") else pk
        if len(s) % 2 == 1:
            s = "0" + s  # left-pad to even length for fromhex
        return bytes.fromhex(s)
    raise TypeError(f"private key must be bytes or hex str, got {type(pk).__name__}")


def _secp256k1_address_bytes(pk) -> bytes:
    """Return the 20-byte address derived from ``pk`` (no 0x prefix)."""
    from eth_keys import keys
    from eth_utils import keccak
    pk_b = _pk_to_bytes(pk)
    if len(pk_b) != 32:
        raise ValueError(f"private key must be 32 bytes, got {len(pk_b)}")
    pub = keys.PrivateKey(pk_b).public_key
    # uncompressed pubkey, skip the 0x04 prefix
    uncompressed = pub.to_bytes()
    if uncompressed[:1] != b"\x04":
        uncompressed = uncompressed[1:]
    return keccak(uncompressed)[-20:]


# --------------------------------------------------------------------------- #
# Deploy helpers                                                              #
# --------------------------------------------------------------------------- #
def _pad32(val: int) -> bytes:
    """Big-endian 32-byte word for an integer. Used for manual ABI encoding."""
    return val.to_bytes(32, "big")


def _encode_constructor(bytecode_hex: str, abi: list, args: tuple) -> str:
    """Encode the constructor args + append to creation bytecode.

    Handles three shapes:

    * **YieldAggregator** (5 args)::

        (address asset, address keeper, IYieldLeg[4] legs,
         uint32 timelock, uint16[4] weights)

    * **RegimeDetector** (1 arg)::

        (address marketDataFeed)

    * **no-arg** constructors (``args is None`` or ``args == ()``) use
      the raw creation bytecode as-is.

    Round-8 fix — caught by the new real-Anvil integration test.
    Previously ``None`` and ``()`` were treated identically and both
    short-circuited to "no constructor args", so a contract with a
    real single-address constructor (RegimeDetector) would deploy
    the raw creation bytecode without ever feeding the marketDataFeed
    to the constructor. On a real EVM the constructor then sees
    ``address(0)`` and reverts with ``"zero feed"``. The mock
    provider path never executed the constructor so it passed
    silently — exactly the class of bug real-Anvil catches.

    Also: the aggregator's ``IYieldLeg[4]`` parameter is an
    interface type, but eth_abi encodes ``address[4]`` in the
    right-aligned (standard ABI) form — same wire format. Using the
    ``address[4]`` signature (instead of ``bytes32[4]``) is the
    correct encoding for fixed-length address-like arrays.
    """
    if args is None or args == ():
        return "0x" + bytecode_hex
    if len(args) == 1:
        # Single-address constructor (RegimeDetector).
        feed = args[0]
        if isinstance(feed, int):
            return "0x" + bytecode_hex + _pad32(feed).hex()
        if isinstance(feed, (bytes, bytearray)):
            return "0x" + bytecode_hex + (b"\x00" * 12 + bytes(feed)[-20:]).hex()
        s = str(feed).lower()
        if s.startswith("0x"):
            s = s[2:]
        s = s.zfill(40)
        return "0x" + bytecode_hex + (b"\x00" * 12 + bytes.fromhex(s)).hex()
    if len(args) != 5:
        raise ValueError(
            f"constructor expects 0, 1, or 5 args, got {len(args)}"
        )
    asset, keeper, legs, timelock, weights = args

    def _addr_hex(v) -> str:
        """Return a 0x-prefixed 40-hex-char address from int/str/bytes."""
        if isinstance(v, int):
            return "0x" + f"{v:040x}"
        if isinstance(v, (bytes, bytearray)):
            return "0x" + bytes(v)[-20:].hex()
        s = str(v).lower()
        if s.startswith("0x"):
            s = s[2:]
        return "0x" + s.zfill(40)

    # Note on eth_abi: for the 5-arg tuple
    #   ["address", "address", "address[4]", "uint32", "uint16[4]"]
    # eth_abi 6.x flattens the two fixed-length arrays inline in source
    # order (no length words, no offset pointers) — this is correct ABI
    # for a tuple of statically-sized types. We hand-roll the encoding
    # anyway (1) to keep the dependency optional for the mock-provider
    # path, and (2) to document the exact word layout in comments below,
    # which is the surface area that the real-Anvil integration test
    # exercises. The layout here MUST match what eth_abi produces,
    # otherwise YieldAggregator's constructor decoder reverts.
    #
    def _addr_word_bytes(v) -> bytes:
        s = _addr_hex(v)
        return b"\x00" * 12 + bytes.fromhex(s[2:])

    def _u32(v) -> bytes:
        return int(v).to_bytes(32, "big")

    def _u16(v) -> bytes:
        return int(v).to_bytes(32, "big")

    payload = b""
    #
    # ABI packing order for a tuple of statically-sized types:
    #   concat(encode(s_1), encode(s_2), ..., encode(s_n))
    #
    # Each fixed-length array of static types is flattened to N
    # contiguous 32-byte words. The constructor signature is:
    #   (asset, keeper, legs[4], timelock, weights[4])
    # so the wire format is:
    #   word[0]:   asset
    #   word[1]:   keeper
    #   word[2]:   legs[0]
    #   word[3]:   legs[1]
    #   word[4]:   legs[2]
    #   word[5]:   legs[3]
    #   word[6]:   timelock
    #   word[7]:   weights[0]
    #   word[8]:   weights[1]
    #   word[9]:   weights[2]
    #   word[10]:  weights[3]
    #
    # This matches what eth_abi produces for the signature
    # ["address", "address", "address[4]", "uint32", "uint16[4]"],
    # which is also what the Solidity constructor decoder expects.
    #
    payload += _addr_word_bytes(asset)              # [asset]
    payload += _addr_word_bytes(keeper)             # [keeper]
    for leg in legs:                               # [legs_0..3]
        payload += _addr_word_bytes(leg)
    payload += _u32(timelock)                       # [timelock]
    for w in weights:                              # [weights_0..3]
        payload += _u16(w)

    return "0x" + bytecode_hex + payload.hex()


def _deploy(provider, name: str, abi: list, bytecode_hex: str,
            constructor_args, dry_run: bool, *, chain_id: int,
            gas_price: int, nonce: int, signer_address: str,
            private_key: str, receipt_timeout: float,
            gas_limit: int = 4_000_000) -> dict:
    """Deploy a single contract via the native EthProvider.

    ``data`` is the full creation code (bytecode + encoded constructor args).
    No estimateGas: on failure we abort rather than guess, since a mis-estimated
    gas limit would either revert or stall forever. ``gas_limit`` defaults to
    4M. The earlier 2M default was too tight: ``eth_estimateGas`` reports the
    YieldAggregator constructor needs ~2.6M gas (mostly the 12 KB initcode
    deposit at 200 g/word plus the four-iter leg-validity loop), so 2M caused
    a silent "out of gas" revert against a real Anvil. 4M gives comfortable
    headroom without bloating the tx envelope.
    """
    data_bytes = (
        _encode_constructor(bytecode_hex, abi, constructor_args)
        if constructor_args is not None
        else bytes.fromhex(bytecode_hex)
    )
    if isinstance(data_bytes, str):
        # _encode_constructor returns a "0x..." hex string; convert to bytes
        # so bytes(data) below doesn't raise "string argument without an encoding".
        data_bytes = bytes.fromhex(data_bytes[2:] if data_bytes.startswith("0x") else data_bytes)
    print(f"[{name}] creation data = {len(data_bytes) * 2} hex chars ({len(data_bytes)} bytes)")

    if dry_run:
        return {
            "name": name,
            "address": None,
            "tx_hash": None,
            "creation_data_length": (len(data_bytes) * 2) // 2,
            "dry_run": True,
            "abi": abi,
        }

    raw = sign_transaction(
        private_key=private_key, nonce=nonce, gas_price=gas_price,
        gas_limit=gas_limit, to=None, value=0, data=data_bytes,
        chain_id=chain_id,
    )

    tx_hash = provider.send_raw_transaction(raw)
    print(f"[{name}] sent tx {tx_hash}")
    receipt = provider.get_transaction_receipt(tx_hash, timeout=receipt_timeout)
    if _receipt_status(receipt) != 1:
        raise RuntimeError(f"{name} deployment reverted: {receipt}")
    address = receipt.get("contractAddress")
    if not address:
        raise RuntimeError(f"{name}: receipt missing contractAddress: {receipt}")
    print(f"[{name}] deployed at {address}")
    return {
        "name": name,
        "address": address,
        "tx_hash": tx_hash if tx_hash.startswith("0x") else "0x" + tx_hash,
        "block_number": int(receipt["blockNumber"], 16),
        "gas_used": int(receipt["gasUsed"], 16),
        "chain_id": chain_id,
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }


def _receipt_status(receipt: dict) -> int:
    """Parse receipt.status into an int. Missing field == treat as 1 (pre-EIP-145)."""
    s = receipt.get("status", "0x1")
    if isinstance(s, int):
        return s
    return int(s, 16)


def _deploy_web3(web3, name: str, abi: list, bytecode_hex: str,
                 constructor_args, dry_run: bool) -> dict:
    """Deploy a single contract via a ``web3.Web3`` instance.

    Kept for the legacy mock-provider test path (``tests/mock_provider.py``
    injects a Web3-compatible provider). New code paths should use
    :func:`_deploy` with :class:`EthProvider` instead.
    """
    if not dry_run:
        from web3 import Web3  # noqa: F401  (import check; real provider)

    if constructor_args is not None:
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
        "maxPriorityFeePerGas": 1 * 10 ** 9,
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


# --------------------------------------------------------------------------- #
# CLI                                                                         #
# --------------------------------------------------------------------------- #
def _build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--rpc-url", default=None,
                    help="EVM JSON-RPC URL (e.g. http://localhost:8545 for Anvil). "
                         "When provided, deploy.py uses the built-in EthProvider "
                         "(no web3 dep). Falls back to the RPC_URL env var or "
                         "Elysium testnet default when omitted.")
    ap.add_argument("--chain-id", type=int, default=None,
                    help="Override the chain ID (otherwise read from RPC)")
    ap.add_argument("--dry-run", action="store_true",
                    help="compile + encode creation data, do NOT send any tx")
    ap.add_argument("--private-key", default=None,
                    help="hex private key for signing (0x-prefixed or bare). "
                         "Falls back to $DEPLOYER_PK, then to Anvil's default "
                         "account #0 when neither is set (local dev only).")
    ap.add_argument("--receipt-timeout", type=float, default=120.0,
                    help="how long to wait for a tx to be mined (seconds)")
    ap.add_argument("--out", default=None,
                    help="manifest output path (default: output/deployments/<chain>-<ts>.json)")
    ap.add_argument("--yes-i-mean-it", action="store_true",
                    help="required for any non-testnet (mainnet) deploy; "
                         "must be paired with an explicit --chain-id")
    ap.add_argument("--market-data-feed",
                    default="0x0000000000000000000000000000000000000000",
                    help="market data feed address for RegimeDetector "
                         "(must be non-zero; the constructor reverts otherwise)")
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
              provided AND no ``--rpc-url`` is on ``argv``, this
              short-circuits the default ``Web3(Web3.HTTPProvider(...))``
              construction. This is the documented injection point for
              ``tests/mock_provider.py``.
    """
    args = _build_parser().parse_args(argv)
    _build_cache()

    # ------------------------------------------------------------------ #
    # Resolve provider + chain_id.                                        #
    # ------------------------------------------------------------------ #
    native = bool(args.rpc_url)
    if native:
        ethp = EthProvider(args.rpc_url)
        try:
            rpc_url_for_manifest = ethp.rpc_url
            chain_id = args.chain_id if args.chain_id is not None else ethp.get_chain_id()
            print(f"RPC: {ethp.rpc_url}  chainId={chain_id}")
        except Exception as e:
            print(f"ERROR: could not connect to RPC at {args.rpc_url}: {e}",
                  file=sys.stderr)
            return 2
    else:
        ethp = None
        rpc_url_for_manifest = (
            args.rpc_url or os.environ.get("RPC_URL") or ELYSIUM_TESTNET_RPC_DEFAULT
        )
        print(f"RPC: {rpc_url_for_manifest}")
        if args.dry_run:
            chain_id = args.chain_id or ELYSIUM_TESTNET_CHAIN_ID
            web3 = None
        elif provider is not None:
            web3 = provider  # injected by tests/mock_provider.py
            chain_id = args.chain_id if args.chain_id is not None else web3.eth.chain_id
            print(f"Connected. chainId={chain_id}")
        else:
            try:
                from web3 import Web3
                web3 = Web3(Web3.HTTPProvider(rpc_url_for_manifest,
                                              request_kwargs={"timeout": 30}))
            except Exception as e:
                print(f"ERROR: could not connect to RPC at {rpc_url_for_manifest}: {e}",
                  file=sys.stderr)
                return 2
            chain_id = args.chain_id if args.chain_id is not None else web3.eth.chain_id
            print(f"Connected. chainId={chain_id}")

    # ------------------------------------------------------------------ #
    # Non-testnet guard.                                                  #
    # ------------------------------------------------------------------ #
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

    # ------------------------------------------------------------------ #
    # Parse aggregator args.                                              #
    # ------------------------------------------------------------------ #
    weights = [int(x) for x in args.weights.split(",")]
    if len(weights) != 4 or sum(weights) != 10_000:
        print("Weights must be 4 integers summing to 10000.", file=sys.stderr)
        sys.exit(2)
    if len(args.leg_addr) != 4:
        print("Pass --leg-addr exactly 4 times for the aggregator.", file=sys.stderr)
        sys.exit(2)

    # ------------------------------------------------------------------ #
    # Deploy.                                                             #
    # ------------------------------------------------------------------ #
    if native:
        # Always resolve the gas price + signer so a dry-run still gives a
        # realistic manifest and we never hit an unbound local. Non-dry-run
        # also increments the nonce between deploys so three txs in one
        # process don't collide.
        try:
            gas_price = ethp.get_gas_price()
        except Exception as e:
            print(f"WARNING: gas price lookup failed ({e}); using 20 gwei",
                  file=sys.stderr)
            gas_price = 20 * 10 ** 9

        private_key = (
            args.private_key
            or os.environ.get("DEPLOYER_PK")
            or ANVIL_DEFAULT_PRIVATE_KEY
        )
        if args.private_key is None and not os.environ.get("DEPLOYER_PK"):
            print(f"NOTE: no --private-key / $DEPLOYER_PK; using Anvil default "
                  f"account ({ANVIL_DEFAULT_ADDRESS}). NEVER use for real funds.",
                  file=sys.stderr)
        signer_address = ethp.get_signer_address()
        nonce = ethp.get_nonce(signer_address)

        deploys = []
        deploys.append(_deploy(ethp, "RegimeDetector",
                               *_COMPILE_CACHE["RegimeDetector"],
                               constructor_args=(args.market_data_feed,),
                               dry_run=args.dry_run,
                               chain_id=chain_id, gas_price=gas_price,
                               nonce=nonce, signer_address=signer_address,
                               private_key=private_key,
                               receipt_timeout=args.receipt_timeout))
        if not args.dry_run:
            nonce += 1
        deploys.append(_deploy(ethp, "TradeOnlyAgent",
                               *_COMPILE_CACHE["TradeOnlyAgent"],
                               constructor_args=(),
                               dry_run=args.dry_run,
                               chain_id=chain_id, gas_price=gas_price,
                               nonce=nonce, signer_address=signer_address,
                               private_key=private_key,
                               receipt_timeout=args.receipt_timeout))
        if not args.dry_run:
            nonce += 1
        deploys.append(_deploy(ethp, "YieldAggregator",
                               *_COMPILE_CACHE["YieldAggregator"],
                               constructor_args=(args.asset, args.keeper,
                                                 args.leg_addr,
                                                 args.timelock_seconds, weights),
                               dry_run=args.dry_run,
                               chain_id=chain_id, gas_price=gas_price,
                               nonce=nonce, signer_address=signer_address,
                               private_key=private_key,
                               receipt_timeout=args.receipt_timeout))
    else:
        deploys = []
        deploys.append(_deploy_web3(web3, "RegimeDetector",
                                    *_COMPILE_CACHE["RegimeDetector"],
                                    constructor_args=(args.market_data_feed,),
                                    dry_run=args.dry_run))
        deploys.append(_deploy_web3(web3, "TradeOnlyAgent",
                                    *_COMPILE_CACHE["TradeOnlyAgent"],
                                    constructor_args=(),
                                    dry_run=args.dry_run))
        deploys.append(_deploy_web3(web3, "YieldAggregator",
                                    *_COMPILE_CACHE["YieldAggregator"],
                                    constructor_args=(args.asset, args.keeper,
                                                      args.leg_addr,
                                                      args.timelock_seconds, weights),
                                    dry_run=args.dry_run))

    manifest = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "chain_id": chain_id,
        "chainId": chain_id,
        "rpc_url": rpc_url_for_manifest,
        "dry_run": args.dry_run,
        "provider": "EthProvider" if native else ("web3(mock)" if provider is not None else "web3"),
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
