# Security notes

This dashboard is a static HTML page plus a JSON data file. It is
designed to be opened from `file://` or served from any static host
with no build step and no server-side logic.

## Threat model

| Surface | Risk | Mitigation |
|---|---|---|
| `data.json` | Attacker swaps the file | Every number carries a `source_url`; readers can verify. No code is executed from this file. |
| Chart.js from CDN | CDN compromise or supply-chain attack | Pinned to `chart.js@4.4.3` on jsdelivr with a `sha384` SRI integrity attribute and `crossorigin="anonymous"`. A mismatch aborts loading. |
| CDN offline / blocked | Charts don't render | The page still renders KPIs, the table, and the alpha claim. A `<noscript>` block carries the full table so all data remains accessible without JavaScript. |
| Inline JS | XSS via `innerHTML` with untrusted data | Only `textContent` and `document.createElement` are used to render `data.json` values. There is a single `innerHTML = ""` reset on the `alpha-cav` element (trusted, hardcoded structure) to guarantee no stale content survives across renders; the actual content of that element is written with `textContent`/`createElement`. No `eval`, no `Function()`, no `setTimeout(string)`. |
| Inline event handlers | XSS via `onclick=` etc. | None present. Chart.js attaches its own listeners via its own code. |
| `<script src>` from untrusted origins | Script injection | Only one external script, from a pinned CDN URL with SRI. |
| PII | Privacy | No email, no phone, no handle beyond the public GitHub handle `@chekhlolz` (referenced in the parent repo's one-pager). |
| Tracking | Privacy | No analytics, no cookies, no `navigator.sendBeacon`, no `postMessage`, no `localStorage` writes, no third-party fonts, no images. |
| Referrer leakage | Privacy | `<meta name="referrer" content="no-referrer">` prevents referrer leakage to external URLs. |

## CDN failure behavior

If the jsdelivr CDN is unreachable, the Chart.js script tag fails to
load. Because the render code checks `typeof Chart === "undefined"`
before constructing charts, the rest of the dashboard (KPI cards,
protocol table, alpha callout, footer) still renders from `data.json`.

The `<noscript>` block at the bottom of the protocol-table section is
always in the DOM. Browsers that have JavaScript disabled ignore the
`<div id="js-table"></div>` sibling and render the noscript table
instead. Browsers with JavaScript enabled will have their table body
populated from `data.json` at runtime (a duplicate of the same data,
kept in sync so the accessibility fallback stays correct even if a
future edit forgets to update it).

## What we refuse to add

- No WebSocket connections.
- No third-party analytics or telemetry.
- No remote font loading.
- No `eval` or `Function()` construction.
- No `fetch` of scripts or JSONP endpoints.

Adding any of these would be a security regression for a page that
should be safe to open from `file://`.
