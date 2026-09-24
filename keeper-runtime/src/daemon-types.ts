/**
 * Shared types for the keeper daemon and venue adapter.
 *
 * These types are deliberately kept in their own file so the daemon and the
 * venue adapter do not need to import from each other to share a common
 * shape. Anything here is part of the public API surface of this package.
 *
 * ## Note on `PendingIntent`
 *
 * The venue-adapter `PendingIntent` is a *best-guess* shape that mirrors the
 * intent submit ABI of `IElysiumCoreWriter.openPosition` / `.closePosition`
 * (see `solidity/src/interfaces/IElysiumCoreWriter.sol`). The real venue
 * is a stub that ships post-mainnet; the exact fields may change. The mock
 * adapter in `src/venue-adapter.ts` populates `delegator` itself so the
 * daemon can also fill it in when the venue does not.
 */

import type { Address, Bytes32, Eip712Domain } from './types.js';

/** USD 6-decimal units. 1_000_000 = 1 USD. */
export type Usd6 = bigint;

/** Perp order side, mirrors `IElysiumCoreWriter.Side`. */
export type Side = 'Long' | 'Short';

/**
 * A pending intent for the venue to submit. Mirrors the intent submit ABI
 * of `IElysiumCoreWriter` as closely as the current stub interface allows.
 *
 * Fields:
 *   - `delegator`   : the delegator address. Filled by the mock venue when
 *                     the venue does not itself specify one; the daemon
 *                     re-fills it defensively before calling `submitTrade`.
 *   - `assetId`     : venue-specific asset id (ERC-20-like uint256 id).
 *   - `side`        : 'Long' | 'Short' per the venue enum.
 *   - `size`        : venue-specific size (units may vary by asset).
 *   - `notionalUsd` : notional in USD 6-decimal units, bounded by the
 *                     daemon's `maxNotionalUsd` and `maxPerOrderUsd`.
 *   - `slippageBps` : optional slippage tolerance in basis points.
 *   - `meta`        : arbitrary venue-specific bytes for the adapter.
 *
 * The `delegator` field is intentionally non-optional in the type so the
 * mock adapter and the daemon can agree on a single source of truth. When a
 * real venue adapter does not populate it, the daemon fills it in before
 * calling `submitTrade`.
 */
export interface PendingIntent {
  delegator: Address;
  assetId: bigint;
  side: Side;
  size: bigint;
  notionalUsd: bigint;
  slippageBps?: number;
  meta?: Bytes32;
}

/** Result of a single `submitTrade` call on a venue. */
export interface SubmitResult {
  /** Hex tx hash; a sentinel `0x…0` when the mock venue did not submit. */
  txHash: string;
  /** True iff the venue accepted the submission. */
  accepted: boolean;
  /** Human-readable reason, present when `accepted === false`. */
  reason?: string;
}

/** A single recorded submission on the venue. Used by tests and audits. */
export interface SubmittedTrade {
  /** Monotonically increasing index of the submission within the mock venue. */
  index: number;
  /** The delegator address the trade was signed on behalf of. */
  delegator: Address;
  /** The keeper address that signed the delegation. */
  keeper: Address;
  /** The nonce used for this delegation. Unique per (delegator, keeper). */
  nonce: bigint;
  /** USD 6-decimal notional charged against the delegation. */
  notionalUsd: bigint;
  /** Original intent that produced this trade. */
  intent: PendingIntent;
  /** Unix-ms timestamp when the trade was recorded. */
  at: number;
}

/** Sliding-window rate limit configuration (defaults in `daemon.ts`). */
export interface DaemonConfig {
  /** Poll interval between ticks, in ms. */
  watchIntervalMs: number;
  /** Max tx submissions in any rolling 60-second window. */
  maxTxsPerMinute: number;
  /** Max notional per delegation, USD 6-decimal units. */
  maxNotionalUsd: bigint;
  /** Max notional per order, USD 6-decimal units. */
  maxPerOrderUsd: bigint;
  /** Delegation TTL in seconds. `expiresAt = now + ttlSeconds`. */
  ttlSeconds: number;
  /** Monotonic nonce seed. Nonces are never reused. */
  nonceSeed: bigint;
  /** EIP-712 domain for signature computation. Required for signing. */
  domain: Eip712Domain;
  /** Event callback. Default: no-op. */
  onEvent: (evt: DaemonEvent) => void;
}

/**
 * Event types emitted by the daemon.
 *   - `submitted` : a delegation was signed and submitted to the venue
 *                    with `result.accepted === true`.
 *   - `skipped`   : the intent was rejected client-side (cap, rate limit,
 *                    venue-side revoke, or used-notional full). No
 *                    submission was attempted.
 *   - `failed`    : the intent was submitted but either returned
 *                    `accepted === false` or `submitTrade` threw.
 */
export type DaemonEventType = 'submitted' | 'skipped' | 'failed';

export interface DaemonEvent {
  type: DaemonEventType;
  intent: PendingIntent;
  delegation?: import('./types.js').Delegation;
  result?: SubmitResult;
  reason?: string;
  /** Monotonic nonce that was consumed (or would have been) by this event. */
  nonce: bigint;
}

/** Aggregated stats from a running daemon. Returned by `getStats()`. */
export interface KeeperDaemonStats {
  /** Number of times `tick()` has executed. */
  ticks: number;
  /** Number of events with `type === 'submitted'`. */
  submitted: number;
  /** Number of events with `type === 'skipped'`. */
  skipped: number;
  /** Number of events with `type === 'failed'`. */
  failed: number;
  /** The most recent nonce that was consumed (or -1n if none). */
  lastNonce: bigint;
}
