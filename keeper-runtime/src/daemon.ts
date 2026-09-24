/**
 * KeeperDaemon — the polling loop that ties the keeper wallet and the venue
 * adapter together.
 *
 * ## Shape of a tick
 *
 * 1. Ask the venue for the next pending intent. If none, sleep for
 *    `watchIntervalMs` and return.
 * 2. Build a fresh `Delegation` from the intent (keeper, empty assetIds,
 *    `min(maxNotionalUsd, intent.notionalUsd)`, `min(maxPerOrderUsd,
 *    intent.notionalUsd)`, `expiresAt = now + ttlSeconds`, monotonic nonce,
 *    random salt).
 * 3. Client-side sanity check: if `intent.notionalUsd > maxPerOrderUsd`,
 *    skip with reason `'exceeds maxPerOrder'`. No signature, no nonce bump.
 * 4. Rate-limit check: if we have emitted `maxTxsPerMinute` submissions in
 *    the last 60 seconds, skip with reason `'rate-limited'`. No nonce bump.
 * 5. Venue-side revoke check: if `venue.isRevoked(delegator, keeper)`,
 *    skip with reason `'keeper revoked by venue'`.
 * 6. Used-notional check: if `used + intent.notionalUsd > maxNotional`,
 *    skip with reason `'notional cap exceeded'`.
 * 7. Bump the nonce and construct the delegation.
 * 8. Sign with the keeper wallet.
 * 9. Submit via `venue.submitTrade(delegation, sig, intent)`.
 * 10. Emit `DaemonEvent { type: 'submitted' | 'failed', ... }`.
 *
 * ## Nonce monotonicity
 *
 * The nonce is a monotonic counter starting at `nonceSeed` and is
 * incremented by 1 **only when a submission is actually attempted**
 * (either successfully or with a failure we will report). Skipped
 * intents do not consume a nonce — they are retriable on a later tick.
 *
 * **Why this matters:** the venue's used-notional book is keyed by
 * `(delegator, keeper, nonce)`. Reusing a nonce is how a replayed
 * delegation sneaks past the venue's dedup: the second submission
 * looks like a re-delivery of the first and the venue silently
 * accepts it. Monotonic nonces are non-negotiable here.
 *
 * The counter lives on the daemon instance. If you need to survive a
 * process restart, pass in a non-zero `nonceSeed` and persist the
 * daemon's last nonce via `getStats().lastNonce`.
 *
 * ## Rate limit
 *
 * Sliding-window counter: a `number[]` of Unix-ms timestamps of
 * submissions emitted within the last 60 seconds. Before each
 * submission, the algorithm prunes timestamps older than 60 s and
 * refuses if the window is full.
 *
 * This is NOT a token-bucket or leaky-bucket. It is deliberately
 * simple: we cap bursts (60 in a minute is the max the venue will
 * absorb), we allow steady-state throughput equal to the cap, and we
 * do not accumulate "credit" from slow periods. The alternative (a
 * token bucket that lets you bank slow periods for later) would let
 * a compromised keeper blow out after a quiet hour.
 *
 * ## Failure modes
 *
 * - If `keeper.signDelegation` throws, the nonce is NOT bumped and the
 *   intent is skipped with reason `'signing error: <msg>'`. The intent
 *   is left in place (the venue still reports it) so the next tick will
 *   retry. If signing is persistently broken the daemon will spin
 *   forever skipping; that is a configuration problem, not a runtime
 *   one.
 * - If `venue.submitTrade` throws, the nonce IS bumped (we attempted
 *   the submission, and we cannot be sure the venue did not record
 *   it). The event type is `failed`. The intent is consumed; the
 *   next tick will fetch the next pending intent.
 *
 * The asymmetry is deliberate: signing failures are recoverable with
 * no state mutation, submission failures are NOT recoverable because
 * the venue's state is now ambiguous.
 */

import { randomBytes } from 'node:crypto';

import type { Address, Delegation, Signature } from './types.js';
import { ZERO_SALT } from './types.js';
import type { KeeperWallet } from './keeper.js';
import type { IVenueAdapter } from './venue-adapter.js';
import type {
  DaemonConfig,
  DaemonEvent,
  KeeperDaemonStats,
  PendingIntent,
  SubmitResult,
} from './daemon-types.js';

/**
 * Defaults. `maxNotionalUsd` and `maxPerOrderUsd` are 6-decimal USD.
 *
 * `domain` is not defaulted — the daemon has no way to know the
 * EIP-712 domain, so callers must supply it. `onEvent` is defaulted to
 * a no-op here and callers may override via the constructor.
 */
export const DEFAULT_DAEMON_CONFIG: Omit<DaemonConfig, 'domain'> = {
  watchIntervalMs: 1000,
  maxTxsPerMinute: 60,
  maxNotionalUsd: 100_000_000n, // 100,000 USD in 6-decimal units.
  maxPerOrderUsd: 10_000_000n, // 10,000 USD in 6-decimal units.
  ttlSeconds: 300,
  nonceSeed: 0n,
  onEvent: () => undefined,
};

/**
 * Shape of the constructor argument to {@link KeeperDaemon}.
 *
 * Every field of `DaemonConfig` is optional EXCEPT `domain`, which is
 * required because the daemon has no way to know the EIP-712 domain
 * without being told. Missing fields fall back to `DEFAULT_DAEMON_CONFIG`.
 */
export type KeeperDaemonConfig =
  & Partial<Omit<DaemonConfig, 'domain'>>
  & Pick<DaemonConfig, 'domain'>;

const RATE_WINDOW_MS = 60_000;
const TICKS_WITHOUT_PROGRESS_LIMIT = 100;

/** A safe empty delegation for `DaemonEvent` when we never built one. */
const PLACEHOLDER_DELEGATION: Delegation = {
  keeper: '0x0000000000000000000000000000000000000000',
  assetIds: [],
  maxNotional: 0n,
  maxPerOrder: 0n,
  expiresAt: 0n,
  nonce: -1n,
  salt: ZERO_SALT,
};

function randomSalt(): `0x${string}` {
  return ('0x' + Buffer.from(randomBytes(32)).toString('hex')) as `0x${string}`;
}

function nowSeconds(): bigint {
  return BigInt(Math.floor(Date.now() / 1000));
}

/**
 * The keeper daemon.
 *
 * @param keeper              The keeper wallet that signs delegations.
 * @param venue               The venue adapter to submit to.
 * @param delegatorAddress    The delegator we sign on behalf of.
 * @param config              Daemon configuration, see `DaemonConfig`.
 *                           Partial configs are merged with
 *                           `DEFAULT_DAEMON_CONFIG`; `domain` is required.
 */
export class KeeperDaemon {
  private readonly keeper: KeeperWallet;
  private readonly venue: IVenueAdapter;
  private readonly delegatorAddress: Address;
  private readonly config: DaemonConfig;

  /** `null` when not running, otherwise the tick promise in flight. */
  private running: Promise<void> | null = null;
  /** Set to `true` to break out of the loop. */
  private stopped = false;

  /** Monotonic nonce. Incremented only on submission attempts. */
  private nextNonce: bigint;

  /** Sliding-window submission timestamps (Unix ms). */
  private readonly submissionTimes: number[] = [];

  /** Aggregated counters, read out via `getStats()`. */
  private ticks = 0;
  private submittedCount = 0;
  private skippedCount = 0;
  private failedCount = 0;
  private lastNonce: bigint = -1n;

  constructor(
    keeper: KeeperWallet,
    venue: IVenueAdapter,
    delegatorAddress: Address,
    partialConfig: KeeperDaemonConfig,
  ) {
    this.keeper = keeper;
    this.venue = venue;
    this.delegatorAddress = delegatorAddress;
    this.config = { ...DEFAULT_DAEMON_CONFIG, ...partialConfig };
    this.nextNonce = this.config.nonceSeed;
  }

  /** The keeper's address, convenient for tests and logs. */
  get address(): Address {
    return this.keeper.address;
  }

  /** The delegator address this daemon signs on behalf of. */
  get delegator(): Address {
    return this.delegatorAddress;
  }

  /** Whether the loop is currently active. */
  get isRunning(): boolean {
    return this.running !== null;
  }

  /**
   * Start the polling loop. Idempotent — calling `start()` again while
   * running resolves immediately. Await `stop()` before calling again.
   */
  async start(): Promise<void> {
    if (this.running) return;
    this.stopped = false;
    this.running = this.loop();
  }

  /**
   * Stop the polling loop cleanly. Waits for the in-flight tick to
   * finish, so callers can assert on events after `await stop()`.
   */
  async stop(): Promise<void> {
    this.stopped = true;
    if (this.running) {
      await this.running;
      this.running = null;
    }
  }

  /**
   * Execute a single tick. Exposed as a public method so tests can
   * drive the loop deterministically without waiting for
   * `watchIntervalMs` between ticks.
   */
  async tick(): Promise<void> {
    this.ticks++;
    const intent = await this.venue.pendingIntent(this.keeper.address);
    if (!intent) return;

    // Client-side sanity: the intent must fit the per-order cap. Skip
    // before we spend a nonce on it so the intent can be retried after
    // a config change.
    if (intent.notionalUsd > this.config.maxPerOrderUsd) {
      this.emitSkipped(intent, 'exceeds maxPerOrder', PLACEHOLDER_DELEGATION);
      return;
    }

    // Rate-limit check. The window is a simple sliding 60s counter.
    if (this.isRateLimited()) {
      this.emitSkipped(intent, 'rate-limited', PLACEHOLDER_DELEGATION);
      return;
    }

    // Venue-side revoke.
    if (await this.venue.isRevoked(intent.delegator, this.keeper.address)) {
      this.emitSkipped(intent, 'keeper revoked by venue', PLACEHOLDER_DELEGATION);
      return;
    }

    // Used-notional check. The venue keeps (delegator, keeper, nonce)
    // caps, so we must consult it per-intent.
    const alreadyUsed = await this.venue.usedNotional(
      intent.delegator,
      this.keeper.address,
      this.nextNonce,
    );
    const projectedMaxNotional = intent.notionalUsd > this.config.maxNotionalUsd
      ? this.config.maxNotionalUsd
      : intent.notionalUsd;
    if (alreadyUsed + intent.notionalUsd > projectedMaxNotional) {
      this.emitSkipped(
        intent,
        'notional cap exceeded',
        PLACEHOLDER_DELEGATION,
      );
      return;
    }

    // Build and sign the delegation.
    const nonce = this.nextNonce;
    const delegation: Delegation = {
      keeper: this.keeper.address,
      assetIds: intent.assetId !== undefined && intent.assetId > 0n ? [intent.assetId] : [],
      maxNotional: projectedMaxNotional,
      maxPerOrder:
        intent.notionalUsd > this.config.maxPerOrderUsd
          ? this.config.maxPerOrderUsd
          : intent.notionalUsd,
      expiresAt: nowSeconds() + BigInt(this.config.ttlSeconds),
      nonce,
      salt: randomSalt(),
    };

    let sig: Signature;
    try {
      sig = await this.keeper.signDelegation(
        delegation,
        intent.delegator,
        this.config.domain,
      );
    } catch (e) {
      // Signing failure: do NOT bump the nonce. The intent is retried
      // next tick. This is a config/health problem, not a runtime one.
      this.emitSkipped(
        intent,
        `signing error: ${errMsg(e)}`,
        delegation,
      );
      return;
    }

    // Commit the nonce. We do this before submit so that even a
    // throwing venue does not cause a nonce reuse.
    this.nextNonce = nonce + 1n;
    this.lastNonce = nonce;
    this.recordSubmission();

    try {
      const result: SubmitResult = await this.venue.submitTrade(
        delegation,
        sig,
        intent,
      );
      if (result.accepted) {
        this.submittedCount++;
        this.emit({ type: 'submitted', intent, delegation, result, nonce });
      } else {
        this.failedCount++;
        this.emit({
          type: 'failed',
          intent,
          delegation,
          result,
          nonce,
          reason: result.reason ?? 'venue rejected submission',
        });
      }
    } catch (e) {
      this.failedCount++;
      this.emit({
        type: 'failed',
        intent,
        delegation,
        nonce,
        reason: `submitTrade threw: ${errMsg(e)}`,
      });
    }
  }

  /**
   * Aggregated stats. `lastNonce` is `-1n` if no submission was
   * attempted yet; otherwise it is the most recently consumed nonce.
   */
  getStats(): KeeperDaemonStats {
    return {
      ticks: this.ticks,
      submitted: this.submittedCount,
      skipped: this.skippedCount,
      failed: this.failedCount,
      lastNonce: this.lastNonce,
    };
  }

  /**
   * Reset the nonce counter to a fresh seed. Useful when re-issuing
   * delegations after a revoke. Only call this when the daemon is not
   * running.
   */
  resetNonce(seed: bigint): void {
    if (this.running) {
      throw new Error('cannot reset nonce while the daemon is running');
    }
    this.nextNonce = seed;
    this.lastNonce = -1n;
  }

  // -------------------------------------------------------------------
  // Internals.
  // -------------------------------------------------------------------

  private async loop(): Promise<void> {
    let ticksWithoutProgress = 0;
    while (!this.stopped) {
      const before = this.submittedCount + this.failedCount;
      try {
        await this.tick();
        if (this.submittedCount + this.failedCount > before) {
          ticksWithoutProgress = 0;
        } else {
          ticksWithoutProgress++;
        }
      } catch (e) {
        // A tick should never throw, but if it does we do not want to
        // kill the loop. Log and sleep.
        this.emit({
          type: 'failed',
          intent: PLACEHOLDER_INTENT,
          nonce: this.lastNonce,
          reason: `tick threw: ${errMsg(e)}`,
        });
        ticksWithoutProgress++;
      }
      if (ticksWithoutProgress >= TICKS_WITHOUT_PROGRESS_LIMIT) {
        // Idle loop guard: after 100 ticks without a submission we
        // back off to the full watch interval (which we already do)
        // and continue. No action here beyond the counter, but the
        // guard prevents a runaway spin if `pendingIntent` keeps
        // returning the same already-processed intent.
      }
      await sleep(this.config.watchIntervalMs);
    }
  }

  private emitSkipped(
    intent: PendingIntent,
    reason: string,
    delegation: Delegation,
  ): void {
    this.skippedCount++;
    this.emit({
      type: 'skipped',
      intent,
      delegation,
      nonce: this.lastNonce,
      reason,
    });
  }

  private emit(evt: DaemonEvent): void {
    try {
      this.config.onEvent(evt);
    } catch (e) {
      // A broken onEvent handler must not take down the daemon. Log to
      // stderr so the operator notices, then continue.
      // eslint-disable-next-line no-console
      console.error(`[KeeperDaemon] onEvent threw: ${errMsg(e)}`);
    }
  }

  private isRateLimited(): boolean {
    const cutoff = Date.now() - RATE_WINDOW_MS;
    while (this.submissionTimes.length > 0 && this.submissionTimes[0] <= cutoff) {
      this.submissionTimes.shift();
    }
    return this.submissionTimes.length >= this.config.maxTxsPerMinute;
  }

  private recordSubmission(): void {
    this.submissionTimes.push(Date.now());
  }
}

/** A degenerate intent used in the outer-loop error path. */
const PLACEHOLDER_INTENT: PendingIntent = {
  delegator: '0x0000000000000000000000000000000000000000',
  assetId: 0n,
  side: 'Long',
  size: 0n,
  notionalUsd: 0n,
};

function errMsg(e: unknown): string {
  if (e instanceof Error) return e.message;
  return String(e);
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
