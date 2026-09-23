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
import shutil
import socket
import subprocess
import sys
import tempfile
import time
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


# ---------------------------------------------------------------------------
# Real-Anvil subprocess management
# ---------------------------------------------------------------------------
def _find_anvil():
    """Return the path to the ``anvil`` binary, or None if not on PATH.

    Uses ``shutil.which`` so this works on both POSIX and Windows. The
    TestRealAnvil tests are skipped when None — CI without Foundry falls
    back to the mock-provider path via ``test_deploy.py``.
    """
    return shutil.which("anvil")


ANVIL_BIN = _find_anvil()


def _free_port():
    """Pick a free TCP port on loopback."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _wait_for_rpc(url, timeout=30.0, interval=0.25):
    """Poll the RPC URL until eth_chainId succeeds. Returns True on success."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        if _rpc_available(url):
            return True
        time.sleep(interval)
    return False


class AnvilProcess:
    """Context manager for a spawned Anvil subprocess.

    Usage::

        with AnvilProcess(chain_id=9876) as anvil:
            provider = deploy.EthProvider(anvil.url)
            # ... run tests against provider ...
        # anvil is terminated (even on exception in the body)

    The subprocess is terminated even if the body raises — see
    ``__exit__``. An ``atexit`` hook is a second safety net so a hang
    in cleanup does not leave a zombie anvil process holding a port.

    Real-Anvil gotcha (documented in the test module docstring): Anvil
    1.8.3 does NOT include the classic Hardhat/Anvil default private
    key's address (0xAE556fcf20678830414f4318c709D225D84F7e0e) among
    its dev accounts. It generates a random mnemonic per invocation.
    The deploy harness defaults to ANVIL_DEFAULT_PRIVATE_KEY, so this
    class passes ``--fund-accounts`` to give the classic address ETH.
    Otherwise the first eth_sendRawTransaction fails with
    "Insufficient funds for gas * price".
    """

    def __init__(self, chain_id=9876, port=None, load_state=None,
                 start_timeout=30.0, fund_accounts=None):
        self.chain_id = chain_id
        self.port = port or _free_port()
        self.url = "http://127.0.0.1:%d" % self.port
        self.load_state = load_state
        self.start_timeout = start_timeout
        self.fund_accounts = fund_accounts or {}
        self.proc = None
        self.stderr_text = ""

    def __enter__(self):
        if ANVIL_BIN is None:
            raise RuntimeError("anvil binary not on PATH")
        cmd = [ANVIL_BIN, "--chain-id", str(self.chain_id),
               "--port", str(self.port), "--silent"]
        if self.load_state:
            cmd.extend(["--load-state", str(self.load_state)])
        fund_list = list(self.fund_accounts.items())
        if not fund_list:
            fund_list = [(deploy.ANVIL_DEFAULT_ADDRESS, 10000)]
        for addr, amount in fund_list:
            cmd.extend(["--fund-accounts", "%s:%d" % (addr, amount)])
        try:
            self.proc = subprocess.Popen(
                cmd,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                text=True,
            )
        except FileNotFoundError:
            # Binary vanished between which() and Popen (rare on Windows).
            raise RuntimeError("anvil binary disappeared before spawn")
        import atexit
        atexit.register(self._terminate)
        if not _wait_for_rpc(self.url, timeout=self.start_timeout):
            try:
                if self.proc.stderr:
                    self.stderr_text = self.proc.stderr.read() or ""
            except Exception:
                pass
            self._terminate()
            raise RuntimeError(
                "anvil at %s did not become ready within %gs. stderr: %r"
                % (self.url, self.start_timeout, self.stderr_text)
            )
        return self

    def _terminate(self):
        if self.proc is None:
            return
        try:
            if self.proc.poll() is None:
                self.proc.terminate()
                try:
                    self.proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self.proc.kill()
                    try:
                        self.proc.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        pass
        finally:
            try:
                if self.proc.stderr:
                    self.proc.stderr.close()
            except Exception:
                pass
            self.proc = None

    def __exit__(self, exc_type, exc, tb):
        self._terminate()


REAL_ANVIL_TESTS_SKIP = unittest.skipUnless(
    ANVIL_BIN is not None,
    "anvil binary not on PATH — install Foundry or set PATH to include it. "
    "CI without Anvil still exercises the mock-provider path in "
    "test_deploy.py."
)


class TestRealAnvil(unittest.TestCase):
    """Real end-to-end deploy against a freshly-spawned Anvil subprocess.

    Chain id is 9876 — a synthetic dev ID that is NOT 999 (HyperEVM
    mainnet guard) and NOT the Elysium testnet placeholder (99801).
    The deploy guard therefore lets the deploy proceed with
    --yes-i-mean-it, which is the path the real-anvil integration is
    designed to exercise.
    """

    CHAIN_ID = 9876
    PORT_BASE = 28545

    @staticmethod
    def LEGS():
        return [
            "0x0000000000000000000000000000000000000001",
            "0x0000000000000000000000000000000000000002",
            "0x0000000000000000000000000000000000000003",
            "0x0000000000000000000000000000000000000004",
        ]

    @REAL_ANVIL_TESTS_SKIP
    def test_realAnvil_subprocessSpawnsAndServesRpc(self):
        """AnvilProcess starts a real Anvil and serves eth_chainId."""
        with AnvilProcess(chain_id=self.CHAIN_ID, port=self.PORT_BASE) as anvil:
            provider = deploy.EthProvider(anvil.url)
            self.assertEqual(provider.get_chain_id(), self.CHAIN_ID)
            self.assertGreater(provider.get_gas_price(), 0)
            body = provider._rpc("eth_accounts")
            self.assertGreaterEqual(len(body["result"]), 10)
            self.assertGreater(
                provider.get_balance(deploy.ANVIL_DEFAULT_ADDRESS), 0,
                "classic Anvil default address must have ETH for the deploy"
            )

    @REAL_ANVIL_TESTS_SKIP
    def test_realAnvil_deployThreeContracts(self):
        """Full three-contract deploy to a freshly-spawned Anvil."""
        out = self._fresh_out()
        deploy._COMPILE_CACHE.clear()
        with AnvilProcess(chain_id=self.CHAIN_ID, port=self.PORT_BASE + 1) as anvil:
            rc = deploy.main(argv=[
                "--rpc-url", anvil.url,
                "--chain-id", str(self.CHAIN_ID),
                "--yes-i-mean-it",
                "--market-data-feed", "0x00000000000000000000000000000000000000F1",
                "--asset", "0x00000000000000000000000000000000000000A1",
                "--keeper", "0x00000000000000000000000000000000000000A2",
                "--timelock-seconds", "86400",
                "--weights", "2000,6000,1500,500",
                *([x for leg in self.LEGS() for x in ("--leg-addr", leg)]),
                "--receipt-timeout", "60",
                "--out", out,
            ])
        self.assertEqual(rc, 0, "deploy must succeed against real Anvil")
        manifest = json.loads(Path(out).read_text(encoding="utf-8"))
        self.assertEqual(manifest["chainId"], self.CHAIN_ID)
        self.assertEqual(len(manifest["contractAddresses"]), 3)
        for c in manifest["contracts"]:
            self.assertEqual(c["chain_id"], self.CHAIN_ID)
            self.assertRegex(c["tx_hash"], r"^0x[0-9a-f]{64}$")
            self.assertGreater(c["gas_used"], 0)
            self.assertGreater(c["block_number"], 0)
        self.assertEqual(manifest["provider"], "EthProvider")

    @REAL_ANVIL_TESTS_SKIP
    def test_realAnvil_happyPath(self):
        """End-to-end smoke: deploy, then verify state via eth_call.

        Deploys YieldAggregator against a freshly-spawned Anvil, then
        reads back ``asset()``, ``keeper()``, and ``timelockSeconds()``
        via raw ``eth_call`` to confirm the constructor actually stored
        the passed arguments. This is the ground-truth check for
        deploy.py's ``_encode_constructor`` — a bug there would show
        up as wrong return values from these read-only calls.
        """
        out = self._fresh_out()
        deploy._COMPILE_CACHE.clear()
        asset_addr = "0x00000000000000000000000000000000000000A1"
        keeper_addr = "0x00000000000000000000000000000000000000A2"
        timelock = 86400
        with AnvilProcess(chain_id=self.CHAIN_ID, port=self.PORT_BASE + 2) as anvil:
            provider = deploy.EthProvider(anvil.url)
            rc = deploy.main(argv=[
                "--rpc-url", anvil.url,
                "--chain-id", str(self.CHAIN_ID),
                "--yes-i-mean-it",
                "--market-data-feed", "0x00000000000000000000000000000000000000F1",
                "--asset", asset_addr,
                "--keeper", keeper_addr,
                "--timelock-seconds", str(timelock),
                "--weights", "2000,6000,1500,500",
                *([x for leg in self.LEGS() for x in ("--leg-addr", leg)]),
                "--receipt-timeout", "60",
                "--out", out,
            ])
            self.assertEqual(rc, 0, "deploy must succeed")
            manifest = json.loads(Path(out).read_text(encoding="utf-8"))
            addrs = manifest["contractAddresses"]
            self.assertEqual(len(addrs), 3)
            for a in addrs:
                self.assertRegex(a, r"^0x[0-9a-fA-F]{40}$")
                self.assertNotEqual(a.lower(),
                                    "0x0000000000000000000000000000000000000000")
            for c in manifest["contracts"]:
                self.assertGreater(c.get("gas_used", 0), 0,
                                  "deploy tx should have used gas")

            # Read back the aggregator's state via eth_call.
            # NOTE: this MUST happen inside the AnvilProcess context —
            # once the `with` block exits, the subprocess is terminated
            # and any eth_call against it raises ConnectionRefusedError.
            agg_addr = addrs[2]  # third = aggregator
            result = self._call_view(provider, agg_addr, "0x38d52e0f")
            self.assertEqual(result[-40:].lower(), asset_addr.lower()[-40:],
                             "asset() must return the passed asset address")
            result = self._call_view(provider, agg_addr, "0xaced1661")
            self.assertEqual(result[-40:].lower(), keeper_addr.lower()[-40:],
                             "keeper() must return the passed keeper address")
            result = self._call_view(provider, agg_addr, "0x65a1f3c3")
            self.assertEqual(int(result, 16), timelock,
                             "timelockSeconds() must return the passed value")

    @REAL_ANVIL_TESTS_SKIP
    def test_realAnvil_refusalGuardStillApplies(self):
        """Even against a real Anvil subprocess, chainId=999 is refused."""
        out = self._fresh_out()
        deploy._COMPILE_CACHE.clear()
        port = self.PORT_BASE + 3
        with AnvilProcess(chain_id=999, port=port):
            with self.assertRaises(SystemExit) as ctx:
                deploy.main(argv=[
                    "--rpc-url", "http://127.0.0.1:%d" % port,
                    "--chain-id", "999",
                    "--asset", "0x00000000000000000000000000000000000000A1",
                    "--keeper", "0x00000000000000000000000000000000000000A2",
                    *([x for leg in self.LEGS() for x in ("--leg-addr", leg)]),
                    "--out", out,
                ])
            self.assertEqual(ctx.exception.code, 2)
            self.assertFalse(Path(out).exists(),
                             "refused deploy must not write a manifest")

    @staticmethod
    def _call_view(provider, to, data):
        return provider._rpc("eth_call", [{"to": to, "data": data},
                                          "latest"])["result"]

    def _fresh_out(self):
        d = tempfile.mkdtemp(prefix="deploy-anvil-real-test-")
        self.addCleanup(self._cleanup, d)
        return str(Path(d) / "manifest.json")

    @staticmethod
    def _cleanup(path):
        shutil.rmtree(path, ignore_errors=True)


if __name__ == "__main__":
    unittest.main(verbosity=2)
