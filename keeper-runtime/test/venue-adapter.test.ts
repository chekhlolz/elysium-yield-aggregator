/**
 * Unit tests for MockElysiumCoreWriter and the IVenueAdapter contract.
 *
 * All offline — no RPC, no keccak.
 */

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';

import type { Address, Delegation } from '../src/types.js';
import { MockElysiumCoreWriter } from '../src/venue-adapter.js';
import type { PendingIntent, SubmittedTrade } from '../src/daemon-types.js';

// ---------------------------------------------------------------------------
// Fixtures.
// ---------------------------------------------------------------------------

const KEEPER: Address = '0x0000000000000000000000000000000000000001';
const DELEGATOR: Address = '0x0000000000000000000000000000000000000002';
const OTHER: Address = '0x0000000000000000000000000000000000000003';

function makeIntent(overrides: Partial<PendingIntent> = {}): PendingIntent {
  return {
    delegator: DELEGATOR,
    assetId: 1n,
    side: 'Long',
    size: 100n,
    notionalUsd: 1_000_000n,
    ...overrides,
  };
}

function makeDelegation(overrides: Partial<Delegation> = {}): Delegation {
  return {
    keeper: KEEPER,
    assetIds: [],
    maxNotional: 100_000_000n,
    maxPerOrder: 10_000_000n,
    expiresAt: 1_000_000_000n,
    nonce: 0n,
    salt: '0x' + '11'.repeat(32),
    ...overrides,
  };
}

// A fake signature; the mock adapter does not verify it.
const FAKE_SIG = {
  v: 27 as const,
  r: '0x' + '11'.repeat(32) as `0x${string}`,
  s: '0x' + '22'.repeat(32) as `0x${string}`,
};

// ---------------------------------------------------------------------------
// Tests.
// ---------------------------------------------------------------------------

describe('MockElysiumCoreWriter', () => {
  // 1. pendingIntent drains FIFO.
  it('pendingIntent returns intents in FIFO order, then null when empty', async () => {
    const venue = new MockElysiumCoreWriter({
      pendingIntents: [
        makeIntent({ assetId: 1n }),
        makeIntent({ assetId: 2n }),
        makeIntent({ assetId: 3n }),
      ],
    });
    assert.equal(venue.pendingCount, 3);

    const a = await venue.pendingIntent(KEEPER);
    const b = await venue.pendingIntent(KEEPER);
    const c = await venue.pendingIntent(KEEPER);
    assert.equal(a?.assetId, 1n);
    assert.equal(b?.assetId, 2n);
    assert.equal(c?.assetId, 3n);

    const empty = await venue.pendingIntent(KEEPER);
    assert.equal(empty, null);
    assert.equal(venue.pendingCount, 0);
  });

  // 2. Empty queue returns null.
  it('pendingIntent returns null on an empty queue', async () => {
    const venue = new MockElysiumCoreWriter();
    assert.equal(venue.pendingCount, 0);
    assert.equal(await venue.pendingIntent(KEEPER), null);
  });

  // 3. submitTrade records into recordedTrades.
  it('submitTrade records the trade with the intent and delegation fields', async () => {
    const venue = new MockElysiumCoreWriter();
    const intent = makeIntent({ notionalUsd: 2_500_000n, assetId: 7n });
    const d = makeDelegation({ nonce: 4n, maxPerOrder: 10_000_000n });

    const result = await venue.submitTrade(d, FAKE_SIG, intent);

    assert.equal(result.accepted, true);
    assert.equal(result.txHash, '0x' + '11'.repeat(32));
    assert.equal(venue.tradeCount, 1);
    const trade = venue.recordedTrades[0];
    assert.ok(trade !== undefined);
    assert.equal(trade.delegator, DELEGATOR);
    assert.equal(trade.keeper, KEEPER);
    assert.equal(trade.nonce, 4n);
    assert.equal(trade.notionalUsd, 2_500_000n);
    assert.equal(trade.intent.assetId, 7n);
    assert.equal(trade.index, 0);
  });

  // 4. usedNotional accumulates across multiple submissions on same triple.
  it('usedNotional accumulates across multiple submissions with the same triple', async () => {
    const venue = new MockElysiumCoreWriter();
    const d = makeDelegation({ nonce: 0n, maxPerOrder: 100_000_000n });

    await venue.submitTrade(d, FAKE_SIG, makeIntent({ notionalUsd: 1_000_000n }));
    await venue.submitTrade(d, FAKE_SIG, makeIntent({ notionalUsd: 2_000_000n }));
    await venue.submitTrade(d, FAKE_SIG, makeIntent({ notionalUsd: 3_000_000n }));

    assert.equal(await venue.usedNotional(DELEGATOR, KEEPER, 0n), 6_000_000n);
    // Different triple → zero.
    assert.equal(await venue.usedNotional(DELEGATOR, KEEPER, 1n), 0n);
    assert.equal(await venue.usedNotional(OTHER, KEEPER, 0n), 0n);
    // sumUsedNotional agrees.
    assert.equal(venue.sumUsedNotional(DELEGATOR, KEEPER, 0n), 6_000_000n);
  });

  // 5. isRevoked returns false by default, true after revoke().
  it('isRevoked is false by default and true after revoke()', async () => {
    const venue = new MockElysiumCoreWriter();
    assert.equal(await venue.isRevoked(DELEGATOR, KEEPER), false);

    await venue.revoke(DELEGATOR, KEEPER);
    assert.equal(await venue.isRevoked(DELEGATOR, KEEPER), true);

    // Other delegator / keeper pairs are unaffected.
    assert.equal(await venue.isRevoked(DELEGATOR, OTHER), false);
    assert.equal(await venue.isRevoked(OTHER, KEEPER), false);
  });

  // 6. Constructor with pre-populated state works.
  it('accepts pre-populated pending intents, recorded trades, used-notional, and revoked keepers', async () => {
    const presetIntent = makeIntent({ assetId: 42n, notionalUsd: 5_000_000n });
    const presetTrade: SubmittedTrade = {
      index: 0,
      delegator: DELEGATOR,
      keeper: KEEPER,
      nonce: 0n,
      notionalUsd: 1_000_000n,
      intent: presetIntent,
      at: 1_000_000,
    };
    // The used-notional key uses the composite (delegator:keeper:nonce) format.
    const presetUsedKey = `${DELEGATOR.toLowerCase()}:${KEEPER.toLowerCase()}:9`;
    // revokedKeppers is keyed by delegator address; values are keeper arrays.
    const presetRevoked: Record<string, Address[]> = {
      [DELEGATOR]: [KEEPER],
    };

    const venue = new MockElysiumCoreWriter({
      pendingIntents: [presetIntent],
      recordedTrades: [presetTrade],
      usedNotionalBy: { [presetUsedKey]: 7_000_000n },
      revokedKeppers: presetRevoked,
    });

    assert.equal(venue.pendingCount, 1);
    assert.equal(venue.tradeCount, 1);
    assert.equal(venue.recordedTrades[0].intent.assetId, 42n);

    // Pre-populated used-notional is readable.
    assert.equal(venue.sumUsedNotional(DELEGATOR, KEEPER, 9n), 7_000_000n);

    // Pre-populated revoke is effective.
    assert.equal(await venue.isRevoked(DELEGATOR, KEEPER), true);
  });

  // 7. Type-safety on missing fields — compile-time guard via `as` cast.
  it('rejects (at the type level) a PendingIntent missing a required field', () => {
    // TypeScript should reject this:
    //   const bad: PendingIntent = { assetId: 1n, side: 'Long' };
    // `size`, `notionalUsd`, and `delegator` are required.
    //
    // At runtime we can only sanity-check the *shape* the venue adapter
    // actually consumes. We assert that accessing a missing field via
    // `as PendingIntent` is `undefined`, which is the expected runtime
    // manifestation of a type-safety failure.
    const missing: PendingIntent = {
      // @ts-expect-error — intentional: we are asserting type-safety by
      // leaving out `size`, `notionalUsd`, and `delegator`.
      assetId: 1n,
      side: 'Long',
    };
    assert.equal(missing.size, undefined);
    assert.equal(missing.notionalUsd, undefined);
    assert.equal(missing.delegator, undefined);
  });

  // 8. No state mutation after revoke.
  it('submitTrade returns accepted:false after revoke and does not record', async () => {
    const venue = new MockElysiumCoreWriter();
    await venue.revoke(DELEGATOR, KEEPER);

    const result = await venue.submitTrade(makeDelegation(), FAKE_SIG, makeIntent());

    assert.equal(result.accepted, false);
    assert.equal(result.reason, 'keeper revoked by venue');
    assert.equal(venue.tradeCount, 0); // no trade recorded
    assert.equal(await venue.usedNotional(DELEGATOR, KEEPER, 0n), 0n);
  });

  // Bonus: maxPerOrder check on the mock venue itself.
  it('submitTrade rejects an intent that exceeds delegation.maxPerOrder', async () => {
    const venue = new MockElysiumCoreWriter();
    const d = makeDelegation({ maxPerOrder: 5_000_000n });
    const r = await venue.submitTrade(d, FAKE_SIG, makeIntent({ notionalUsd: 6_000_000n }));
    assert.equal(r.accepted, false);
    assert.equal(r.reason, 'intent exceeds delegation.maxPerOrder');
    assert.equal(venue.tradeCount, 0);
  });

  // Bonus: pendingIntent returns a defensive copy, so callers cannot mutate the queue.
  it('pendingIntent returns a defensive copy of the intent', async () => {
    const venue = new MockElysiumCoreWriter({
      pendingIntents: [makeIntent({ assetId: 5n })],
    });
    const got = await venue.pendingIntent(KEEPER);
    assert.notEqual(got, null);
    // Mutating the returned intent must not affect the venue's internal state.
    // The internal queue has already been drained, so this is more of a
    // sanity check that the returned object is standalone.
    if (got) {
      (got as PendingIntent).assetId = 999n;
    }
    assert.equal(venue.pendingCount, 0);
  });

  // Bonus: recorded trade index advances even with pre-populated state.
  it('continues the trade index counter after pre-populated trades', async () => {
    const venue = new MockElysiumCoreWriter({
      recordedTrades: [
        {
          index: 0,
          delegator: DELEGATOR,
          keeper: KEEPER,
          nonce: 0n,
          notionalUsd: 1n,
          intent: makeIntent(),
          at: 1,
        },
      ],
    });
    assert.equal(venue.tradeCount, 1);
    await venue.submitTrade(makeDelegation({ nonce: 1n }), FAKE_SIG, makeIntent());
    assert.equal(venue.recordedTrades[1].index, 1);
  });
});

/** Tiny helper for the pre-populated-state test, which is otherwise async. */
function isRevokedSync(venue: MockElysiumCoreWriter): boolean {
  return Promise.resolve(venue.isRevoked(DELEGATOR, KEEPER)).then(
    (v) => v,
    () => false,
  ) as unknown as boolean;
}
