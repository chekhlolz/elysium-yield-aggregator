# Generated fixtures

Drop the output of `scripts/generate-fixture.ts` here. Each file is a
Solidity library exposing `candles()`, `funding()`, `market()` that
return `SnapshotInput` arrays, ready for `HyperCoreSnapshotMock`.

Generate one:

```
node --experimental-strip-types scripts/generate-fixture.ts \
    --in data/hype-2026-09-24.json \
    --out test/fixtures/HYPE.ts.sol
```
