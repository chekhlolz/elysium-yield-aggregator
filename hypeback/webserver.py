"""hypeback.webserver — local web UI for the backtester.

Serves a single HTML page with:
  - configuration panel (HR, Lev, vol, staking, capital, rebalance, seed, window, paths)
  - KPI cards (net APY, max DD, Sharpe, liquidation, kill-gate verdict)
  - equity curve chart (Chart.js)
  - Monte Carlo APY distribution histogram + max-DD bar
  - sensitivity sweep grid table

Endpoints:
  GET /            — HTML dashboard
  POST /api/run    — single backtest, returns {result, equity_curve}
  POST /api/mc     — Monte Carlo, returns aggregates + APY/DD samples
  POST /api/sweep  — HR x Lev x rebalance grid

No external Python deps beyond stdlib. Uses Chart.js from CDN (or
chart.min.js vendored in ./static if offline).
"""

import json
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from . import engine

HTML = r"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<title>hypeback — HYPE delta-neutral backtester</title>
<style>
:root{--bg:#0b0f17;--panel:#131a26;--border:#1f2a3d;--text:#e6edf6;--muted:#8892a6;
--accent:#7aa2ff;--good:#4ade80;--bad:#f87171;--warn:#fbbf24}
*{box-sizing:border-box}
body{margin:0;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;
background:var(--bg);color:var(--text);font-size:14px}
header{padding:14px 22px;border-bottom:1px solid var(--border);background:var(--panel);
display:flex;justify-content:space-between;align-items:center}
header h1{margin:0;font-size:16px;font-weight:600}
header .sub{color:var(--muted);font-size:12px}
main{display:grid;grid-template-columns:280px 1fr;gap:16px;padding:16px}
aside{background:var(--panel);border:1px solid var(--border);border-radius:8px;padding:14px}
aside h3{margin:0 0 10px;font-size:12px;text-transform:uppercase;letter-spacing:.05em;color:var(--muted)}
label{display:block;margin:8px 0 4px;font-size:12px;color:var(--muted)}
input,select{width:100%;padding:6px 8px;background:#0b1220;border:1px solid var(--border);
color:var(--text);border-radius:4px;font-size:13px}
button{margin-top:10px;padding:9px 12px;background:var(--accent);color:#0b0f17;border:none;
border-radius:4px;font-weight:600;cursor:pointer;width:100%}
button:hover{background:#93b3ff}
button.sec{background:#1f2a3d;color:var(--text);margin-top:6px}
section{background:var(--panel);border:1px solid var(--border);border-radius:8px;padding:14px;margin-bottom:14px}
section h2{margin:0 0 10px;font-size:14px;font-weight:600}
.kpis{display:grid;grid-template-columns:repeat(6,1fr);gap:8px;margin-bottom:14px}
.kpi{background:var(--panel);border:1px solid var(--border);border-radius:6px;padding:10px}
.kpi .v{font-size:18px;font-weight:600}
.kpi .l{font-size:11px;color:var(--muted);text-transform:uppercase}
.good{color:var(--good)}.bad{color:var(--bad)}.warn{color:var(--warn)}
table{width:100%;border-collapse:collapse;font-size:12px}
th,td{padding:5px 8px;border-bottom:1px solid var(--border);text-align:right}
th:first-child,td:first-child{text-align:left}
th{color:var(--muted);font-weight:500}
tr.pass td{color:var(--good)}tr.fail td{color:var(--bad)}
canvas{max-width:100%}
.status{font-size:12px;color:var(--muted);margin-top:6px}
.status.err{color:var(--bad)}
.pills{display:flex;gap:8px;flex-wrap:wrap;margin-top:8px}
.pill{padding:3px 10px;border-radius:12px;font-size:11px;font-weight:600}
.pill.pass{background:#052e16;color:var(--good);border:1px solid #14532d}
.pill.fail{background:#3b0a0a;color:var(--bad);border:1px solid #7f1d1d}
</style></head>
<body>
<header>
  <div><h1>hypeback</h1><div class="sub">HYPE delta-neutral backtester · Elysium builder workstream</div></div>
  <div class="sub" id="status-header">idle</div>
</header>
<main>
<aside>
  <h3>Position</h3>
  <label>Hedge ratio (perp/spot)</label><input id="hr" type="number" step="0.1" value="1.0">
  <label>Perp leverage</label><input id="lev" type="number" step="0.5" value="3">
  <label>Rebalance interval (h)</label><input id="rebal" type="number" step="1" value="12">
  <label>Initial capital (USD)</label><input id="capital" type="number" value="100000">

  <h3 style="margin-top:14px">Market</h3>
  <label>HYPE annual vol</label><input id="vol" type="number" step="0.05" value="0.70">
  <label>Staking APY (kHYPE)</label><input id="staking" type="number" step="0.001" value="0.0189">
  <label>Funding window (hours, 0 = all)</label><input id="window" type="number" value="0">

  <h3 style="margin-top:14px">Run</h3>
  <label>Seed</label><input id="seed" type="number" value="42">
  <label>MC paths</label><input id="paths" type="number" value="300">
  <label>MC seed</label><input id="mcseed" type="number" value="1000">

  <button id="run-btn">Run backtest</button>
  <button id="mc-btn" class="sec">Monte Carlo</button>
  <button id="sweep-btn" class="sec">Sweep</button>
  <div class="status" id="status"></div>
</aside>

<section>
  <h2>KPI — single path (seed=<span id="kpi-seed">—</span>)</h2>
  <div class="kpis">
    <div class="kpi"><div class="l">Final equity</div><div class="v" id="k-final">—</div></div>
    <div class="kpi"><div class="l">Net APY</div><div class="v" id="k-apy">—</div></div>
    <div class="kpi"><div class="l">Max DD</div><div class="v" id="k-dd">—</div></div>
    <div class="kpi"><div class="l">Sharpe</div><div class="v" id="k-sharpe">—</div></div>
    <div class="kpi"><div class="l">Liquidated</div><div class="v" id="k-liq">—</div></div>
    <div class="kpi"><div class="l">Kill gate</div><div class="v" id="k-gate">—</div></div>
  </div>
  <div class="pills" id="kpi-pills"></div>
</section>

<section>
  <h2>Equity curve (hourly)</h2>
  <canvas id="equity" height="180"></canvas>
</section>

<section>
  <h2>Monte Carlo — APY distribution</h2>
  <div class="kpis" style="grid-template-columns:repeat(4,1fr);margin-bottom:8px">
    <div class="kpi"><div class="l">Median APY</div><div class="v" id="mc-median">—</div></div>
    <div class="kpi"><div class="l">p10 / p90</div><div class="v" id="mc-p10p90">—</div></div>
    <div class="kpi"><div class="l">Worst DD</div><div class="v" id="mc-worstdd">—</div></div>
    <div class="kpi"><div class="l">Liquidations</div><div class="v" id="mc-liq">—</div></div>
  </div>
  <canvas id="apy-hist" height="160"></canvas>
</section>

<section>
  <h2>Sensitivity sweep — HR × Lev × rebalance</h2>
  <div id="sweep-table"><i class="status">no sweep yet</i></div>
</section>

</main>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.min.js"></script>
<script>
const $ = id => document.getElementById(id);
const status = (msg, err=false) => { $('status').textContent = msg; $('status').className = 'status' + (err?' err':''); $('status-header').textContent = msg; };
const pct = v => (v*100).toFixed(2)+'%';
const usd = v => '$'+v.toLocaleString('en-US',{maximumFractionDigits:0});

let eqChart, apyChart;

function readParams(){
  const w = parseInt($('window').value)||0;
  return {
    hr_target: parseFloat($('hr').value),
    lev: parseFloat($('lev').value),
    rebalance_interval_hours: parseInt($('rebal').value),
    initial_capital: parseFloat($('capital').value),
    vol_annual: parseFloat($('vol').value),
    staking_apy: parseFloat($('staking').value),
    seed: parseInt($('seed').value),
    window_hours: w>0?w:undefined,
  };
}

async function api(path, body){
  const t0 = performance.now();
  const r = await fetch(path, {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify(body)});
  const j = await r.json();
  return {j, ms: performance.now()-t0};
}

function renderKPIs(r){
  $('k-final').textContent = usd(r.final_equity);
  $('k-apy').textContent = pct(r.net_apy);
  $('k-apy').className = 'v '+(r.net_apy>0.04?'good':'bad');
  $('k-dd').textContent = pct(r.max_drawdown);
  $('k-dd').className = 'v '+(r.max_drawdown<0.15?'good':'bad');
  $('k-sharpe').textContent = r.sharpe.toFixed(2);
  $('k-liq').textContent = r.liquidated?'Y':'n';
  $('k-liq').className = 'v '+(r.liquidated?'bad':'good');
  const g = engine_kill_gate(r, 0.04, 0.15);
  $('k-gate').textContent = g.passed?'PASS':'FAIL';
  $('k-gate').className = 'v '+(g.passed?'good':'bad');
  $('kpi-seed').textContent = r.params.seed;
  const pills = [
    ['APY > 4%', g.apy_pass], ['DD < 15%', g.dd_pass], ['no liquidation', g.liq_pass]
  ];
  $('kpi-pills').innerHTML = pills.map(([n,ok])=>
    `<span class="pill ${ok?'pass':'fail'}">${ok?'✓':'✗'} ${n}</span>`).join('');
}
function engine_kill_gate(r,apy,dd){
  return {apy_pass:r.net_apy>apy, dd_pass:r.max_drawdown<dd, liq_pass:!r.liquidated,
          passed:r.net_apy>apy && r.max_drawdown<dd && !r.liquidated};
}

function renderEquity(curve){
  const labels = curve.map((_,i)=>i);
  const ds = {
    data: curve.map(v=>+v.toFixed(2)),
    borderColor:'#7aa2ff', borderWidth:1.5, pointRadius:0, fill:true,
    backgroundColor:'rgba(122,162,255,0.15)',
  };
  const cfg = {type:'line', data:{labels, datasets:[ds]},
    options:{
      animation:false,
      responsive:true,
      plugins:{legend:{display:false}, tooltip:{callbacks:{
        title:items=>'hour '+items[0].parsed.x, label:it=>'$'+it.parsed.y.toLocaleString()}}},
      scales:{x:{display:true,ticks:{maxTicksLimit:12}}, y:{ticks:{callback:v=>'$'+(v/1000).toFixed(0)+'k'}}},
    }
  };
  if(eqChart) eqChart.destroy();
  eqChart = new Chart($('equity'), cfg);
}

function renderMC(mc){
  $('mc-median').textContent = pct(mc.apy_median);
  $('mc-p10p90').textContent = pct(mc.apy_p10)+' / '+pct(mc.apy_p90);
  $('mc-worstdd').textContent = pct(mc.max_dd_max);
  const liq = mc.liquidations+'/'+mc.n_paths;
  $('mc-liq').textContent = liq;
  $('mc-liq').className = 'v '+(mc.liquidations>0?'bad':'good');

  // build histogram from apy_samples
  const apys = mc.apy_samples;
  const min = Math.min(...apys), max = Math.max(...apys);
  const bins = 30;
  const w = (max-min)/bins || 1;
  const counts = new Array(bins).fill(0);
  for(const a of apys){ const i = Math.min(bins-1, Math.floor((a-min)/w)); counts[i]++; }
  const labels = counts.map((_,i)=>(min + (i+0.5)*w).toFixed(3));

  const cfg = {type:'bar', data:{labels, datasets:[{
    data:counts,
    backgroundColor: labels.map(l=> parseFloat(l)>0?'#7aa2ff':'#f87171'),
  }]},
  options:{animation:false, responsive:true,
    plugins:{legend:{display:false}},
    scales:{x:{ticks:{maxTicksLimit:15}}, y:{ticks:{precision:0}}}}};
  if(apyChart) apyChart.destroy();
  apyChart = new Chart($('apy-hist'), cfg);
}

async function runOnce(){
  status('running backtest…');
  const {j:r, ms} = await api('/api/run', readParams());
  renderKPIs(r.result);
  renderEquity(r.equity_curve);
  status(`done in ${ms.toFixed(0)} ms · ${r.equity_curve.length} hours`);
}
async function runMC(){
  status('monte carlo…');
  const p = readParams();
  const {j:mc, ms} = await api('/api/mc', {...p, paths:parseInt($('paths').value), mc_seed:parseInt($('mcseed').value)});
  renderMC(mc);
  status(`MC done in ${ms.toFixed(0)} ms · ${mc.n_paths} paths`);
}
async function runSweep(){
  status('sweeping…');
  const p = readParams();
  const {j:sweep, ms} = await api('/api/sweep', {...p,
    hrs:[0.5,1.0,1.5,2.0,3.0], levs:[1.5,2.0,3.0,5.0], rebals:[6,12,24]});
  let html = '<table><tr><th>HR</th><th>Lev</th><th>rebal</th><th>APY</th><th>DD</th><th>Sharpe</th><th>fees</th><th>liq</th><th>gate</th></tr>';
  for(const r of sweep){
    const g = engine_kill_gate(r,0.04,0.15);
    html += `<tr class="${g.passed?'pass':'fail'}"><td>${r.params.hr_target}</td><td>${r.params.lev}</td>
      <td>${r.params.rebalance_interval_hours}h</td><td>${pct(r.net_apy)}</td><td>${pct(r.max_drawdown)}</td>
      <td>${r.sharpe.toFixed(2)}</td><td>$${r.fees_paid.toFixed(0)}</td><td>${r.liquidated?'Y':'n'}</td>
      <td>${g.passed?'PASS':'fail'}</td></tr>`;
  }
  html += '</table>';
  $('sweep-table').innerHTML = html;
  status(`sweep done in ${ms.toFixed(0)} ms · ${sweep.length} cells`);
}

$('run-btn').onclick = runOnce;
$('mc-btn').onclick = runMC;
$('sweep-btn').onclick = runSweep;
runOnce();
</script>
</body></html>
"""

STATIC = {
    "/": ("text/html; charset=utf-8", HTML.encode("utf-8")),
}


def _read_body(handler):
    length = int(handler.headers.get("Content-Length") or 0)
    if length == 0:
        return {}
    raw = handler.rfile.read(length).decode("utf-8")
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return {}


def _send(handler, payload, content_type="application/json"):
    body = json.dumps(payload).encode("utf-8") if content_type.startswith("application/json") \
        else payload if isinstance(payload, bytes) else payload.encode("utf-8")
    handler.send_response(200)
    handler.send_header("Content-Type", content_type)
    handler.send_header("Content-Length", str(len(body)))
    handler.send_header("Access-Control-Allow-Origin", "*")
    handler.end_headers()
    handler.wfile.write(body)


def _send_err(handler, code, msg):
    body = json.dumps({"error": msg}).encode("utf-8")
    handler.send_response(code)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


def _endpoint_run(handler, body):
    overrides = {k: v for k, v in body.items()
                 if k in engine.DEFAULTS}
    window = body.get("window_hours")
    r = engine.run_backtest(overrides=overrides, window_hours=window,
                            return_curve=True)
    result = {k: v for k, v in r.items() if k != "equity_curve"}
    if result.get("start_time"):
        result["start_time"] = result["start_time"].isoformat()
    return {"result": result, "equity_curve": r["equity_curve"]}


def _endpoint_mc(handler, body):
    overrides = {k: v for k, v in body.items()
                 if k in engine.DEFAULTS}
    paths = int(body.get("paths", 300))
    mc_seed = int(body.get("mc_seed", 1000))
    window = body.get("window_hours")
    return engine.monte_carlo(num_paths=paths, seed=mc_seed,
                              overrides=overrides, window_hours=window)


def _endpoint_sweep(handler, body):
    base = {k: v for k, v in body.items() if k in engine.DEFAULTS}
    hrs = body.get("hrs") or [0.5, 1.0, 1.5, 2.0, 3.0]
    levs = body.get("levs") or [1.5, 2.0, 3.0, 5.0]
    rebals = body.get("rebals") or [6, 12, 24]
    window = body.get("window_hours")
    out = []
    for hr in hrs:
        for lev in levs:
            for rebal in rebals:
                ov = dict(base)
                ov.update({"hr_target": hr, "lev": lev,
                           "rebalance_interval_hours": rebal})
                r = engine.run_backtest(overrides=ov, window_hours=window)
                out.append({k: v for k, v in r.items() if k != "params"} | {"params": r["params"]})
    return out


class Handler(BaseHTTPRequestHandler):
    server_version = "hypeback/0.1"

    def log_message(self, fmt, *args):
        pass  # silence access log

    def do_GET(self):
        if self.path in STATIC:
            body = STATIC[self.path][1]
            self.send_response(200)
            self.send_header("Content-Type", STATIC[self.path][0])
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            _send_err(self, 404, "not found")

    def do_POST(self):
        if self.path == "/api/run":
            _send(self, _endpoint_run(self, _read_body(self)))
        elif self.path == "/api/mc":
            t0 = time.time()
            _send(self, _endpoint_mc(self, _read_body(self)))
        elif self.path == "/api/sweep":
            _send(self, _endpoint_sweep(self, _read_body(self)))
        else:
            _send_err(self, 404, "not found")


def serve(port=8760):
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print(f"hypeback web UI: http://127.0.0.1:{port}")
    print("Ctrl-C to stop")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nbye")
        server.server_close()
