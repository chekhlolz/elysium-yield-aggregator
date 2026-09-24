/**
 * Venue adapter interface and an in-memory implementation.
 *
 * ## Why an adapter
 *
 * The daemon does not know (and does not care) whether the venue is a
 * real predeploy, a mock, or a test double. Everything flows through
 * {@link IVenueAdapter} so the daemon can be tested offline with
 * {@link MockElysiumCoreWriter} and swapped for a real adapter later
 * without touching daemon logic.
 *
 * ## The mock
 *
 * {@link MockElysiumCoreWriter} holds all state in memory:
 *   - `pendingIntents` queue, drained FIFO by `pendingIntent()`
 *   - `recordedTrades` array, appended by `submitTrade()`
 *   - `usedNotionalBy` map, keyed by `(delegator, keeper, nonce)`
 *   - `revokedKeppers` set, keyed by `(delegator, keeper)`
 *
 * The mock is NOT a substitute for on-chain signature verification. It
 * accepts whatever signature the daemon sends, provided the venue has
 * not been told to revoke the keeper. This is intentional — the
 * signature-verification contract is covered by `src/mock-venue.ts`
 * and `test/signing.test.ts`. The adapter's job is to shape the
 * intent/submit/used-notional/revoke API the daemon consumes.
 */

import type { Address, Delegation, Signature } from './types.js';
import type {
  PendingIntent,
  SubmittedTrade,
  SubmitResult,
} from './daemon-types.js';

/** Adapter interface consumed by `KeeperDaemon`. */
export interface IVenueAdapter {
  /**
   * Fetch the next pending intent for this keeper, or null when the
   * venue has nothing to do. Called once per tick.
   */
  pendingIntent(keeper: Address): Promise<PendingIntent | null>;

  /**
   * Submit a signed delegation for the intent. Returns a `SubmitResult`
   * indicating whether the venue accepted the trade.
   */
  submitTrade(
    delegation: Delegation,
    sig: Signature,
    intent: PendingIntent,
  ): Promise<SubmitResult>;

  /**
   * Read the total used notional (USD 6-decimal units) charged against
   * the `(delegator, keeper, nonce)` triple. The mock accumulates this
   * across multiple submissions for the same triple — real venues
   * would key it off the venue contract's used-notional storage.
   */
  usedNotional(
    delegator: Address,
    keeper: Address,
    nonce: bigint,
  ): Promise<bigint>;

  /**
   * Check whether the venue has been told (via its own revoke flow)
   * that this keeper should stop trading. Venues hold revoke state
   * independently of the TradeOnlyAgent, so the daemon must consult
   * both.
   */
  isRevoked(delegator: Address, keeper: Address): Promise<boolean>;

  /** Tell the venue to revoke this keeper. Venue-local. */
  revoke(delegator: Address, keeper: Address): Promise<void>;
}

/** Shape of the initial in-memory state passed to the mock constructor. */
export interface MockVenueState {
  /** Pending intents the venue already knows about. FIFO. */
  pendingIntents?: PendingIntent[];
  /** Trades already recorded against the venue. */
  recordedTrades?: SubmittedTrade[];
  /** Used notional per `(delegator, keeper, nonce)` triple. */
  usedNotionalBy?: Record<string, bigint>;
  /** Keppers the venue has been told to revoke, keyed by delegator. */
  revokedKeppers?: Record<string, Address[]>;
  /** Optional label for logs. */
  name?: string;
}

const MOCK_TX_HASH =
  '0x' + '11'.repeat(32); // 0x11…11, stable sentinel for test assertions.

function tripKey(
  delegator: Address,
  keeper: Address,
  nonce: bigint,
): string {
  return [delegator.toLowerCase(), keeper.toLowerCase(), nonce.toString()].join(':');
}

function pairKey(delegator: Address, keeper: Address): string {
  return [delegator.toLowerCase(), keeper.toLowerCase()].join(':');
}

/**
 * In-memory `IElysiumCoreWriter` mock. No RPC, no keccak, no real venue.
 *
 * - `pendingIntent()` drains a FIFO queue.
 * - `submitTrade()` records the trade and accumulates used notional on
 *   `(delegator, keeper, nonce)`.
 * - `revoke()` adds the keeper to the venue's local revoke set; once
 *   revoked, `submitTrade` returns `accepted: false` for that keeper.
 *
 * Constructor takes a `MockVenueState` for pre-population. The state is
 * a shallow copy — mutating `state.pendingIntents` after construction
 * does NOT affect the mock (defensive).
 */
export class MockElysiumCoreWriter implements IVenueAdapter {
  readonly name: string;

  private readonly _pendingIntents: PendingIntent[];
  private readonly _recordedTrades: SubmittedTrade[];
  private readonly _usedNotionalBy: Map<string, bigint>;
  private readonly _revokedKeppers: Map<string, Address>;
  private _nextTradeIndex: number;

  constructor(state: MockVenueState = {}) {
    this.name = state.name ?? 'MockElysiumCoreWriter';
    this._pendingIntents = state.pendingIntents ? [...state.pendingIntents] : [];
    this._recordedTrades = state.recordedTrades ? [...state.recordedTrades] : [];
    this._usedNotionalBy = new Map();
    for (const [k, v] of Object.entries(state.usedNotionalBy ?? {})) {
      this._usedNotionalBy.set(k, v);
    }
    this._revokedKeppers = new Map();
    // `revokedKeppers` is keyed by delegator address, with values being
    // arrays of revoked keeper addresses. We expand each entry into the
    // composite (delegator, keeper) pair key used internally.
    for (const [delegator, keepers] of Object.entries(state.revokedKeppers ?? {})) {
      for (const keeper of keepers) {
        this._revokedKeppers.set(pairKey(delegator as Address, keeper), keeper);
      }
    }
    // Start the recorded-trade index counter after any pre-populated trades.
    this._nextTradeIndex = this._recordedTrades.length;
  }

  /** Snapshot of the pending-queue length. */
  get pendingCount(): number {
    return this._pendingIntents.length;
  }

  /** Snapshot of the recorded-trade count. */
  get tradeCount(): number {
    return this._recordedTrades.length;
  }

  /** Read-only snapshot of recorded trades, safe to assert against. */
  get recordedTrades(): readonly SubmittedTrade[] {
    return this._recordedTrades;
  }

  /** Read-only snapshot of used-notional entries, keyed by composite string. */
  getUsedNotional(): ReadonlyMap<string, bigint> {
    return this._usedNotionalBy;
  }

  /**
   * Total used notional across every (delegator, keeper, nonce) triple
   * whose string key contains all three of the given addresses. Used by
   * tests to assert the accumulated cap across multiple submissions.
   */
  sumUsedNotional(delegator: Address, keeper: Address, nonce: bigint): bigint {
    return this._usedNotionalBy.get(tripKey(delegator, keeper, nonce)) ?? 0n;
  }

  /** Read-only snapshot of the pending queue (FIFO order). */
  get pendingIntents(): readonly PendingIntent[] {
    return this._pendingIntents;
  }

  /**
   * Drain the next intent from the queue. When the queue is empty the
   * method returns null and the daemon's next tick will `sleep` without
   * touching the venue.
   *
   * The mock returns the FIRST intent in the queue, regardless of the
   * keeper passed in. This is intentional: the mock venue is single-
   * keeper for simplicity. Multi-keeper filtering belongs in a real
   * adapter.
   */
  async pendingIntent(_keeper: Address): Promise<PendingIntent | null> {
    if (this._pendingIntents.length === 0) return null;
    const intent = this._pendingIntents.shift();
    if (!intent) return null;
    return { ...intent };
  }

  /**
   * Submit a signed delegation for an intent.
   *
   * The mock performs three checks before recording:
   *   1. If the keeper has been revoked by this venue, reject.
   *   2. If the intent's notional exceeds `delegation.maxPerOrder`,
   *      reject (the on-chain verifier would do the same).
   *   3. Otherwise, record the trade and accumulate used notional.
   *
   * The mock does NOT verify the EIP-712 signature here — signature
   * verification is the job of `TradeOnlyAgent.isValidDelegation`
   * on-chain, and of `src/mock-venue.ts` offline. Adding it here
   * would duplicate work and mask bugs in the venue adapter layer.
   */
  async submitTrade(
    delegation: Delegation,
    _sig: Signature,
    intent: PendingIntent,
  ): Promise<SubmitResult> {
    void _sig; // Unused in the mock; the real venue verifies it.

    if (await this.isRevoked(intent.delegator, delegation.keeper)) {
      return {
        txHash: MOCK_TX_HASH,
        accepted: false,
        reason: 'keeper revoked by venue',
      };
    }

    if (intent.notionalUsd > delegation.maxPerOrder) {
      return {
        txHash: MOCK_TX_HASH,
        accepted: false,
        reason: 'intent exceeds delegation.maxPerOrder',
      };
    }

    const key = tripKey(intent.delegator, delegation.keeper, delegation.nonce);
    const used = this._usedNotionalBy.get(key) ?? 0n;
    this._usedNotionalBy.set(key, used + intent.notionalUsd);

    const trade: SubmittedTrade = {
      index: this._nextTradeIndex++,
      delegator: intent.delegator,
      keeper: delegation.keeper,
      nonce: delegation.nonce,
      notionalUsd: intent.notionalUsd,
      intent: { ...intent },
      at: Date.now(),
    };
    this._recordedTrades.push(trade);

    return { txHash: MOCK_TX_HASH, accepted: true };
  }

  /**
   * Total used notional charged against the `(delegator, keeper, nonce)`
   * triple. Zero if none.
   */
  async usedNotional(
    delegator: Address,
    keeper: Address,
    nonce: bigint,
  ): Promise<bigint> {
    return this._usedNotionalBy.get(tripKey(delegator, keeper, nonce)) ?? 0n;
  }

  /**
   * Check whether the venue has revoked this keeper for this delegator.
   * The default is `false` — a keeper is trusted until told otherwise.
   */
  async isRevoked(delegator: Address, keeper: Address): Promise<boolean> {
    return this._revokedKeppers.has(pairKey(delegator, keeper));
  }

  /**
   * Record a venue-side revoke for the (delegator, keeper) pair. Once
   * revoked, all future `submitTrade` calls for that keeper return
   * `accepted: false` with reason `'keeper revoked by venue'`.
   *
   * This is venue-local state only; it does not touch the TradeOnlyAgent
   * on-chain revoke. The daemon should also call
   * `KeeperWallet.revoke(agentAddress, keeperAddress, provider)` for
   * the on-chain path — those are two independent layers of defense.
   */
  async revoke(delegator: Address, keeper: Address): Promise<void> {
    this._revokedKeppers.set(pairKey(delegator, keeper), keeper);
  }
}
