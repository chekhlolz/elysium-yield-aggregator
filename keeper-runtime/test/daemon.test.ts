/**
 * Unit tests for the keeper daemon.
 *
 * These tests drive the daemon in three ways:
 *   - Calling `tick()` directly (deterministic, no timers).
 *   - Calling `start()` / `stop()` with a short watch interval to
 *     verify the lifecycle.
 *   - Freezing `Date.now()` to make the sliding-window rate limiter
 *     deterministic (node:test does not ship a fake-timers utility;
 *     this helper freezes `Date.now` and lets us advance it manually).
 *
 * All fixtures are offline — no RPC, no real network, no real pk
 * (we use the Hardhat dev key from `src/signing.ts`).
 */

import { afterEach, beforeEach, describe, it } from 'node:test';
import assert from 'node:assert/strict';

import type { Address, Delegation, Eip712Domain } from '../src/types.js';
import { KeeperWallet } from '../src/keeper.js';
import { MockElysiumCoreWriter } from '../src/venue-adapter.js';
import { KeeperDaemon } from '../src/daemon.js';
import type {
  DaemonConfig,
  DaemonEvent,
  PendingIntent,
  SubmitResult,
} from '../src/daemon-types.js';

// ---------------------------------------------------------------------------
// Fixtures.
// ---------------------------------------------------------------------------

const HARDHAT_PK_0 = '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80';
const HARDHAT_ADDR_0 = '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266';
const AGENT_ADDR = '0x5FbDB2315678afecb367f032d93F642f64180aa3';

const DOMAIN: Eip712Domain = {
  name: 'TradeOnlyAgent v1',
  version: '1',
  chainId: 999n,
  verifyingContract: AGENT_ADDR,
};

function makeIntent(overrides: Partial<PendingIntent> = {}): PendingIntent {
  return {
    delegator: HARDHAT_ADDR_0,
    assetId: 1n,
    side: 'Long',
    size: 100n,
    notionalUsd: 1_000_000n, // 1 USD in 6-decimal units.
    ...overrides,
  };
}

function makeConfig(overrides: Partial<Omit<DaemonConfig, 'domain'>> = {}): DaemonConfig {
  return {
    domain: DOMAIN,
    watchIntervalMs: 1,
    maxTxsPerMinute: 60,
    maxNotionalUsd: 100_000_000n,
    maxPerOrderUsd: 10_000_000n,
    ttlSeconds: 300,
    nonceSeed: 0n,
    onEvent: () => undefined,
    ...overrides,
  };
}

// ---------------------------------------------------------------------------
// A venue adapter that lets tests inject failures / acceptances.
// ---------------------------------------------------------------------------

class StubVenue {
  private _queue: PendingIntent[] = [];
  private _usedNotionalBy = new Map<string, bigint>();
  private _revoked = false;
  private _submitBehavior: (intent: PendingIntent, d: Delegation) => SubmitResult = () => ({
    txHash: '0x' + '11'.repeat(32),
    accepted: true,
  });
  private _submitThrows: (() => Error) | null = null;

  enqueue(...intents: PendingIntent[]): void {
    this._queue.push(...intents);
  }
  async pendingIntent(_keeper: Address): Promise<PendingIntent | null> {
    return this._queue.shift() ?? null;
  }
  async submitTrade(
    _d: Delegation,
    _sig: { v: 27 | 28; r: `0x${string}`; s: `0x${string}` },
    intent: PendingIntent,
  ): Promise<SubmitResult> {
    if (this._submitThrows) throw this._submitThrows();
    return this._submitBehavior(intent, _d);
  }
  async usedNotional(_delegator: Address, keeper: Address, nonce: bigint): Promise<bigint> {
    return this._usedNotionalBy.get(`${_delegator}:${keeper}:${nonce}`) ?? 0n;
  }
  async isRevoked(_delegator: Address, _keeper: Address): Promise<boolean> {
    return this._revoked;
  }
  async revoke(): Promise<void> {
    this._revoked = true;
  }
  setBehavior(fn: (intent: PendingIntent, d: Delegation) => SubmitResult): void {
    this._submitBehavior = fn;
  }
  setThrow(fn: (() => Error) | null): void {
    this._submitThrows = fn;
  }
  addUsedNotional(delegator: Address, keeper: Address, nonce: bigint, v: bigint): void {
    const k = `${delegator}:${keeper}:${nonce}`;
    this._usedNotionalBy.set(k, (this._usedNotionalBy.get(k) ?? 0n) + v);
  }
  get queueLength(): number {
    return this._queue.length;
  }
}

// ---------------------------------------------------------------------------
// Fake-clock helper. node:test does not ship vi.useFakeTimers(); we
// monkey-patch Date.now directly. Timers (`setTimeout`) keep using the
// real wall clock; `Date.now()` is what the daemon's rate limiter reads.
// ---------------------------------------------------------------------------

const REAL_NOW = Date.now.bind(Date);
let frozenTime: number | null = null;

function setFakeTime(ms: number): void {
  frozenTime = ms;
}

function advanceMs(delta: number): void {
  if (frozenTime === null) return;
  frozenTime += delta;
}

function freezeClock(ms: number): void {
  frozenTime = ms;
  Date.now = () => frozenTime!;
}

function unfreezeClock(): void {
  frozenTime = null;
  Date.now = REAL_NOW;
}

// ---------------------------------------------------------------------------
// Tests.
// ---------------------------------------------------------------------------

describe('KeeperDaemon', () => {
  let keeper: KeeperWallet;
  let events: DaemonEvent[];

  beforeEach(() => {
    keeper = new KeeperWallet(HARDHAT_PK_0);
    events = [];
  });

  afterEach(() => {
    unfreezeClock();
  });

  // 1. Start / stop lifecycle.
  it('start() begins ticking and stop() halts the loop', async () => {
    const venue = new StubVenue();
    venue.enqueue(makeIntent());
    const daemon = new KeeperDaemon(keeper, venue, HARDHAT_ADDR_0, {
      ...makeConfig({ watchIntervalMs: 1, onEvent: (e) => events.push(e) }),
    });

    assert.equal(daemon.isRunning, false);
    await daemon.start();
    assert.equal(daemon.isRunning, true);

    // Let a couple of ticks happen.
    await new Promise((r) => setTimeout(r, 25));
    await daemon.stop();
    assert.equal(daemon.isRunning, false);

    // Exactly one intent was queued, so at most one submission.
    const submitted = events.filter((e) => e.type === 'submitted');
    assert.equal(submitted.length, 1);
    assert.ok(events.length >= 1);
  });

  // 2. Empty queue → no submit, no event.
  it('does not submit or emit when the venue queue is empty', async () => {
    const venue = new StubVenue();
    const daemon = new KeeperDaemon(keeper, venue, HARDHAT_ADDR_0, {
      ...makeConfig({ onEvent: (e) => events.push(e) }),
    });

    await daemon.tick();
    assert.equal(events.length, 0);
    assert.equal(venue.queueLength, 0);
    const stats = daemon.getStats();
    assert.equal(stats.ticks, 1);
    assert.equal(stats.submitted, 0);
  });

  // 3. Single intent → signed, submitted, nonce = seed+0.
  it('submits a single intent with nonce = nonceSeed', async () => {
    const venue = new StubVenue();
    venue.enqueue(makeIntent());
    const daemon = new KeeperDaemon(keeper, venue, HARDHAT_ADDR_0, {
      ...makeConfig({ nonceSeed: 5n, onEvent: (e) => events.push(e) }),
    });

    await daemon.tick();
    assert.equal(events.length, 1);
    assert.equal(events[0].type, 'submitted');
    assert.equal(events[0].nonce, 5n);
    assert.equal(events[0].delegation?.keeper, keeper.address);
    assert.equal(events[0].result?.accepted, true);
    assert.ok(events[0].result?.txHash !== undefined);
  });

  // 4. Multi-intent batch → nonces are monotonic.
  it('submits a batch with monotonic nonces', async () => {
    const venue = new StubVenue();
    for (let i = 0; i < 4; i++) venue.enqueue(makeIntent({ notionalUsd: BigInt(i + 1) * 100_000n }));
    const daemon = new KeeperDaemon(keeper, venue, HARDHAT_ADDR_0, {
      ...makeConfig({ nonceSeed: 0n, onEvent: (e) => events.push(e) }),
    });

    for (let i = 0; i < 4; i++) await daemon.tick();
    const nonces = events.map((e) => e.nonce);
    assert.deepEqual(nonces, [0n, 1n, 2n, 3n]);
    assert.equal(daemon.getStats().lastNonce, 3n);
  });

  // 5. Nonce persists across start/stop.
  it('does not reuse a nonce across two start() calls', async () => {
    const venue = new StubVenue();
    venue.enqueue(makeIntent());
    const daemon = new KeeperDaemon(keeper, venue, HARDHAT_ADDR_0, {
      ...makeConfig({ watchIntervalMs: 1, onEvent: (e) => events.push(e) }),
    });

    await daemon.start();
    await new Promise((r) => setTimeout(r, 25));
    await daemon.stop();

    const firstLastNonce = daemon.getStats().lastNonce;
    assert.equal(firstLastNonce, 0n);

    // Re-add an intent and restart.
    events = [];
    venue.enqueue(makeIntent());
    await daemon.start();
    await new Promise((r) => setTimeout(r, 25));
    await daemon.stop();

    const secondLastNonce = daemon.getStats().lastNonce;
    assert.equal(secondLastNonce, firstLastNonce + 1n);
  });

  // 6. Slippage: intent.notionalUsd > maxPerOrder → skipped.
  it('skips an intent that exceeds maxPerOrderUsd', async () => {
    const venue = new StubVenue();
    // Default maxPerOrderUsd in makeConfig is 10_000_000n.
    venue.enqueue(makeIntent({ notionalUsd: 11_000_000n }));
    const daemon = new KeeperDaemon(keeper, venue, HARDHAT_ADDR_0, {
      ...makeConfig({ onEvent: (e) => events.push(e) }),
    });

    await daemon.tick();
    assert.equal(events.length, 1);
    assert.equal(events[0].type, 'skipped');
    assert.equal(events[0].reason, 'exceeds maxPerOrder');
    assert.equal(venue.queueLength, 0); // intent was consumed but not submitted
  });

  // 7. Rate limit: 60 txs in 60s → 61st skipped.
  it('skips the 61st submission in the same 60s window', async () => {
    const t0 = new Date('2026-01-01T00:00:00.000Z').getTime();
    freezeClock(t0);

    const venue = new StubVenue();
    for (let i = 0; i < 61; i++) venue.enqueue(makeIntent({ notionalUsd: 1n }));
    const daemon = new KeeperDaemon(keeper, venue, HARDHAT_ADDR_0, {
      ...makeConfig({ maxTxsPerMinute: 60, onEvent: (e) => events.push(e) }),
    });

    // Fire 60 submissions — all should be accepted.
    for (let i = 0; i < 60; i++) await daemon.tick();
    const acceptedSoFar = events.filter((e) => e.type === 'submitted').length;
    assert.equal(acceptedSoFar, 60);

    // 61st should be skipped for rate limiting.
    await daemon.tick();
    const last = events[events.length - 1];
    assert.equal(last.type, 'skipped');
    assert.equal(last.reason, 'rate-limited');
  });

  // 8. Rate-limit window slides: after 60s new txs accepted.
  it('resumes accepting submissions once the 60s window slides', async () => {
    const t0 = new Date('2026-01-01T00:00:00.000Z').getTime();
    freezeClock(t0);

    const venue = new StubVenue();
    for (let i = 0; i < 61; i++) venue.enqueue(makeIntent({ notionalUsd: 1n }));
    const daemon = new KeeperDaemon(keeper, venue, HARDHAT_ADDR_0, {
      ...makeConfig({ maxTxsPerMinute: 60, onEvent: (e) => events.push(e) }),
    });

    for (let i = 0; i < 60; i++) await daemon.tick();
    assert.equal(events.filter((e) => e.type === 'submitted').length, 60);

    // Fast-forward past the window.
    advanceMs(61_000);

    await daemon.tick();
    const last = events[events.length - 1];
    assert.equal(last.type, 'submitted');
  });

  // 9. Venue returns accepted: false → failed.
  it('marks the event failed when the venue rejects', async () => {
    const venue = new StubVenue();
    venue.setBehavior(() => ({
      txHash: '0x' + '11'.repeat(32),
      accepted: false,
      reason: 'venue-side notional exceeded',
    }));
    venue.enqueue(makeIntent());
    const daemon = new KeeperDaemon(keeper, venue, HARDHAT_ADDR_0, {
      ...makeConfig({ onEvent: (e) => events.push(e) }),
    });

    await daemon.tick();
    assert.equal(events.length, 1);
    assert.equal(events[0].type, 'failed');
    assert.equal(events[0].reason, 'venue-side notional exceeded');
    assert.equal(daemon.getStats().failed, 1);
  });

  // 10. Random exception from venue.submitTrade → caught, failed, loop continues.
  it('catches exceptions from venue.submitTrade and marks failed', async () => {
    const venue = new StubVenue();
    venue.setThrow(() => new Error('network down'));
    venue.enqueue(makeIntent());
    venue.enqueue(makeIntent());
    const daemon = new KeeperDaemon(keeper, venue, HARDHAT_ADDR_0, {
      ...makeConfig({ onEvent: (e) => events.push(e) }),
    });

    await daemon.tick();
    assert.equal(events.length, 1);
    assert.equal(events[0].type, 'failed');
    assert.ok(events[0].reason?.includes('network down'));

    // Loop continues: fix the venue, submit the next intent.
    venue.setThrow(null);
    venue.setBehavior(() => ({ txHash: '0x' + '11'.repeat(32), accepted: true }));
    await daemon.tick();
    assert.equal(events.length, 2);
    assert.equal(events[1].type, 'submitted');
  });

  // 11. onEvent handler receives the correct event shape.
  it('onEvent receives events with all expected fields', async () => {
    const t0 = new Date('2026-01-01T00:00:00.000Z').getTime();
    freezeClock(t0);

    const venue = new StubVenue();
    venue.enqueue(makeIntent({ notionalUsd: 2_000_000n, assetId: 42n, side: 'Short' }));
    const daemon = new KeeperDaemon(keeper, venue, HARDHAT_ADDR_0, {
      ...makeConfig({ onEvent: (e) => events.push(e) }),
    });

    await daemon.tick();
    const evt = events[0];
    assert.equal(evt.type, 'submitted');
    assert.equal(evt.intent.assetId, 42n);
    assert.equal(evt.intent.side, 'Short');
    assert.equal(evt.intent.notionalUsd, 2_000_000n);
    assert.equal(evt.nonce, 0n);
    assert.equal(evt.delegation?.nonce, 0n);
    assert.equal(evt.delegation?.keeper, keeper.address);
    assert.deepEqual(evt.delegation?.assetIds, [42n]);
    assert.equal(evt.delegation?.maxPerOrder, 2_000_000n);
    const nowSeconds = BigInt(Math.floor(Date.now() / 1000));
    assert.ok(evt.delegation?.expiresAt > nowSeconds - 5n);
    assert.equal(evt.result?.accepted, true);
  });

  // 12. Stats reflect real counts.
  it('getStats() reflects real submitted/skipped/failed counts', async () => {
    const venue = new StubVenue();
    // Enqueue: 1 good, 1 too-big, 1 rejected, 1 good.
    venue.enqueue(makeIntent());
    venue.enqueue(makeIntent({ notionalUsd: 11_000_000n })); // > maxPerOrder
    venue.enqueue(makeIntent());
    const daemon = new KeeperDaemon(keeper, venue, HARDHAT_ADDR_0, {
      ...makeConfig({ onEvent: (e) => events.push(e) }),
    });

    // Tick 1: submitted.
    await daemon.tick();
    // Tick 2: skipped (too big).
    await daemon.tick();
    // Tick 3: rejected by venue.
    venue.setBehavior(() => ({ txHash: '0x' + '11'.repeat(32), accepted: false, reason: 'no' }));
    await daemon.tick();
    // Tick 4: nothing to do.
    await daemon.tick();

    const stats = daemon.getStats();
    assert.equal(stats.ticks, 4);
    assert.equal(stats.submitted, 1);
    assert.equal(stats.skipped, 1);
    assert.equal(stats.failed, 1);
    // lastNonce = 1 (the rejected submission consumed a nonce).
    assert.equal(stats.lastNonce, 1n);
  });

  // 13. (Bonus) Nonce bumps even when the venue rejects, ensuring no reuse.
  it('bumps the nonce even when the venue rejects the submission', async () => {
    const venue = new StubVenue();
    venue.setBehavior(() => ({ txHash: '0x' + '11'.repeat(32), accepted: false, reason: 'no' }));
    venue.enqueue(makeIntent());
    venue.enqueue(makeIntent());
    const daemon = new KeeperDaemon(keeper, venue, HARDHAT_ADDR_0, {
      ...makeConfig({ onEvent: (e) => events.push(e) }),
    });

    await daemon.tick();
    await daemon.tick();
    assert.deepEqual(events.map((e) => e.nonce), [0n, 1n]);
    assert.equal(daemon.getStats().lastNonce, 1n);
  });

  // 14. (Bonus) Signing failure skips without consuming the nonce.
  it('does not consume the nonce on signing failure', async () => {
    // Force a signing failure by monkey-patching signDelegation on the wallet instance.
    (keeper as unknown as { signDelegation: () => Promise<never> }).signDelegation = async () => {
      throw new Error('signer offline');
    };
    const venue = new StubVenue();
    venue.enqueue(makeIntent());
    const daemon = new KeeperDaemon(keeper, venue, HARDHAT_ADDR_0, {
      ...makeConfig({ onEvent: (e) => events.push(e) }),
    });

    await daemon.tick();
    assert.equal(events[0].type, 'skipped');
    assert.ok(events[0].reason?.includes('signer offline'));
    assert.equal(daemon.getStats().lastNonce, -1n); // nonce was NOT consumed
  });

  // 15. (Bonus) resetNonce() only works when stopped.
  it('resetNonce() throws while running, resets when stopped', async () => {
    const venue = new StubVenue();
    const daemon = new KeeperDaemon(keeper, venue, HARDHAT_ADDR_0, {
      ...makeConfig({ watchIntervalMs: 1 }),
    });
    await daemon.start();
    assert.throws(() => daemon.resetNonce(999n), /running/);
    await daemon.stop();
    daemon.resetNonce(999n);
    assert.equal(daemon.getStats().lastNonce, -1n);
  });

  // 16. (Bonus) Venue-side revoke skips the intent.
  it('skips when the venue has revoked the keeper', async () => {
    const venue = new MockElysiumCoreWriter();
    await venue.revoke(HARDHAT_ADDR_0, keeper.address);
    venue['pendingIntents'].push(makeIntent());
    const daemon = new KeeperDaemon(keeper, venue, HARDHAT_ADDR_0, {
      ...makeConfig({ onEvent: (e) => events.push(e) }),
    });

    await daemon.tick();
    assert.equal(events[0].type, 'skipped');
    assert.equal(events[0].reason, 'keeper revoked by venue');
  });

  // 17. (Bonus) Notional-cap check: pre-existing used-notional blocks submission.
  it('skips when projected used-notional exceeds maxNotionalUsd', async () => {
    const venue = new StubVenue();
    venue.addUsedNotional(HARDHAT_ADDR_0, keeper.address, 0n, 100_000_000n);
    venue.enqueue(makeIntent({ notionalUsd: 1_000_000n }));
    const daemon = new KeeperDaemon(keeper, venue, HARDHAT_ADDR_0, {
      ...makeConfig({ maxNotionalUsd: 1_500_000n, onEvent: (e) => events.push(e) }),
    });

    await daemon.tick();
    assert.equal(events[0].type, 'skipped');
    assert.equal(events[0].reason, 'notional cap exceeded');
  });
});
