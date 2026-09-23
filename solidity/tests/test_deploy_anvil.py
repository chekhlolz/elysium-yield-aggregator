"""Integration tests for ``solidity/scripts/deploy.py`` against a live Anvil.

These tests are skipped when Anvil is not reachable, so CI without a local
node can run the rest of the suite cleanly.

Prerequisites (any one of):
    anvil  --port 8545                    # default Anvil
    hardhat node --port 8545              # Hardhat
    cast node --port 8545                 # Foundry's node mode
    # ...then this test module auto-detects at port 8545 and runs.

    ANVIL_URL=http://localhost:8545 python -m unittest solidity.tests.test_deploy_anvil
    # ...or point at a different endpoint.

Every test starts from a pristine chain via ``anvil_reset`` (or the
equivalent Hardhat ``evm_setNextBlockTimestamp`` reset trick — we use
``anvil_reset`` because that's what Anvil exposes by default). If the node
doesn't support ``anvil_reset`` the test is skipped rather than failing.
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
import urllib.error
import urllib.request
from pathlib import Path
from typing import Optional

# ---- Imports under test -------------------------------------------------
SCRIPTS_DIR = Path(__file__).resolve().parent.parent / "scripts"
TESTS_DIR = Path(__file__).resolve().parent
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))
if str(TESTS_DIR) not in sys.path:
    sys.path.insert(0, str(TESTS_DIR))

import deploy  # noqa: E402  (path-manipulated)


DEFAULT_ANVIL_URL = "http://localhost:8545"
ANVIL_URL = os.environ.get("ANVIL_URL", DEFAULT_ANVIL_URL)


def _rpc_available(url: str) -> bool:
    """Cheap liveness probe — returns True iff eth_chainId succeeds."""
    try:
        req = urllib.request.Request(
            url,
            data=json.dumps({
                "jsonrpc": "2.0", "id": 1,
                "method": "eth_chainId", "params": [],
            }).encode("utf-8"),
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=2) as resp:
            body = json.loads(resp.read())
        return isinstance(body, dict) and "result" in body and not body.get("error")
    except (urllib.error.URLError, OSError, TimeoutError, ValueError,
            json.JSONDecodeError):
        return False


ANVIL_REACHABLE = _rpc_available(ANVIL_URL)


def _supports_anvil_reset(url: str) -> bool:
    """Probe for ``anvil_reset`` (or ``hardhat_reset``). Returns bool."""
    for method in ("anvil_reset", "hardhat_reset"):
        try:
            req = urllib.request.Request(
                url,
                data=json.dumps({
                    "jsonrpc": "2.0", "id": 1,
                    "method": method, "params": [],
                }).encode("utf-8"),
                headers={"Content-Type": "application/json"},
            )
            with urllib.request.urlopen(req, timeout=3) as resp:
                body = json.loads(resp.read())
            if isinstance(body, dict) and "error" in body:
                continue  # method rejected; try next
            return True
        except (urllib.error.URLError, OSError, TimeoutError, ValueError):
            continue
    return False


CAN_RESET = _supports_anvil_reset(ANVIL_URL)


@unittest.skipUnless(
    ANVIL_REACHABLE,
    f"no EVM JSON-RPC endpoint reachable at {ANVIL_URL} — start Anvil "
    f"(anvil --port 8545) or set ANVIL_URL to point at one.",
)
class TestAnvilDeploy(unittest.TestCase):
    """Real end-to-end deploy against a live Anvil node."""

    LEGS = [
        "0x0000000000000000000000000000000000000001",
        "0x0000000000000000000000000000000000000002",
        "0x0000000000000000000000000000000000000003",
        "0x0000000000000000000000000000000000000004",
    ]

    # Anvil chain id is 31337 by default; the deploy guardrails require
    # --chain-id + --yes-i-mean-it for any non-testnet chain. We pass
    # both so the deploy guard lets this through (this IS a dev node).
    CHAIN_ID = 31337

    def setUp(self):
        # Probe/reset only when a test actually mutates chain state. Tests
        # that only read (chain_id, accounts, sign_transaction) don't need
        # it — so a read-only node still passes them.
        if self._needs_reset():
            if not CAN_RESET:
                self.skipTest(
                    f"node at {ANVIL_URL} does not support anvil_reset; "
                    "this test requires a fresh chain between runs"
                )
            _rpc_call(ANVIL_URL, "anvil_reset") if _has_method(ANVIL_URL, "anvil_reset") \
                else _rpc_call(ANVIL_URL, "hardhat_reset")
        # Deploy the compile cache once per test to keep isolation tight.
        deploy._COMPILE_CACHE.clear()

    def _needs_reset(self) -> bool:
        return self._testMethodName in {
            "test_dry_run_against_anvil",
            "test_full_deploy_against_anvil",
        }

    # ------------------------------------------------------------------ #
    # Tests                                                             #
    # ------------------------------------------------------------------ #
    def test_eth_provider_reports_chain_id(self):
        provider = deploy.EthProvider(ANVIL_URL)
        chain_id = provider.get_chain_id()
        # Anvil defaults to 31337 but we shouldn't hard-code it — just
        # assert it's a positive integer.
        self.assertIsInstance(chain_id, int)
        self.assertGreater(chain_id, 0)

    def test_eth_provider_lists_anvil_accounts(self):
        provider = deploy.EthProvider(ANVIL_URL)
        signer = provider.get_signer_address()
        self.assertRegex(signer, r"^0x[0-9a-fA-F]{40}$")
        balance = provider.get_balance(signer)
        # Anvil's default accounts ship with 10,000 ETH; assert non-zero.
        self.assertGreater(balance, 0)

    def test_sign_transaction_produces_raw_bytes(self):
        provider = deploy.EthProvider(ANVIL_URL)
        pk = deploy.ANVIL_DEFAULT_PRIVATE_KEY
        chain_id = provider.get_chain_id()
        nonce = provider.get_nonce(provider.get_signer_address())
        gas_price = provider.get_gas_price()
        raw = deploy.sign_transaction(
            private_key=pk, nonce=nonce, gas_price=gas_price,
            gas_limit=21000, to=None, value=0,
            data=b"\x60\x80\x60\x40\x52", chain_id=chain_id,
        )
        self.assertIsInstance(raw, (bytes, bytearray))
        self.assertGreater(len(raw), 50, "signed tx is suspiciously small")

    def test_dry_run_against_anvil(self):
        """`--dry-run` reads chain id + gas price from Anvil, no tx sent."""
        out = self._fresh_out()
        rc = deploy.main(argv=[
            "--rpc-url", ANVIL_URL,
            "--chain-id", str(self.CHAIN_ID),
            "--yes-i-mean-it",  # ANVIL chain id != ELYSIUM_TESTNET_CHAIN_ID
            "--dry-run",
            "--asset", "0x00000000000000000000000000000000000000A1",
            "--keeper", "0x00000000000000000000000000000000000000A2",
            "--timelock-seconds", "86400",
            "--weights", "2000,6000,1500,500",
            *([x for leg in self.LEGS for x in ("--leg-addr", leg)]),
            "--out", out,
        ])
        self.assertEqual(rc, 0)
        manifest = json.loads(Path(out).read_text(encoding="utf-8"))
        self.assertTrue(manifest["dry_run"])
        self.assertEqual(manifest["chainId"], self.CHAIN_ID)
        self.assertEqual(len(manifest["contracts"]), 3)
        for c in manifest["contracts"]:
            self.assertIsNone(c["address"])
            self.assertIsNone(c["tx_hash"])
            self.assertGreater(c["creation_data_length"], 0)
        self.assertEqual(manifest["provider"], "EthProvider")

    def test_full_deploy_against_anvil(self):
        """Full three-contract deploy to Anvil via eth_sendRawTransaction."""
        out = self._fresh_out()
        rc = deploy.main(argv=[
            "--rpc-url", ANVIL_URL,
            "--chain-id", str(self.CHAIN_ID),
            "--yes-i-mean-it",  # CHAIN_ID != ELYSIUM_TESTNET_CHAIN_ID
            "--asset", "0x00000000000000000000000000000000000000A1",
            "--keeper", "0x00000000000000000000000000000000000000A2",
            "--timelock-seconds", "86400",
            "--weights", "2000,6000,1500,500",
            *([x for leg in self.LEGS for x in ("--leg-addr", leg)]),
            "--receipt-timeout", "60",
            "--out", out,
        ])
        self.assertEqual(rc, 0)
        manifest = json.loads(Path(out).read_text(encoding="utf-8"))
        addrs = manifest["contractAddresses"]
        self.assertEqual(len(addrs), 3, f"expected 3 contracts, got {len(addrs)}")
        for a in addrs:
            self.assertRegex(a, r"^0x[0-9a-fA-F]{40}$",
                             f"address {a!r} is malformed")
        self.assertEqual(len(set(addrs)), 3, "addresses must be distinct")
        for c in manifest["contracts"]:
            self.assertRegex(c["tx_hash"], r"^0x[0-9a-f]{64}$")
            self.assertEqual(c["chain_id"], self.CHAIN_ID)
            self.assertGreater(c["gas_used"], 0)
            self.assertGreater(c["block_number"], 0)
        self.assertEqual(manifest["provider"], "EthProvider")

    def test_mainnet_refusal_guard_still_applies(self):
        """The 999-HyperEVM guard must still fire even with --rpc-url."""
        out = self._fresh_out()
        with self.assertRaises(SystemExit) as ctx:
            deploy.main(argv=[
                "--rpc-url", ANVIL_URL,
                "--chain-id", "999",
                "--asset", "0x00000000000000000000000000000000000000A1",
                "--keeper", "0x00000000000000000000000000000000000000A2",
                *([x for leg in self.LEGS for x in ("--leg-addr", leg)]),
                "--out", out,
            ])
        self.assertEqual(ctx.exception.code, 2)
        self.assertFalse(Path(out).exists(),
                         "refused deploy must not write a manifest")

    # ------------------------------------------------------------------ #
    # Fixtures                                                          #
    # ------------------------------------------------------------------ #
    def _fresh_out(self) -> str:
        d = tempfile.mkdtemp(prefix="deploy-anvil-test-")
        self.addCleanup(self._cleanup, d)
        return str(Path(d) / "manifest.json")

    @staticmethod
    def _cleanup(path: str) -> None:
        import shutil
        shutil.rmtree(path, ignore_errors=True)


def _rpc_call(url: str, method: str, params: Optional[list] = None) -> dict:
    req = urllib.request.Request(
        url,
        data=json.dumps({
            "jsonrpc": "2.0", "id": 1,
            "method": method, "params": params or [],
        }).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=5) as resp:
        return json.loads(resp.read())


def _has_method(url: str, method: str) -> bool:
    try:
        body = _rpc_call(url, method)
        return isinstance(body, dict) and "error" not in body
    except (urllib.error.URLError, OSError, TimeoutError, ValueError,
            json.JSONDecodeError):
        return False


if __name__ == "__main__":
    unittest.main(verbosity=2)
