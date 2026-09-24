#!/usr/bin/env node
/**
 * generate-fixture.ts
 *
 * Convert Hyperliquid-style API JSON (candles, funding, market data)
 * into a Solidity file that constructs the `SnapshotInput` arrays
 * consumed by `HyperCoreSnapshotMock`.
 *
 * WHY THIS EXISTS:
 *
 *   The harness ships two mock flavors:
 *     - `HyperCorePrecompileMock` — stateful, prime-during-test.
 *     - `HyperCoreSnapshotMock` — read-only, prime-in-constructor.
 *
 *   For reproducibility tests (same input → same regime, year over
 *   year), you want to feed `HyperCoreSnapshotMock` a frozen
 *   snapshot. This script is the bridge from a JSON capture of real
 *   Hyperliquid data to a Solidity initializer.
 *
 * USAGE:
 *
 *   node scripts/generate-fixture.ts --in data/hype-2026-09-24.json \
 *       --out test/fixtures/HYPE.ts.sol --coin HYPE
 *
 * INPUT FORMAT:
 *
 *   {
 *     "candles": [
 *       {
 *         "t": 1700000000,    // start time, unix SECONDS
 *         "s": "HYPE",         // coin
 *         "i": "1h",          // interval
 *         "o": 100000000,     // open (1e6-scaled)
 *         "c": 100005000,     // close (1e6-scaled)
 *         "h": 100010000,     // high
 *         "l": 99995000,      // low
 *         "v": 1000000        // volume (1e6-scaled base units)
 *       },
 *       ...
 *     ],
 *     "funding": [
 *       {
 *         "t": 1700003600,
 *         "s": "HYPE",
 *         "r": 5000,          // fundingRate, 1e6-scaled
 *         "oi": 1000000       // open interest, 1e6-scaled
 *       },
 *       ...
 *     ],
 *     "market": [
 *       {
 *         "s": "HYPE",
 *         "spot": 100005000,
 *         "oracle": 100005500,
 *         "t": 1700003600
 *       }
 *     ]
 *   }
 *
 * The field names mirror Hyperliquid's REST shape; rename at the
 * boundary if your feed uses different keys (the normalisation is
 * one function below).
 *
 * OUTPUT:
 *
 *   A Solidity file with three top-level memory arrays that match
 *   the `HyperCoreSnapshotMock` constructor signature:
 *
 *     SnapshotInput.CandleEntry[] memory _candles = new ...;
 *     SnapshotInput.FundingEntry[] memory _funding = new ...;
 *     SnapshotInput.MarketEntry[] memory _market = new ...;
 *
 *   Each entry is appended in input order. Callers are responsible
 *   for sorting ascending by startTime / timestamp before passing
 *   to the constructor (the snapshot mock does not re-sort).
 *
 * This script has zero npm dependencies. It runs on Node >= 18.
 */

import * as fs from "node:fs";
import * as path from "node:path";

// ---- CLI ----

type Args = {
    input: string;
    output: string;
    coin: string;
    indent: string;
};

function parseArgs(argv: string[]): Args {
    const out: Partial<Args> = {};
    for (let i = 0; i < argv.length; i++) {
        const a = argv[i];
        if (a === "--in" || a === "-i") out.input = argv[++i];
        else if (a === "--out" || a === "-o") out.output = argv[++i];
        else if (a === "--coin" || a === "-c") out.coin = argv[++i];
        else if (a === "--indent") out.indent = argv[++i];
        else if (a === "--help" || a === "-h") {
            console.log(USAGE);
            process.exit(0);
        } else {
            throw new Error(`Unknown arg: ${a}`);
        }
    }
    if (!out.input || !out.output) {
        throw new Error("Missing --in and/or --out. See --help.");
    }
    return {
        input: out.input,
        output: out.output,
        coin: out.coin ?? "HYPE",
        indent: out.indent ?? "    ",
    };
}

const USAGE = `Usage: node scripts/generate-fixture.ts --in <json> --out <sol> [--coin HYPE]

Generate a Solidity file that constructs SnapshotInput arrays for
HyperCoreSnapshotMock, from a JSON capture of Hyperliquid-style data.

See the comment block at the top of this file for the input schema.
`;

// ---- JSON → SnapshotInput ----

type JsonCandle = {
    t: number;
    s: string;
    i: string;
    o: number;
    c: number;
    h: number;
    l: number;
    v: number;
    /**
     * End time in seconds. Optional: if omitted, computed as
     * `t + intervalSeconds(i)`. Always emitted in the output.
     */
    e?: number;
};

type JsonFunding = {
    t: number;
    s: string;
    r: number;
    oi: number;
};

type JsonMarket = {
    s: string;
    spot: number;
    oracle: number;
    t: number;
};

type FixtureInput = {
    candles: JsonCandle[];
    funding: JsonFunding[];
    market: JsonMarket[];
};

function normaliseTimestamps(obj: FixtureInput): FixtureInput {
    // Hyperliquid's REST API returns milliseconds in some endpoints
    // and seconds in others. Any value > 1e12 is clearly ms.
    // The harness expects SECONDS everywhere.
    const isMs = (t: number): boolean => t > 1e12;
    return {
        candles: obj.candles.map((c) => {
            const t = isMs(c.t) ? Math.floor(c.t / 1000) : c.t;
            const e = c.e !== undefined
                ? (isMs(c.e) ? Math.floor(c.e / 1000) : c.e)
                : t + intervalSeconds(c.i);
            return { ...c, t, e };
        }),
        funding: obj.funding.map((f) => ({
            ...f,
            t: isMs(f.t) ? Math.floor(f.t / 1000) : f.t,
        })),
        market: obj.market.map((m) => ({
            ...m,
            t: isMs(m.t) ? Math.floor(m.t / 1000) : m.t,
        })),
    };
}

/** Map interval labels to seconds. Covers the canonical Hyperliquid set. */
function intervalSeconds(i: string): number {
    switch (i) {
        case "1m": return 60;
        case "3m": return 180;
        case "5m": return 300;
        case "15m": return 900;
        case "30m": return 1800;
        case "1h": return 3600;
        case "4h": return 14400;
        case "1d": return 86400;
        case "1w": return 604800;
        default:
            // Unknown interval: emit t+0 as endTime. The snapshot mock
            // does not validate interval arithmetic, so this won't
            // crash; it just means candleSnapshot time-window filtering
            // will be noisier. Callers should pass real intervals.
            return 0;
    }
}

function sortByTimestamp(
    arr: Array<{ t: number }>,
): Array<{ t: number }> {
    return [...arr].sort((a, b) => a.t - b.t);
}

// ---- Solidity codegen ----

const INDENT = "    ";

function solidifyInt(n: number): string {
    // Emit as a plain integer literal. Solidity handles large ints natively.
    return `${Math.trunc(n)}`;
}

function emitCandleEntry(c: JsonCandle, indent: string): string {
    const endTs = c.e !== undefined ? Math.trunc(c.e) : 0;
    // Solidity constructor-assignment syntax is `Type({...})` — the
    // closing sequence is `})`: `}` closes the brace `{`, then `)`
    // closes the paren `(`. Same for the nested struct.
    //
    // We use plain string concatenation (not template literals) here
    // so each emitted line is explicit and easy to reason about.
    const L1 = indent;                              // outer indent
    const L2 = indent + INDENT;                     // entry fields
    const L3 = indent + INDENT + INDENT;            // nested struct fields
    const lines: string[] = [];
    lines.push(`${L1}SnapshotInput.CandleEntry({`);
    lines.push(`${L2}coin: "${c.s}",`);
    lines.push(`${L2}interval: "${c.i}",`);
    lines.push(`${L2}candle: HyperCoreTypes.Candle({`);
    lines.push(`${L3}open: ${solidifyInt(c.o)},`);
    lines.push(`${L3}high: ${solidifyInt(c.h)},`);
    lines.push(`${L3}low: ${solidifyInt(c.l)},`);
    lines.push(`${L3}close: ${solidifyInt(c.c)},`);
    lines.push(`${L3}startTime: ${solidifyInt(c.t)},`);
    lines.push(`${L3}endTime: ${solidifyInt(endTs)},`);
    lines.push(`${L3}volume: ${solidifyInt(c.v)}`);
    lines.push(`${L2}})`);  // close Candle({...})  -> brace-then-paren
    lines.push(`${L1}})`);  // close CandleEntry({...})
    return lines.join("\n");
}

function emitFundingEntry(f: JsonFunding, indent: string): string {
    const L1 = indent;
    const L2 = indent + INDENT;
    const L3 = indent + INDENT + INDENT;
    const lines: string[] = [];
    lines.push(`${L1}SnapshotInput.FundingEntry({`);
    lines.push(`${L2}coin: "${f.s}",`);
    lines.push(`${L2}tick: HyperCoreTypes.FundingSnapshot({`);
    lines.push(`${L3}fundingRate: ${solidifyInt(f.r)},`);
    lines.push(`${L3}oi: ${solidifyInt(f.oi)},`);
    lines.push(`${L3}timestamp: ${solidifyInt(f.t)}`);
    lines.push(`${L2}})`);  // close FundingSnapshot({...})
    lines.push(`${L1}})`);  // close FundingEntry({...})
    return lines.join("\n");
}

function emitMarketEntry(m: JsonMarket, indent: string): string {
    const L1 = indent;
    const L2 = indent + INDENT;
    const L3 = indent + INDENT + INDENT;
    const lines: string[] = [];
    lines.push(`${L1}SnapshotInput.MarketEntry({`);
    lines.push(`${L2}coin: "${m.s}",`);
    lines.push(`${L2}data: HyperCoreTypes.MarketData({`);
    lines.push(`${L3}spotPrice: ${solidifyInt(m.spot)},`);
    lines.push(`${L3}oraclePrice: ${solidifyInt(m.oracle)},`);
    lines.push(`${L3}timestamp: ${solidifyInt(m.t)}`);
    lines.push(`${L2}})`);  // close MarketData({...})
    lines.push(`${L1}})`);  // close MarketEntry({...})
    return lines.join("\n");
}

function emitFixture(
    data: FixtureInput,
    indent: string,
): string {
    const candles = sortByTimestamp(data.candles).map((c) => emitCandleEntry(c, indent));
    const funding = sortByTimestamp(data.funding).map((f) => emitFundingEntry(f, indent));
    // Market data is a single snapshot per coin; last write wins.
    // We sort ascending by timestamp so the latest entry is the
    // final one in the array (the constructor uses last-write-wins).
    const market = sortByTimestamp(data.market).map((m) => emitMarketEntry(m, indent));

    // NOTE ON WHY THESE ARE FUNCTIONS, NOT CONSTANTS:
    // Solidity does not allow top-level `constant` memory arrays of
    // structs (the constant keyword only supports value types and
    // string/bytes literals). Memory arrays must be returned by
    // functions. Callers do `Fixture.candles()` etc. in their
    // constructor call. See Solidity docs §Constants.
    const lines: string[] = [];
    lines.push("// SPDX-License-Identifier: Apache-2.0");
    lines.push("// AUTO-GENERATED by scripts/generate-fixture.ts - do not edit.");
    lines.push("// Source: " + sourceLabel);
    lines.push("// Generated at: " + new Date().toISOString());
    lines.push("");
    lines.push("pragma solidity 0.8.26;");
    lines.push("");
    lines.push("import {HyperCoreTypes} from \"../../src/types.sol\";");
    lines.push("import {SnapshotInput} from \"../../src/HyperCoreSnapshotMock.sol\";");
    lines.push("");
    lines.push("/**");
    lines.push(" * @dev Frozen market snapshot for HyperCoreSnapshotMock.");
    lines.push(" *");
    lines.push(" * Use this in a test setUp():");
    lines.push(" *");
    lines.push(" *     HyperCoreSnapshotMock snap =");
    lines.push(" *         new HyperCoreSnapshotMock(");
    lines.push(" *             Fixture.candles(), Fixture.funding(), Fixture.market()");
    lines.push(" *         );");
    lines.push(" *");
    lines.push(" * Snapshot: " + candles.length + " candles, " + funding.length +
               " funding ticks, " + market.length + " market data.");
    lines.push(" */");
    lines.push("library Fixture {");
    lines.push("");
    lines.push(`    function candles() external pure returns (SnapshotInput.CandleEntry[] memory)`);
    lines.push(`    {`);
    lines.push(`        SnapshotInput.CandleEntry[] memory arr = new SnapshotInput.CandleEntry[](${candles.length});`);
    candles.forEach((entry, idx) => {
        // Strip the outermost leading/trailing whitespace (the
        // single-line open of `SnapshotInput.CandleEntry({` and
        // the closing `);`) but preserve all inner indentation.
        const inner = stripOuterIndent(entry);
        lines.push(`        arr[${idx}] = ${inner};`);
    });
    lines.push(`        return arr;`);
    lines.push(`    }`);
    lines.push("");
    lines.push(`    function funding() external pure returns (SnapshotInput.FundingEntry[] memory)`);
    lines.push(`    {`);
    lines.push(`        SnapshotInput.FundingEntry[] memory arr = new SnapshotInput.FundingEntry[](${funding.length});`);
    funding.forEach((entry, idx) => {
        lines.push(`        arr[${idx}] = ${stripOuterIndent(entry)};`);
    });
    lines.push(`        return arr;`);
    lines.push(`    }`);
    lines.push("");
    lines.push(`    function market() external pure returns (SnapshotInput.MarketEntry[] memory)`);
    lines.push(`    {`);
    lines.push(`        SnapshotInput.MarketEntry[] memory arr = new SnapshotInput.MarketEntry[](${market.length});`);
    market.forEach((entry, idx) => {
        lines.push(`        arr[${idx}] = ${stripOuterIndent(entry)};`);
    });
    lines.push(`        return arr;`);
    lines.push(`    }`);
    lines.push("}");
    return lines.join("\n") + "\n";
}

/**
 * Strip exactly one level of common leading whitespace from the
 * multi-line entry string. The emit*Entry helpers indent everything
 * by the outer `indent` parameter; we don't want that when embedding
 * inside `arr[i] = ...;`, so we trim one level.
 */
function stripOuterIndent(entry: string): string {
    // Trim trailing newline, then strip common leading whitespace
    // from every line. This gives a compact form suitable for embedding
    // inside `arr[i] = ...;`.
    let s = entry.replace(/\n+$/, "");
    const lines = s.split("\n");
    let min = Number.POSITIVE_INFINITY;
    for (const line of lines) {
        if (line.trim() === "") continue;
        const m = line.match(/^( +)/);
        if (m) min = Math.min(min, m[1].length);
    }
    if (!isFinite(min) || min === 0) return s;
    return lines.map((l) => l.slice(min)).join("\n");
}

let sourceLabel = "<unknown>";

// ---- main ----

function main(argv: string[]): void {
    const args = parseArgs(argv);
    sourceLabel = args.input;
    const raw = fs.readFileSync(args.input, "utf8");
    const data = normaliseTimestamps(JSON.parse(raw) as FixtureInput);

    // Basic shape validation.
    if (!Array.isArray(data.candles)) throw new Error("candles: must be array");
    if (!Array.isArray(data.funding)) throw new Error("funding: must be array");
    if (!Array.isArray(data.market)) throw new Error("market: must be array");
    if (data.candles.length === 0 && data.funding.length === 0) {
        throw new Error("Empty fixture: at least one of candles/funding required.");
    }

    const out = emitFixture(data, args.indent);
    fs.mkdirSync(path.dirname(path.resolve(args.output)), { recursive: true });
    fs.writeFileSync(args.output, out);
    console.log(
        `Wrote ${args.output} (${data.candles.length} candles, ` +
        `${data.funding.length} funding, ${data.market.length} market data)`
    );
}

if (process.argv[1] && process.argv[1].endsWith("generate-fixture.ts")) {
    try {
        main(process.argv.slice(2));
    } catch (e) {
        console.error(e instanceof Error ? e.message : e);
        process.exit(1);
    }
}
