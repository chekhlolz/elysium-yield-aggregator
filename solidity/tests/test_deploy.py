"""End-to-end tests for ``solidity/scripts/deploy.py``.

Two families of tests:

1. Dry-run (no network, no provider). Confirms the existing behavior is
   intact: ``_build_cache`` runs, three contracts are encoded, and the
   manifest is written to disk.

2. Non-dry-run against a mock JSON-RPC provider (see
   ``mock_provider.py``). This proves the real deploy path works
   end-to-end — signing, ``estimateGas``, ``sendRawTransaction``,
   ``wait_for_transaction_receipt`` — without ever touching a live
   node. Every ``main()`` call below uses ``--dry-run`` implicitly
   except where noted.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

# ---- Imports under test -------------------------------------------------
SCRIPTS_DIR = Path(__file__).resolve().parent.parent / "scripts"
TESTS_DIR = Path(__file__).resolve().parent
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))
if str(TESTS_DIR) not in sys.path:
    sys.path.insert(0, str(TESTS_DIR))

import deploy  # noqa: E402  (path-manipulated)

# ---- web3 is required for the non-dry-run path -------------------------
try:
    from web3 import Web3  # noqa: E402
    from mock_provider import MockProvider  # noqa: E402
    HAS_WEB3 = True
except ImportError:  # pragma: no cover - environment-dependent
    HAS_WEB3 = False

SKIP_NO_WEB3 = unittest.skipUnless(
    HAS_WEB3,
    "web3 is not installed — install with `pip install web3` to run the "
    "mock-provider deploy tests.",
)

# Well-known test private key (the Hardhat/Anvil account #0). Safe to use
# in tests; never use for real funds.
TEST_PK = "0x4c0883a69102937d6231471b5dbb6204fe5129617082792ae468d01a3f362318"

# Canonical 40-hex-char address check: 0x prefix + 40 hex digits.
ADDR_RE = re.compile(r"^0x[0-9a-fA-F]{40}$")

LEG1 = "0x0000000000000000000000000000000000000001"
LEG2 = "0x0000000000000000000000000000000000000002"
LEG3 = "0x0000000000000000000000000000000000000003"
LEG4 = "0x0000000000000000000000000000000000000004"

BASE_ARGS = [
    "--asset", "0x00000000000000000000000000000000000000A1",
    "--keeper", "0x00000000000000000000000000000000000000A2",
    "--timelock-seconds", "86400",
    "--weights", "2000,6000,1500,500",
    "--leg-addr", LEG1,
    "--leg-addr", LEG2,
    "--leg-addr", LEG3,
    "--leg-addr", LEG4,
]


def _fresh_output_path() -> str:
    """Return a path inside a fresh tempdir — no risk of stomping real output."""
    d = tempfile.mkdtemp(prefix="deploy-test-")
    return str(Path(d) / "manifest.json")


class _DeployTestCase(unittest.TestCase):
    """Shared fixtures: temp output dir + DEPLOYER_PK env var."""

    def setUp(self):
        self._prev_out_dir = tempfile.mkdtemp(prefix="deploy-test-")
        self._prev_pk = os.environ.get("DEPLOYER_PK")
        os.environ["DEPLOYER_PK"] = TEST_PK
        # Silence the compile cache so every test starts clean.
        deploy._COMPILE_CACHE.clear()

    def tearDown(self):
        if self._prev_pk is None:
            os.environ.pop("DEPLOYER_PK", None)
        else:
            os.environ["DEPLOYER_PK"] = self._prev_pk
        shutil.rmtree(self._prev_out_dir, ignore_errors=True)
        deploy._COMPILE_CACHE.clear()


class TestDryRun(_DeployTestCase):
    """Existing behavior: dry-run builds creation data and writes a manifest."""

    def test_dry_run_produces_manifest(self):
        out = _fresh_output_path()
        rc = deploy.main(argv=["--dry-run", *BASE_ARGS, "--out", out])
        self.assertEqual(rc, 0)

        path = Path(out)
        self.assertTrue(path.exists(), f"manifest not written to {out}")
        manifest = json.loads(path.read_text(encoding="utf-8"))

        self.assertTrue(manifest["dry_run"])
        self.assertEqual(manifest["chainId"], 99801)
        self.assertEqual(len(manifest["contracts"]), 3)
        for c in manifest["contracts"]:
            self.assertIn(c["name"], {"RegimeDetector", "TradeOnlyAgent", "YieldAggregator"})
            self.assertIsNone(c["address"])
            self.assertIsNone(c["tx_hash"])
            self.assertGreater(c["creation_data_length"], 0)

        # contractAddresses should list three None entries (nothing deployed).
        self.assertEqual(len(manifest["contractAddresses"]), 3)
        for a in manifest["contractAddresses"]:
            self.assertIsNone(a)


@SKIP_NO_WEB3
class TestMockDeploy(_DeployTestCase):
    """Non-dry-run against the mock provider — exercises the real deploy path."""

    def _run_deploy(self, *, out: str, argv_extra=None, provider=None):
        argv = list(BASE_ARGS)
        if argv_extra:
            argv = argv + argv_extra
        argv.append("--out")
        argv.append(out)
        rc = deploy.main(argv=argv, provider=provider)
        return rc

    def test_mock_deploy_produces_three_contracts(self):
        out = _fresh_output_path()
        provider = MockProvider(chain_id=99801)
        w3 = Web3(provider)

        rc = self._run_deploy(out=out, provider=w3,
                              argv_extra=["--chain-id", "99801"])
        self.assertEqual(rc, 0)

        manifest = json.loads(Path(out).read_text(encoding="utf-8"))

        # Three contract addresses, all well-formed 0x-prefixed 40-hex-char strings.
        addrs = manifest["contractAddresses"]
        self.assertEqual(len(addrs), 3, f"expected 3 contracts, got {len(addrs)}")
        for a in addrs:
            self.assertIsInstance(a, str, f"address {a!r} is not a string")
            self.assertRegex(a, ADDR_RE,
                             f"address {a!r} does not match 0x + 40 hex")

        # Addresses must be distinct (three separate txs, three separate contracts).
        self.assertEqual(len(set(addrs)), 3, "contract addresses should be distinct")

        # Expected manifest top-level fields.
        for field in ("chainId", "asset", "keeper", "timelockSeconds",
                      "weights", "contractAddresses", "contracts",
                      "chain_id", "dry_run", "timestamp", "rpc_url"):
            self.assertIn(field, manifest, f"manifest missing field: {field}")

        self.assertEqual(manifest["chainId"], 99801)
        self.assertEqual(manifest["asset"], "0x00000000000000000000000000000000000000A1")
        self.assertEqual(manifest["keeper"], "0x00000000000000000000000000000000000000A2")
        self.assertEqual(manifest["timelockSeconds"], 86400)
        self.assertEqual(manifest["weights"], [2000, 6000, 1500, 500])
        self.assertFalse(manifest["dry_run"])

        # Contract-level fields.
        self.assertEqual(len(manifest["contracts"]), 3)
        for c in manifest["contracts"]:
            self.assertIn(c["name"], {"RegimeDetector", "TradeOnlyAgent", "YieldAggregator"})
            self.assertRegex(c["address"], ADDR_RE)
            self.assertTrue(c["tx_hash"].startswith("0x"))
            self.assertEqual(c["chain_id"], 99801)

        # The mock should have recorded the full RPC trace — 3 txs sent.
        self.assertEqual(len(provider.tx_hashes), 3)
        self.assertEqual(len(provider.calls_for("eth_sendRawTransaction")), 3)
        self.assertEqual(len(provider.calls_for("eth_getTransactionReceipt")), 3)
        # web3 calls eth_chainId on every deploy (account signing, tx
        # encoding, receipt parsing). At least one per deploy; more is fine.
        self.assertGreaterEqual(len(provider.calls_for("eth_chainId")), 3)
        # One estimateGas per deploy.
        self.assertEqual(len(provider.calls_for("eth_estimateGas")), 3)

    def test_manifest_is_written_to_disk(self):
        """The manifest JSON lands at the exact path passed via --out."""
        out = _fresh_output_path()
        provider = MockProvider(chain_id=99801)
        w3 = Web3(provider)

        rc = self._run_deploy(out=out, provider=w3,
                              argv_extra=["--chain-id", "99801"])
        self.assertEqual(rc, 0)

        path = Path(out)
        self.assertTrue(path.is_file(),
                        f"--out path {out} was not created as a file")
        content = path.read_text(encoding="utf-8")
        self.assertGreater(len(content), 100, "manifest appears empty")

        # The file must parse as JSON and be a dict at the top level.
        parsed = json.loads(content)
        self.assertIsInstance(parsed, dict)
        # Round-trip serialization: re-serializing and re-parsing is stable.
        self.assertEqual(json.loads(json.dumps(parsed)), parsed)


@SKIP_NO_WEB3
class TestRefusalGuards(_DeployTestCase):
    """Safety guards: mainnet deploys require --yes-i-mean-it."""

    def test_chain_id_999_requires_yes_flag(self):
        out = _fresh_output_path()
        provider = MockProvider(chain_id=999)
        w3 = Web3(provider)

        argv = list(BASE_ARGS) + [
            "--chain-id", "999",
            "--out", out,
        ]
        with self.assertRaises(SystemExit) as ctx:
            deploy.main(argv=argv, provider=w3)
        self.assertEqual(ctx.exception.code, 2,
                         "mainnet deploy without --yes-i-mean-it should exit(2)")

        # Nothing was written — the refusal happens before any tx is sent.
        self.assertFalse(Path(out).exists(),
                         "refused deploy must not write a manifest")
        self.assertEqual(provider.tx_hashes, [],
                         "refused deploy must not send any transactions")


if __name__ == "__main__":
    unittest.main()
