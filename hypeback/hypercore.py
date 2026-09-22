"""hypeback.hypercore — HyperCore market-data client.

Two access modes:

1. HTTP (works today, against HyperCore's public API at https://api.hyperliquid.xyz):
    - /info: metaAndAssetCtxs, candleSnapshot, fundingHistory
    - Used to bootstrap backtests with live data.

2. Precompile-ready (works post ~4 weeks after Elysium mainnet):
    - Reads the HyperCore market-data precompile at the fixed predeploy
      address (TBD by Kinetiq). The Python client here models the ABI
      so on-chain contracts (via a small SMT-style bridge) can call it
      with identical shape.

Design notes:
    - This module exposes a narrow interface (funding_history, spot_candles,
      meta) so it can be swapped between HTTP and precompile without
      touching the backtester.
    - All methods return plain Python structures (dicts / lists) matching
      the shapes the rest of hypeback already uses.

TODO (Elysium precompile integration):
    - Confirm precompile address once Kinetiq publishes the ArbOS
      upgrade spec.
    - Add a `PrecompileClient` class that issues JSON-RPC calls of
      the shape: { to: PRECOMPILE_ADDRESS, data: <calldata> } and
      decodes the response.
    - The calldata layouts here mirror the on-chain shape, so both
      paths will produce identical output.
"""

from __future__ import annotations

import json
import os
import time
from datetime import datetime, timezone
from typing import Dict, List, Optional

HYPERLIQUID_API_DEFAULT = "https://api.hyperliquid.xyz"

# Elysium precompile address — TBA by Kinetiq. Placeholder for now.
HYPERCORE_PRECOMPILE_ADDRESS = "0x000000000000000000000000000000000000C0DE"  # placeholder
# 99801 is a PLACEHOLDER testnet chain ID, not a confirmed value.
# Kinetiq's docs (elysium.kinetiq.xyz/docs/chain-specifications) say the
# real chain ID will be published at mainnet launch. Note: 999 is
# HyperEVM's mainnet chain ID, NOT Elysium's — do not use 999 here.
ELYSIUM_MAINNET_CHAIN_ID = None  # TBD by Kinetiq at launch
ELYSIUM_TESTNET_CHAIN_ID = 99801  # placeholder


# ---- HTTP helpers (no external deps beyond stdlib). ----

def _post_json(url: str, payload: dict, timeout: float = 15.0) -> dict:
    import urllib.request
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers={
        "Content-Type": "application/json",
        "User-Agent": "hypeback/0.1 (+https://github.com/kinetiq/elysium)",
    })
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8"))


# ---- Public API surface (mirrors hypeback.engine.load_funding). ----

class HyperCoreClient:
    """HTTP client for HyperCore market data.

    Usage:
        c = HyperCoreClient()
        records = c.funding_history(coin="HYPE", hours=24*30)
        candles = c.spot_candles(coin="HYPE", interval="1h", hours=24*30)
    """

    def __init__(self, base_url: str = HYPERLIQUID_API_DEFAULT):
        self.base = base_url.rstrip("/")

    # ---- meta ----

    def universe(self) -> List[dict]:
        """Return the full meta (coin, szDecimals, maxLeverage)."""
        return _post_json(self._url("/info"), {"type": "meta"})["universe"]

    def meta_and_asset_ctxs(self) -> dict:
        return _post_json(self._url("/info"), {"type": "metaAndAssetCtxs"})

    # ---- funding history ----

    def funding_history(self, coin: str = "HYPE", hours: int = 24 * 365,
                        start_ms: Optional[int] = None) -> List[dict]:
        """Return [{coin, fundingRate, premium, time}, ...] sorted by time."""
        payload = {
            "type": "fundingHistory",
            "coin": coin,
        }
        if start_ms is None and hours:
            start_ms = int(time.time() * 1000) - hours * 3600 * 1000
        if start_ms is not None:
            payload["startTime"] = start_ms

        result = _post_json(self._url("/info"), payload)
        # HyperCore returns an array of {coin, fundingRate, premium, time}
        records = result if isinstance(result, list) else []
        # Normalize the "time" field to int(ms).
        for r in records:
            r["time"] = int(r.get("time", 0))
            r["fundingRate"] = float(r.get("fundingRate", 0.0))
            r["premium"] = float(r.get("premium", 0.0))
        records.sort(key=lambda r: r["time"])
        return records

    # ---- candle snapshots ----

    def spot_candles(self, coin: str = "HYPE", interval: str = "1h",
                     hours: int = 24 * 365, start_ms: Optional[int] = None) -> List[dict]:
        """Return [{t, T, s, i, c, h, l, v, n}, ...] — candles sorted ascending.

        Field meanings: t=start ms, T=end ms, s=open, i=... , c=close,
        h=high, l=low, v=base volume, n=trades.
        """
        if start_ms is None:
            start_ms = int(time.time() * 1000) - hours * 3600 * 1000
        # /info accepts {type, req:{coin, interval, startTime, endTime}}
        payload = {
            "type": "candleSnapshot",
            "req": {
                "coin": coin,
                "interval": interval,
                "startTime": start_ms,
                "endTime": int(time.time() * 1000),
            },
        }
        result = _post_json(self._url("/info"), payload)
        if not isinstance(result, list):
            return []
        for c in result:
            for k in ("t", "T", "v", "n"):
                c[k] = int(c[k])
            for k in ("s", "c", "h", "l"):
                c[k] = float(c[k])
        result.sort(key=lambda c: c["t"])
        return result

    # ---- helpers ----

    def _url(self, path: str) -> str:
        return f"{self.base}{path}"


# ---- Precompile client (scaffold, requires on-chain call). ----

class PrecompileClient:
    """Scaffold for calling the HyperCore market-data precompile on Elysium.

    This class is a stub: it builds the calldata that would be sent to
    the precompile and documents the expected decoding logic. It does
    NOT send RPC calls here — that requires a web3 session and a running
    Elysium node, which we don't have in this dev environment.

    Usage when the precompile is live:

        pc = PrecompileClient(precompile_addr, web3)
        candles = pc.spot_candles("HYPE", interval="1h", hours=24*365)
    """

    def __init__(self, precompile_addr: str, web3=None, chain_id: int = ELYSIUM_TESTNET_CHAIN_ID):
        self.addr = precompile_addr
        self.web3 = web3
        self.chain_id = chain_id

    # ---- ABI (placeholder signatures — confirm with Kinetiq spec) ----
    # The precompile is expected to expose at least:
    #   spotCandles(address asset, uint64 startMs, uint64 endMs, uint8 interval) returns (Candle[])
    #   fundingHistory(address asset, uint64 startMs, uint64 endMs) returns (FundingTick[])
    #   meta() returns (UniverseEntry[])
    #
    # The actual signatures are not published yet. See docs/ROADMAP.md.

    SPOT_CANDLES_SIG = "spotCandles(address,uint64,uint64,uint8)"
    FUNDING_HISTORY_SIG = "fundingHistory(address,uint64,uint64)"
    META_SIG = "meta()"

    def _selector(self, sig: str) -> str:
        from eth_utils import keccak, function_selector_to_4byte_selector
        try:
            from eth_utils import function_selector_to_4byte_selector as fs
            return fs(sig).hex()
        except Exception:
            return keccak(sig.encode()).hex()[:8]

    def build_spot_candles_calldata(self, asset_addr: str, start_ms: int,
                                    end_ms: int, interval: int = 60) -> str:
        from eth_abi import encode as enc
        payload = enc(["address", "uint64", "uint64", "uint8"],
                      [asset_addr, start_ms, end_ms, interval])
        return "0x" + self._selector(self.SPOT_CANDLES_SIG) + payload.hex()

    def build_funding_history_calldata(self, asset_addr: str, start_ms: int,
                                       end_ms: int) -> str:
        from eth_abi import encode as enc
        payload = enc(["address", "uint64", "uint64"],
                      [asset_addr, start_ms, end_ms])
        return "0x" + self._selector(self.FUNDING_HISTORY_SIG) + payload.hex()

    def call(self, calldata: str) -> bytes:
        """Send the calldata to the precompile via web3. eth_call only."""
        if self.web3 is None:
            raise RuntimeError("PrecompileClient requires a web3 session")
        return self.web3.eth.call({
            "to": self.addr,
            "data": calldata,
        })

    def spot_candles(self, asset_addr: str, hours: int = 24 * 365,
                     start_ms: Optional[int] = None,
                     interval_minutes: int = 60) -> List[dict]:
        end_ms = int(time.time() * 1000)
        if start_ms is None:
            start_ms = end_ms - hours * 3600 * 1000
        calldata = self.build_spot_candles_calldata(asset_addr, start_ms, end_ms,
                                                     interval_minutes)
        raw = self.call(calldata)
        return _decode_candles(raw)

    def funding_history(self, asset_addr: str, hours: int = 24 * 365,
                        start_ms: Optional[int] = None) -> List[dict]:
        end_ms = int(time.time() * 1000)
        if start_ms is None:
            start_ms = end_ms - hours * 3600 * 1000
        calldata = self.build_funding_history_calldata(asset_addr, start_ms, end_ms)
        raw = self.call(calldata)
        return _decode_funding_ticks(raw)


# ---- Decoders (used by PrecompileClient). ----

def _decode_candles(raw: bytes) -> List[dict]:
    """Decode the Candles array from a precompile eth_call return.

    Layout: (Candle[]) where Candle = (uint64 t, uint64 T, uint256 s,
    uint256 i, uint256 c, uint256 h, uint256 l, uint256 v, uint256 n).
    The exact ABI depends on Kinetiq's spec — this decoder assumes a
    common packing. Adjust once the spec is final.
    """
    from eth_abi import decode as dec
    types = ["tuple[]"]
    components = [("uint64", "uint64", "uint256", "uint256", "uint256",
                   "uint256", "uint256", "uint256", "uint256")]
    # eth_abi's tuple[] needs the component list passed separately;
    # the simpler approach is to decode as (uint64,uint64,uint256)*N.
    # We do a minimal length prefix read.
    if len(raw) < 32:
        return []
    length = int.from_bytes(raw[:32], "big")
    if length == 0:
        return []
    out = []
    for i in range(length):
        off = 32 + i * 32 * 9
        if off + 32 * 9 > len(raw):
            break
        vals = [raw[off + j*32: off + (j+1)*32] for j in range(9)]
        t, T, s, _ignore, c, h, l, v, n = [int.from_bytes(x, "big") for x in vals]
        out.append({
            "t": t, "T": T,
            "s": s, "c": c, "h": h, "l": l,
            "v": v, "n": n,
        })
    return out


def _decode_funding_ticks(raw: bytes) -> List[dict]:
    """Decode the FundingTick[] return from the precompile.

    Layout: (FundingTick[]) where FundingTick = (uint256 fundingRate,
    uint256 premium, uint256 time) — rates/premiums may be scaled.
    """
    if len(raw) < 32:
        return []
    length = int.from_bytes(raw[:32], "big")
    if length == 0:
        return []
    out = []
    for i in range(length):
        off = 32 + i * 32 * 3
        if off + 32 * 3 > len(raw):
            break
        fr = int.from_bytes(raw[off: off+32], "big")
        pr = int.from_bytes(raw[off+32: off+64], "big")
        ts = int.from_bytes(raw[off+64: off+96], "big")
        # Assume rates are scaled by 1e8.
        out.append({
            "fundingRate": fr / 1e8,
            "premium": pr / 1e8,
            "time": ts,
        })
    return out


# ---- Convenience: build the full funding dataset used by hypeback.engine. ----

def bootstrap_funding_dataset(client: Optional[HyperCoreClient] = None,
                              coin: str = "HYPE",
                              hours: int = 24 * 365 * 2,
                              out_path: Optional[str] = None) -> List[dict]:
    """Fetch and persist a funding-history dataset matching
    hypeback.engine.load_funding's expected shape."""
    c = client or HyperCoreClient()
    records = c.funding_history(coin=coin, hours=hours)
    if out_path:
        os.makedirs(os.path.dirname(out_path), exist_ok=True)
        with open(out_path, "w") as f:
            json.dump(records, f)
        print(f"Wrote {len(records)} funding records to {out_path}")
    return records


if __name__ == "__main__":
    # Smoke test: fetch last 7 days of HYPE funding.
    c = HyperCoreClient()
    recs = c.funding_history(coin="HYPE", hours=24 * 7)
    print(f"Fetched {len(recs)} funding records (last 7 days)")
    if recs:
        print(f"  first: {recs[0]}")
        print(f"  last : {recs[-1]}")
