#!/usr/bin/env python3
"""check_repo.py — independent verifier for the hypeback review fixes.

Usage:
  python3 check_repo.py <repo_root>              # docs + solidity checks
  python3 check_repo.py <docs_dir> --docs-only   # markdown checks only
  python3 check_repo.py <root> --ignore D7,I3    # suppress codes

Exit code: 1 if any FAIL-level finding, 0 otherwise.
FAIL = must fix before sending to Kinetiq. INFO = manual review.
"""
import argparse
import re
import sys
from pathlib import Path

# ---------------------------------------------------------------- doc checks
# (code, level, regex, must-not-contain-same-line, description)
DOC_CHECKS = [
    ("D1", "FAIL",
     r"Elysium mainnet \(chainId 999\)|chainId 999 for mainnet|refuses Elysium mainnet|Elysium mainnet.*chainId\s*999",
     None,
     "chainId 999 attributed to Elysium mainnet (999 = HyperEVM; Elysium ID unpublished)"),
    ("D2", "FAIL", r"\b99801\b", None,
     "placeholder chainId 99801 (official docs: chain IDs published at launch)"),
    ("D3", "FAIL", r"uint8\[\]\s*weights", None,
     "uint8[] weights cannot hold 10000 bps — must be uint16[4]"),
    ("D4", "FAIL", r"planned for v0\.2|not shipped in this repo", None,
     "DELEGATION_SPEC §10 claims TradeOnlyAgent impl not shipped (it is)"),
    ("D5", "FAIL", r"FUNGING", None, "typo FUNGING_STRONG"),
    ("D6", "FAIL", r"allocation allocation", None, "duplicated word"),
    ("D7", "FAIL", r"abi=39|12\s?096\b|2\s?886\b|39 ABI entries", None,
     "stale contract stats (current build: 42 ABI / 12,306 B; 8 ABI / 2,839 B)"),
    ("D8", "FAIL", r"\(10 total", None,
     "'Contracts (10 total)' — count doesn't match the table"),
    ("D9", "INFO", r"testnet-rpc\.elysium\.kinetiq\.xyz", None,
     "unpublished RPC URL — mark as example/placeholder"),
    ("D10", "FAIL", r"deposit\(uint256 shares|previewWithdraw\(uint256 shares", None,
     "non-canonical ERC-4626 signatures in spec snippet"),
    ("D11", "FAIL", r"block\.timestamp\s*<=\s*[\w.]*expiresAt", r"==\s*0",
     "expiresAt=0 ('never') always reverts on this require — need `== 0 ||`"),
    ("I1", "INFO", r"19\.67|17\.56", r"excludes|caveat|not comparable|microstructure",
     "Sharpe figure — verify explicit model-risk caveat is present nearby"),
    ("I2", "INFO", r"15-hour negative funding streak|15h longest|longest historical", None,
     "'Why Elysium' 15h-streak argument — should be reframed as basis/HFT value"),
    ("I3", "INFO", r"cancelPending", r"owner|keeper|multisig|governance|bond|role",
     "cancelPending open-to-anyone — verify access policy decision is documented"),
    ("I4", "INFO", r"priority access", None,
     "email ask — official wording is 'early access / integration support'"),
]


def run_doc_checks(root: Path, ignore: set) -> int:
    fails = 0
    findings = []
    for md in sorted(root.rglob("*.md")):
        if any(p in md.parts for p in ("node_modules", ".git")):
            continue
        try:
            text = md.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for lineno, line in enumerate(text.splitlines(), 1):
            for code, level, pattern, neg, desc in DOC_CHECKS:
                if code in ignore:
                    continue
                if re.search(pattern, line) and not (neg and re.search(neg, line)):
                    findings.append((level, code, md, lineno, desc, line.strip()[:100]))
    for level, code, md, lineno, desc, snippet in sorted(findings, key=lambda f: (f[0] != "FAIL", f[2], f[3])):
        rel = md.relative_to(root) if md.is_relative_to(root) else md
        print(f"[{level}] {code}  {rel}:{lineno}  {desc}")
        print(f"        > {snippet}")
        if level == "FAIL":
            fails += 1
    return fails


# ------------------------------------------------------------ solidity checks
REQUIRED_4626 = ["asset", "totalAssets", "deposit", "mint", "withdraw",
                 "redeem", "previewDeposit", "previewMint",
                 "previewWithdraw", "previewRedeem"]


def run_solidity_checks(root: Path, ignore: set) -> int:
    sol_dir = root / "solidity"
    if not sol_dir.is_dir():
        sol_dir = root  # maybe pointed directly at solidity/
    # `.t.sol` files live in `solidity/test/` and use forge-std imports
    # (`@forge-std/Test.sol`). The external verifier runs solc directly
    # with no remapping support, so those files can't compile here —
    # they're already covered by `forge test`. Skip the test dir for
    # the same reason forge-std lives in `lib/` (which we already
    # exclude).
    srcs = sorted(p for p in sol_dir.rglob("*.sol")
                  if not any(x in p.parts for x in
                             ("node_modules", ".git", "lib", "out", "test")))
    if not srcs:
        print("[INFO] S0  no .sol sources found — skipping solidity checks")
        return 0
    try:
        import solcx
    except ImportError:
        print("[INFO] S0  py-solc-x not installed — skipping solidity checks "
              "(pip install py-solc-x)")
        return 0
    try:
        solcx.install_solc("0.8.26")
    except Exception as e:  # already installed or offline
        print(f"[INFO] S0  solc install note: {e}")
    base = sol_dir.parent if sol_dir.name == "solidity" else sol_dir
    sources = {}
    for p in srcs:
        try:
            sources[str(p.relative_to(base))] = p.read_text(encoding="utf-8", errors="replace")
        except ValueError:
            sources[p.name] = p.read_text(encoding="utf-8", errors="replace")
    inp = {
        "language": "Solidity",
        "sources": {k: {"content": v} for k, v in sources.items()},
        "settings": {
            "optimizer": {"enabled": True, "runs": 200},
            "outputSelection": {"*": {"*": ["abi", "evm.bytecode.object",
                                            "evm.deployedBytecode.object"]}},
        },
    }
    try:
        out = solcx.compile_standard(inp, solc_version="0.8.26")
    except Exception as e:
        print(f"[FAIL] S1  compile crashed: {e}")
        return 1
    fails = 0
    errors = [e for e in out.get("errors", []) if e.get("severity") == "error"]
    warns = [e for e in out.get("errors", []) if e.get("severity") != "error"]
    if errors:
        fails += 1
        print("[FAIL] S1  compile errors:")
        for e in errors[:10]:
            print("        " + e.get("formattedMessage", str(e)).strip()[:200])
    else:
        print(f"[ OK ] S1  compile clean (solc 0.8.26, {len(warns)} warnings)")

    contracts = {}
    for unit, cs in out.get("contracts", {}).items():
        for name, c in cs.items():
            contracts[name] = (unit, c)

    print("\n--- fresh build stats (source of truth for both READMEs) ---")
    print(f"{'contract':24} {'abi':>4} {'creation B':>11} {'deployed B':>11}  unit")
    for name, (unit, c) in sorted(contracts.items()):
        abi = c.get("abi", [])
        created = len(c.get("evm", {}).get("bytecode", {}).get("object", "")) // 2
        deployed = len(c.get("evm", {}).get("deployedBytecode", {}).get("object", "")) // 2
        print(f"{name:24} {len(abi):>4} {created:>11} {deployed:>11}  {unit}")
    print("-----------------------------------------------------------\n")

    # S2: ERC-4626 surface on YieldAggregator
    if "S2" not in ignore:
        ya = contracts.get("YieldAggregator")
        if ya:
            fns = {e["name"] for e in ya[1].get("abi", []) if e.get("type") == "function"}
            missing = [f for f in REQUIRED_4626 if f not in fns]
            if missing:
                fails += 1
                print(f"[FAIL] S2  YieldAggregator missing ERC-4626 methods: {missing}")
            else:
                print("[ OK ] S2  YieldAggregator has full ERC-4626 method surface")
    # S3: expiresAt == 0 handling in TradeOnlyAgent source
    if "S3" not in ignore:
        hit = None
        for p in srcs:
            if p.name == "TradeOnlyAgent.sol":
                t = p.read_text(encoding="utf-8", errors="replace")
                hit = re.search(r"expiresAt\s*==\s*0|0\s*==\s*[\w.]*expiresAt", t)
        if hit:
            print("[ OK ] S3  TradeOnlyAgent handles expiresAt == 0 ('never')")
        else:
            fails += 1
            print("[FAIL] S3  TradeOnlyAgent: no `expiresAt == 0` short-circuit found "
                  "— delegations with expiresAt=0 may always revert")
    # S4: revoke(address) present
    if "S4" not in ignore:
        ta = contracts.get("TradeOnlyAgent")
        if ta:
            fns = {e["name"] for e in ta[1].get("abi", []) if e.get("type") == "function"}
            if "revoke" in fns:
                print("[ OK ] S4  TradeOnlyAgent.revoke present (universal revocation)")
            else:
                fails += 1
                print("[FAIL] S4  TradeOnlyAgent.revoke missing — spec claims universal revoke")
    # S5: stats drift between root README table and fresh build
    if "S5" not in ignore:
        for readme in (root / "README.md", root / "solidity" / "README.md"):
            if not readme.is_file():
                continue
            rows = re.findall(
                r"\|\s*`?(?:src/|solidity/src/)?([\w/]+\.sol)`?\s*\|\s*([\d, ]+?)\s*\|\s*(\d+)\s*\|",
                readme.read_text(encoding="utf-8", errors="replace"))
            for fname, size_s, abi_s in rows:
                stem = Path(fname).stem
                if stem not in contracts:
                    continue
                c = contracts[stem][1]
                abi = len(c.get("abi", []))
                sizes = {len(c.get("evm", {}).get(k, {}).get("object", "")) // 2
                         for k in ("bytecode", "deployedBytecode")}
                size = int(size_s.replace(",", "").replace(" ", ""))
                problems = []
                if int(abi_s) != abi:
                    problems.append(f"ABI {abi_s}!=build:{abi}")
                if size not in sizes:
                    problems.append(f"bytes {size}!=build:{sorted(sizes)}")
                tag = "FAIL" if problems else " OK "
                if problems:
                    fails += 1
                print(f"[{tag}] S5  {readme.name}: {fname} " +
                      ("; ".join(problems) if problems else "matches build"))
    return fails


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("root", type=Path)
    ap.add_argument("--docs-only", action="store_true")
    ap.add_argument("--ignore", default="", help="comma-separated codes, e.g. D7,I3")
    args = ap.parse_args()
    ignore = {x.strip() for x in args.ignore.split(",") if x.strip()}
    if not args.root.is_dir():
        print(f"not a directory: {args.root}")
        return 2
    fails = run_doc_checks(args.root, ignore)
    if not args.docs_only:
        fails += run_solidity_checks(args.root, ignore)
    print(f"\n== {fails} FAIL-level finding(s) ==")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
