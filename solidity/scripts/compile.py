"""Compile all Solidity contracts in this project with solc 0.8.26.

Uses py-solc-x so we don't need solc on the PATH.

Usage:  python scripts/compile.py
Output: prints compile errors if any; zero exit code = all clean.
"""

import os
import sys
import traceback

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCES = [
    "src/interfaces/IYieldLeg.sol",
    "src/interfaces/IYieldAggregator.sol",
    "src/interfaces/ITradeOnlyAgent.sol",
    "src/keeper/RegimeDetector.sol",
    "src/aggregator/YieldAggregator.sol",
    "src/delegation/TradeOnlyAgent.sol",
]
SOLC_VERSION = "0.8.26"


def build_source_map():
    out = {}
    for rel in SOURCES:
        abs_path = os.path.join(PROJECT_ROOT, rel)
        with open(abs_path, "r", encoding="utf-8") as f:
            out[rel] = {"content": f.read()}
    return out


def compile_with_solcx():
    try:
        import solcx
    except ImportError:
        print("py-solc-x not installed. Install with: pip install py-solc-x")
        return 1

    from packaging.version import Version
    if Version(SOLC_VERSION) not in solcx.get_installed_solc_versions():
        print(f"Installing solc {SOLC_VERSION}...")
        solcx.install_solc(SOLC_VERSION)
    solcx.set_solc_version(SOLC_VERSION)

    input_data = {
        "language": "Solidity",
        "sources": build_source_map(),
        "settings": {
            "optimizer": {"enabled": True, "runs": 200},
            "outputSelection": {"*": {"*": ["abi", "evm.bytecode.object"]}},
        },
    }
    return process_result(solcx.compile_standard(input_data))


def process_result(data):
    errors = [e for e in data.get("errors", []) if e.get("severity") == "error"]
    warnings = [e for e in data.get("errors", []) if e.get("severity") == "warning"]
    if warnings:
        print("--- warnings (non-fatal) ---")
        for e in warnings:
            print(f"[warning] {e.get('formattedMessage') or e.get('message')}")
    if errors:
        print("--- compile ERRORS ---")
        for e in errors:
            print(f"[error] {e.get('formattedMessage') or e.get('message')}")
        return 1
    contracts = data.get("contracts", {})
    if not contracts:
        print("No contracts in output.")
        return 1
    print("Compile OK. Contracts:")
    for source, names in sorted(contracts.items()):
        for cname, info in names.items():
            abi_len = len(info.get("abi", []))
            bytecode = info.get("evm", {}).get("bytecode", {}).get("object", "")
            print(f"  {source}::{cname}  abi={abi_len} entries  bytecode={len(bytecode)//2} bytes")
    return 0


def main():
    try:
        return compile_with_solcx()
    except Exception as e:
        print(f"solcx failed: {e}")
        traceback.print_exc()
        return 1


if __name__ == "__main__":
    sys.exit(main())
