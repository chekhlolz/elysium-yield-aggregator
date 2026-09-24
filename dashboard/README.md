# HyperEVM Ecosystem Dashboard

A static, single-page dashboard that shows the current state of the
HyperEVM ecosystem as captured by DeFiLlama, plus the aggregator's
alpha claim from `docs/KINETIQ_PARTNERS_ONEPAGER.md`. No server, no
build step, no npm install.

## Files

```
dashboard/
  index.html    The dashboard (self-contained, Chart.js via CDN).
  data.json     The numbers. Every field has a source_url.
  refresh.py    Optional stdlib-only refresh script (dry-run by default).
  README.md     This file.
  SECURITY.md   Threat-model notes.
```

## How to view

Just open `index.html` in a browser.

- **Windows**: double-click `index.html` in Explorer, or drag it into a browser window.
- **macOS**: `open index.html` in Terminal, or double-click in Finder.
- **Linux**: `xdg-open index.html` or `firefox index.html`.

No network calls other than fetching Chart.js from jsdelivr and
(optionally) `data.json` from the same directory.

If your browser blocks `file://` XHR (Firefox does by default), serve
the directory:

```bash
python -m http.server 8000 --directory dashboard
# then open http://localhost:8000/
```

## Data refresh

`data.json` is hand-curated against DeFiLlama. To refresh:

1. Fetch the chains list: <https://api.llama.fi/v2/chains>
2. Fetch the protocols list: <https://api.llama.fi/protocols>
3. Update `data.json` — every number has a `source_url` field.
4. If a number comes from `docs/KINETIQ_PARTNERS_ONEPAGER.md`
   (kHYPE $1.13B @ 1.83%, xHYPE $6.99M @ 14.50%), keep the source
   pointing at `kinetiq.xyz` or `defillama.com` as appropriate and
   mark it `"note"` to explain the discrepancy.
5. Reload `index.html`.

Or use the optional script:

```bash
python dashboard/refresh.py --dry-run   # prints the URLs it would fetch
python dashboard/refresh.py             # actually fetches and rewrites data.json
```

`refresh.py` is stdlib-only (`urllib.request`, `json`) — no `requests`,
no `httpx`. If your network environment blocks the DeFiLlama endpoints,
run with `--dry-run` and update `data.json` by hand.

## What it does NOT do

- No live RPC calls, no web3 library, no contract queries.
- No API key required.
- No build step, no bundler, no TypeScript, no npm install.
- No tracking, analytics, or cookies.
- No inline event handlers beyond Chart.js's own callbacks.
- No personal PII.

## Data sources

- <https://api.llama.fi/v2/chains> — chain-level TVL ("Hyperliquid L1", "Robinhood Chain").
- <https://api.llama.fi/protocols> — protocol-level TVL + chain attribution.
- <https://defillama.com> — reference for the xHYPE vault listing.
- <https://kinetiq.xyz> — kHYPE TVL and APY (cited in `docs/KINETIQ_PARTNERS_ONEPAGER.md`).
- <https://github.com/chekhlolz/elysium-yield-aggregator> — aggregator alpha claim source.

## License

Apache-2.0, matching the parent repo. See `SECURITY.md` for threat
model notes and the SPDX header convention.
