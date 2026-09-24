# hypercore-dev-harness

Local development harness for the `hypeback` Solidity contracts against
a **mock** HyperCore market-data precompile, while Kinetiq has not
yet published the real precompile address on Elysium mainnet.

```
hypeback/
  solidity/src/keeper/RegimeDetector.sol    # uses IMarketDataFeed
  solidity/src/keeper/YieldAggregator.sol
  lib/
    forge-std/                              # submodule
    hypercore-dev-harness/                  # <- this directory
      src/
        IHyperCorePrecompile.sol            # speculative ABI (matches hypeback/hypercore.py)
        HyperCoreTypes                      # shared struct types (Candle / FundingSnapshot / MarketData)
        HyperCorePrecompileMock.sol         # stateful mock, prime-during-test
        HyperCoreSnapshotMock.sol           # read-only mock, prime-in-constructor
        HyperCoreFixture.sol                # CREATE2 deployment with deterministic address
        MarketDataFeedAdapter.sol           # bridges precompile -> RegimeDetector's IMarketDataFeed
      test/                                 # 53 passing tests (forge test)
      scripts/
        generate-fixture.ts                 # JSON -> Solidity SnapshotInput arrays
      examples/                             # symlink to test/, tutorial-style walkthrough
      README.md                             # this file
      SECURITY.md                           # what is NOT in this repo (no secrets, no pk, no RPC URLs)
      foundry.toml
```

## Why does this exist?

`RegimeDetector` calls `IMarketDataFeed` — an inline interface that
expects a HyperCore market-data precompile to be deployed at a fixed
address. As of writing, Kinetiq has not published the real precompile
on Elysium mainnet; the placeholder address is
`0x000000000000000000000000000000000000C0DE`.

This harness lets you:

1. Write and run Solidity tests for `RegimeDetector` and
   `YieldAggregator` today, without waiting for Kinetiq.
2. Pin down the adapter contract (`MarketDataFeedAdapter`) that
   will be the bridge between the real precompile and `IMarketDataFeed`
   once Kinetiq publishes the ABI.
3. Replay frozen market snapshots deterministically for regression
   tests that must produce identical output year over year.

## Quick start

```bash
# 1. Run all tests in the harness.
cd hypeback/lib/hypercore-dev-harness
forge test

# 2. Generate a fixture from a JSON capture.
node --experimental-strip-types scripts/generate-fixture.ts \
    --in data/hype-2026-09-24.json \
    --out test/fixtures/HYPE.ts.sol

# 3. Run just one suite.
forge test --match-path "test/AdapterIntegration.t.sol"
```

## Full guide

### Value conventions

All values in this harness follow Hyperliquid's wire format:

| Field           | Unit                       | Scale      |
| --------------- | -------------------------- | ---------- |
| Prices          | native units               | 1e6        |
| Funding rates   | native units (100% = 1)    | 1e6        |
| Volumes         | base units                 | 1e6        |
| Timestamps      | unix seconds               | —          |
| `fundingRateBps` (in RegimeDetector) | bps of 10000 | — |

### Regime thresholds (from `RegimeDetector.sol`)

| Regime           | Trigger                                   |
| ---------------- | ----------------------------------------- |
| `FUNDING_STRONG` | `fundingApyBps >= 800`                    |
| `FUNDING_WEAK`   | `300 <= fundingApyBps < 800`              |
| `FUNDING_NEG`    | `fundingRateBps < 0`                      |
| `HIGH_VOL`       | `realizedVolBps >= 9000`                  |

Note: `fundingApyBps_24h` in the snapshot is a `uint256` that stores
`apyAbs = apyBps > 0 ? uint256(apyBps) : 0` — so for negative funding
it is `0`, not the absolute value. That's by design (the regime is
encoded in the `regime` enum, not in the magnitude field).

### Mock flavors

Two mocks ship with the harness; pick based on your test shape:

**`HyperCorePrecompileMock`** — stateful, prime during the test.

```solidity
HyperCorePrecompileMock mock = new HyperCorePrecompileMock();
mock.setCandles("HYPE", "1h", _candles());
mock.setFunding("HYPE", _funding());
mock.setMarketData("HYPE", _marketData());
adapter = new MarketDataFeedAdapter(address(mock));
detector = new RegimeDetector(IMarketDataFeed(address(adapter)));
```

Use this for ad-hoc unit tests that need to mutate the precompile
between assertions.

**`HyperCoreSnapshotMock`** — read-only, prime in the constructor.

```solidity
HyperCoreSnapshotMock snap = new HyperCoreSnapshotMock(
    Fixture.candles(), Fixture.funding(), Fixture.market()
);
adapter = new MarketDataFeedAdapter(address(snap));
detector = new RegimeDetector(IMarketDataFeed(address(adapter)));
```

Use this for reproducibility tests. The fixture is generated from a
JSON capture by `scripts/generate-fixture.ts` and checked into the
repo. Same input → same regime, forever.

### CREATE2 fixture address

`HyperCoreFixture` deploys a fresh mock deterministically:

```solidity
HyperCoreFixture fixture = new HyperCoreFixture();
address pc = fixture.deployDeterministic();
// pc is stable across test runs (given the same bytecode).
```

Tests in `test/FixtureAtFixedAddress.t.sol` verify the address is
deterministic. If you need to inject the address into a contract's
immutable constructor arg, call `deployDeterministic()` once in
`setUp()` and store the address.

### The adapter: `MarketDataFeedAdapter`

`RegimeDetector` expects `IMarketDataFeed`:

```solidity
function fundingRateBps(string calldata coin) external view returns (int64);
function realizedVolBps(string calldata coin, uint32 lookbackHrs)
    external view returns (uint256);
function spotPrice(string calldata coin) external view returns (uint256);
function perpMarkPrice(string calldata coin) external view returns (uint256);
```

The real HyperCore precompile returns `fundingRate` (1e6-scaled),
`Candle` OHLCV arrays, and `MarketData { spotPrice, oraclePrice, timestamp }`.
`MarketDataFeedAdapter` bridges:

| `IMarketDataFeed`       | Source in precompile                            | Transformation                                              |
| ----------------------- | ----------------------------------------------- | ----------------------------------------------------------- |
| `fundingRateBps(coin)`  | `fundingSnapshot(coin, 1)[0].fundingRate`       | bps = rate / 100 (rate is 1e6-scaled)                       |
| `realizedVolBps(coin, hrs)` | trailing candles from `candleSnapshot`      | hourly sigma from log returns, annualized by `sqrt(hrs)`    |
| `spotPrice(coin)`       | `marketData(coin).spotPrice`                    | returned as-is (already 1e6-scaled)                         |
| `perpMarkPrice(coin)`   | `marketData(coin).oraclePrice` or spot fallback | returns spot if oracle is 0/non-positive                    |

The Taylor log approximation `ln(x/y) ≈ 2(x-y)/(x+y)` is used for
`realizedVolBps`. It's second-order accurate for |move| < ~25% and
saturates near `INT64_MAX / 100` for pathological inputs — see
`test_fuzz_realizedVolBps_neverOverflows`.

### Fuzz tests

`test/fuzz-adapter.t.sol` contains 6 fuzz tests + 3 targeted checks:

- `fundingRateBps_alwaysInInt64Range(int64)`
- `fundingRateBps_conversion_isRateOver100(int24)`
- `spotPrice_returnsUint256(int64,int64)`
- `perpMarkPrice_fallsBackToSpot_whenOracleNonPositive(int64,int64)`
- `realizedVolBps_neverOverflows(uint16)`
- `realizedVolBps_monotonicInMoveSize(int8)`
- `adapter_coinIsolation`
- `realizedVolBps_emptyFeed_returnsZero`
- `realizedVolBps_largerMovesGiveLargerVol`

### The generator script

`scripts/generate-fixture.ts` is a Node.js script (Node >= 18, uses
`--experimental-strip-types` for TypeScript execution). It takes a
JSON capture of Hyperliquid-style data and emits a Solidity file with
three `external pure` functions returning `SnapshotInput.*` arrays.

Input schema (Hyperliquid-compatible):

```json
{
  "candles": [
    {"t": 1700000000, "s": "HYPE", "i": "1h",
     "o": 99995000, "h": 100005000, "l": 99990000, "c": 100000000, "v": 1000000}
  ],
  "funding": [
    {"t": 1700003600, "s": "HYPE", "r": 5000, "oi": 1000000}
  ],
  "market": [
    {"s": "HYPE", "spot": 100005000, "oracle": 100005500, "t": 1700003600}
  ]
}
```

Timestamps in seconds (or ms; the script normalises anything > 1e12
to ms). Prices/volumes/funding are 1e6-scaled.

### When Kinetiq publishes the real precompile

The interface in `src/IHyperCorePrecompile.sol` is **speculative**.
It mirrors the Python client (`hypeback/hypercore.py`) vocabulary:
`candleSnapshot`, `fundingSnapshot`, `marketData`. If Kinetiq's
final spec uses different names (e.g. `getCandles` / `getFundingHistory`
/ `getPrice`), only two files should change:

1. `src/IHyperCorePrecompile.sol` — update the method names and
   parameter shapes.
2. `src/MarketDataFeedAdapter.sol` — adjust the adapter to call the
   new names.

The mock contracts, the fixture library, and all tests stay the
same. `RegimeDetector` and `YieldAggregator` (in `hypeback/solidity/`)
should not need to change — that's the whole point of the adapter.

## Layout

| File | Purpose |
| ---- | ------- |
| `src/IHyperCorePrecompile.sol` | Speculative ABI for the Elysium precompile. |
| `src/types.sol` | `HyperCoreTypes` library with `Candle`, `FundingSnapshot`, `MarketData`. |
| `src/HyperCorePrecompileMock.sol` | Stateful mock, primed via setters. |
| `src/HyperCoreSnapshotMock.sol` | Read-only mock, primed in constructor. |
| `src/HyperCoreFixture.sol` | Deployment helper with CREATE2 support. |
| `src/MarketDataFeedAdapter.sol` | Bridges precompile -> `IMarketDataFeed`. |
| `test/MockSnapshot.t.sol` | Unit tests for both mocks. |
| `test/FixtureAtFixedAddress.t.sol` | CREATE2 determinism tests. |
| `test/AdapterIntegration.t.sol` | End-to-end: mock → adapter → `RegimeDetector`. |
| `test/fuzz-adapter.t.sol` | Fuzz + boundary tests for the adapter. |
| `test/fixture-smoke-test.t.sol` | Verifies generated fixtures compile and load. |
| `test/using-the-harness.t.sol` | Tutorial walkthrough (also in `examples/`). |
| `scripts/generate-fixture.ts` | JSON → Solidity fixture generator. |

## Running

```bash
cd hypeback/lib/hypercore-dev-harness
forge test                                  # all 53 tests
forge test --match-path "test/AdapterIntegration.t.sol"  # one suite
forge test --match-test "test_DetectorFundingStr*"       # by name
```

Expected: **53 passed, 0 failed** in well under a second.

## License

Apache-2.0 (same as the parent `hypeback` repo).
