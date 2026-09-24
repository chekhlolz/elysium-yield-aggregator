#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
#
# refresh.py — regenerate dashboard/data.json from DeFiLlama public APIs.
#
# Stdlib only (urllib.request + json), matching the style of
# hypeback/hypeback/hypercore.py.
#
# Default mode: --dry-run. Prints the URLs it WOULD fetch and exits.
# Pass --write to actually fetch and rewrite data.json in place.
#
# Usage:
#   python dashboard/refresh.py --dry-run      # safe default
#   python dashboard/refresh.py                # same as --dry-run
#   python dashboard/refresh.py --write        # actually fetch and rewrite
#
# Does NOT preserve curated entries that DeFiLlama does not list
# (Kinetiq kHYPE, Liminal xHYPE). Those live under the `ecosystem`
# object in data.json and are re-emitted verbatim on refresh.

from __future__ import annotations

import argparse
import datetime as _dt
import json
import sys
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

CHAINS_URL = "https://api.llama.fi/v2/chains"
PROTOCOLS_URL = "https://api.llama.fi/protocols"
DATA_FILE = Path(__file__).resolve().parent / "data.json"

# Categories whose TVL we actually want to show on HyperEVM.
# CEXs and non-chain items are filtered out.
CEX_CATEGORIES = {"CEX", "Exchange"}

# Protocols we know are on HyperEVM/Hyperliquid L1 as of the last refresh.
# Any protocol with `chainTvl.Hyperliquid L1 > 0` that is not a CEX is kept.
CHAIN_LABEL = "Hyperliquid L1"

# Curated ecosystem entries — re-emitted verbatim on refresh so we
# don't lose numbers DeFiLlama does not track for HyperEVM (kHYPE,
# xHYPE). Update manually when Kinetiq or Liminal publish.
CURATED_ECOSYSTEM: Dict[str, Dict[str, Any]] = {
    "kHYPE": {
        "tvl_usd": 1_130_000_000,
        "apy_pct": 1.83,
        "source": "kinetiq.xyz",
        "source_url": "https://kinetiq.xyz",
        "note": "kHYPE is the Kinetiq liquid staking token on HyperEVM. "
                "Cited in docs/KINETIQ_PARTNERS_ONEPAGER.md.",
    },
    "xHYPE": {
        "tvl_usd": 6_990_000,
        "apy_pct": 14.50,
        "source": "defillama.com",
        "source_url": "https://defillama.com",
        "note": "Liminal xHYPE vault. Live APY referenced in the one-pager. "
                "DeFiLlama does not list an xHYPE vault on HyperEVM as of the "
                "last fetch.",
    },
    "RobinhoodChain": {
        "tvl_usd": 998_053_202,
        "source": "defillama.com",
        "source_url": CHAINS_URL,
        "note": "Competitor L1; listed for context, not part of HyperEVM.",
    },
}

ALPHA_CLAIM: Dict[str, str] = {
    "figure": "+3.47% APY median",
    "context": "regime-sweep winner, 15 seeds, 100% positive, 15,750h history",
    "caveat": "below Liminal xHYPE's live 14.50% — complementary, not a substitute",
}

CATEGORY_LEGEND: Dict[str, str] = {
    "liquid-staking": "#7c3aed",
    "vault": "#dc2626",
    "lending": "#2563eb",
    "bridge": "#0891b2",
    "capital-allocator": "#16a34a",
    "risk-curators": "#9333ea",
}


def _get_json(url: str, timeout: int = 30) -> Any:
    req = Request(url, headers={"User-Agent": "hypeback-dashboard/0.1"})
    with urlopen(req, timeout=timeout) as resp:  # noqa: S310 (https only)
        return json.loads(resp.read().decode("utf-8"))


def _fetch_chains() -> List[Dict[str, Any]]:
    data = _get_json(CHAINS_URL)
    if not isinstance(data, list):
        raise ValueError(f"unexpected response shape from {CHAINS_URL}")
    return data


def _fetch_protocols() -> List[Dict[str, Any]]:
    data = _get_json(PROTOCOLS_URL)
    if not isinstance(data, list):
        raise ValueError(f"unexpected response shape from {PROTOCOLS_URL}")
    return data


def _extract_hypevm_chain(chains: Iterable[Dict[str, Any]]) -> Optional[Dict[str, Any]]:
    for c in chains:
        if c.get("name") == CHAIN_LABEL:
            return c
    return None


def _extract_robinhood(chains: Iterable[Dict[str, Any]]) -> Optional[Dict[str, Any]]:
    for c in chains:
        if c.get("name") == "Robinhood Chain":
            return c
    return None


def _normalize_category(raw: str) -> str:
    if not raw:
        return "unknown"
    mapping = {
        "Liquid Staking": "liquid-staking",
        "Lending": "lending",
        "Bridge": "bridge",
        "DEXs": "dex",
        "Dexs": "dex",
        "CDP": "cdp",
        "Capital Allocator": "capital-allocator",
        "Onchain Capital Allocator": "capital-allocator",
        "Risk Curators": "risk-curators",
        "Vault": "vault",
        "Yield": "vault",
        "Perps": "perp",
    }
    return mapping.get(raw, raw.lower().replace(" ", "-"))


def _build_protocols(protocols: Iterable[Dict[str, Any]]) -> List[Dict[str, Any]]:
    out: List[Dict[str, Any]] = []
    for p in protocols:
        name = p.get("name") or ""
        category = p.get("category") or ""
        if category in CEX_CATEGORIES:
            continue
        chain_tvl = p.get("chainTvl") or {}
        hyper_tvl = chain_tvl.get(CHAIN_LABEL)
        if not isinstance(hyper_tvl, (int, float)) or hyper_tvl <= 0:
            continue
        out.append({
            "name": name,
            "category": _normalize_category(category),
            "tvl_usd": int(hyper_tvl) if float(hyper_tvl).is_integer() else float(hyper_tvl),
            "apy_pct": None,
            "website": p.get("url") or "",
            "source": "defillama.com",
            "source_url": PROTOCOLS_URL,
            "last_updated": _today(),
        })
    # Sort by TVL desc; keep everything, the HTML page shows top 10.
    out.sort(key=lambda x: x["tvl_usd"] or 0, reverse=True)
    return out


def _today() -> str:
    return _dt.datetime.utcnow().strftime("%Y-%m-%d")


def _gen_ts() -> str:
    return _dt.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%S+00:00")


def build_data(chains: List[Dict[str, Any]],
               protocols: List[Dict[str, Any]]) -> Dict[str, Any]:
    hyper = _extract_hypevm_chain(chains)
    rh = _extract_robinhood(chains)

    ecosystem = dict(CURATED_ECOSYSTEM)
    if hyper:
        tvl = hyper.get("tvl")
        ecosystem["TotalHyperEVM"] = {
            "tvl_usd": int(tvl) if isinstance(tvl, (int, float)) and float(tvl).is_integer() else tvl,
            "source": "defillama.com",
            "source_url": CHAINS_URL,
            "note": f"DeFiLlama labels this chain '{CHAIN_LABEL}'. "
                    f"Used as the HyperEVM total.",
        }
    if rh:
        tvl = rh.get("tvl")
        ecosystem["RobinhoodChain"] = {
            "tvl_usd": int(tvl) if isinstance(tvl, (int, float)) and float(tvl).is_integer() else tvl,
            "source": "defillama.com",
            "source_url": CHAINS_URL,
            "note": "Competitor L1; listed for context, not part of HyperEVM.",
        }

    return {
        "generated_at": _gen_ts(),
        "ecosystem": ecosystem,
        "protocols": _build_protocols(protocols),
        "alpha_claim": dict(ALPHA_CLAIM),
        "category_legend": dict(CATEGORY_LEGEND),
        "sources": [CHAINS_URL, PROTOCOLS_URL, "https://defillama.com", "https://kinetiq.xyz"],
    }


def _dry_run_report() -> None:
    print("refresh.py --dry-run")
    print(f"  data file: {DATA_FILE}")
    print("  would fetch:")
    print(f"    {CHAINS_URL}")
    print(f"    {PROTOCOLS_URL}")
    print("  would write:")
    print(f"    {DATA_FILE}")
    print()
    print("Tip: pass --write to actually fetch and rewrite data.json.")
    print("     Every field carries a source_url so numbers stay traceable.")


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="Refresh dashboard/data.json from DeFiLlama.",
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", action="store_true",
                      help="print URLs and exit (default)")
    mode.add_argument("--write", action="store_true",
                      help="fetch and rewrite data.json in place")
    args = parser.parse_args(argv)

    if not args.write:
        _dry_run_report()
        return 0

    try:
        chains = _fetch_chains()
        protocols = _fetch_protocols()
    except (HTTPError, URLError, ValueError, TimeoutError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 2

    data = build_data(chains, protocols)
    DATA_FILE.write_text(
        json.dumps(data, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    print(f"wrote {DATA_FILE} ({len(data.get('protocols', []))} protocols)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
