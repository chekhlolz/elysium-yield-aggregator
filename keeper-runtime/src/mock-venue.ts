/**
 * MockVenue — an offline venue simulator for local testing.
 *
 * A real venue (ElysiumCoreWriter, in Phase 2) does two things:
 *   1. Calls `TradeOnlyAgent.isValidDelegation` on-chain to verify
 *      the signature.
 *   2. Calls `TradeOnlyAgent.recordExecution` on-chain to charge
 *      the delegation's notional cap.
 *
 * This mock does the first step purely in JS and tracks the notional
 * cap in memory. It is used by `scripts/run-example.ts` to demonstrate
 * the end-to-end flow without needing an Anvil instance.
 *
 * The signature verification here uses {@link recoverDelegationSigner}
 * from `signing.ts`, which is the *same* code path the on-chain
 * contract uses (well, the same digest computation, with `ecrecover`
 * swapped for `ethers.recoverAddress`). So a signature that passes
 * here will also pass on-chain, and vice versa.
 */

import { getAddress } from 'ethers';

import {
  type Address,
  type Delegation,
  type Eip712Domain,
  type Signature,
} from './types.js';
import { recoverDelegationSigner } from './signing.js';

export interface VenueSubmitResult {
  accepted: boolean;
  usedNotional: bigint;
  remainingNotional: bigint;
  note?: string;
}

/**
 * A venue that verifies delegations offline and tracks used notional
 * in memory. Not a substitute for the on-chain verifier — use that in
 * production.
 *
 * The venue is bound to a single `Eip712Domain` at construction.
 * This is intentional: the domain (chainId, verifyingContract) is a
 * property of the deployment, not of each submission.
 */
export class MockVenue {
  private readonly venueAddress: Address;
  private readonly domain: Eip712Domain;
  private readonly usedNotional = new Map<string, bigint>();

  constructor(opts: { venueAddress?: Address; domain: Eip712Domain }) {
    // Use a canonical zero address if the caller does not supply one.
    // This is only used as the "venue" axis of the notional key — it
    // does not affect signature recovery.
    this.venueAddress = (opts.venueAddress ?? ZERO_MOCK_VENUE) as Address;
    this.domain = opts.domain;
  }

  /** The venue's on-chain address (used as the venue axis in caps). */
  get address(): Address {
    return this.venueAddress;
  }

  /** The EIP-712 domain bound to this venue. */
  get boundDomain(): Eip712Domain {
    return this.domain;
  }

  /**
   * Submit an intent under a delegation.
   *
   * @returns accepted `true` iff the signature is valid AND the
   *   notional fits within the remaining cap.
   */
  async submit(
    from: Address,
    d: Delegation,
    sig: Signature,
    notional: bigint,
  ): Promise<VenueSubmitResult> {
    // 1. Signature recovery. This is the offline equivalent of the
    //    contract's `ecrecover(digest, v, r, s) == from` check.
    const recovered = recoverDelegationSigner(from, d, this.domain, sig);
    if (recovered !== getAddress(from)) {
      return {
        accepted: false,
        usedNotional: this.getUsed(from, d),
        remainingNotional: BigInt(0),
        note: `signature recovered to ${recovered}, expected ${from}`,
      };
    }

    // 2. Cap check. The on-chain contract tracks (venue, delegator,
    //    keeper, nonce) → used; we mirror that key here.
    const key = this.key(from, d);
    const used = this.usedNotional.get(key) ?? 0n;
    if (used + notional > d.maxNotional) {
      return {
        accepted: false,
        usedNotional: used,
        remainingNotional: d.maxNotional - used,
        note: 'exceeds maxNotional',
      };
    }

    // 3. Per-order cap.
    if (notional > d.maxPerOrder) {
      return {
        accepted: false,
        usedNotional: used,
        remainingNotional: d.maxNotional - used,
        note: 'exceeds maxPerOrder',
      };
    }

    // 4. Commit.
    this.usedNotional.set(key, used + notional);
    return {
      accepted: true,
      usedNotional: used + notional,
      remainingNotional: d.maxNotional - (used + notional),
    };
  }

  /** Get the used notional for a specific (from, delegation). */
  getUsed(from: Address, d: Delegation): bigint {
    return this.usedNotional.get(this.key(from, d)) ?? 0n;
  }

  /** Get the remaining notional for a specific (from, delegation). */
  getRemaining(from: Address, d: Delegation): bigint {
    const used = this.getUsed(from, d);
    return used >= d.maxNotional ? 0n : d.maxNotional - used;
  }

  /** Reset all used-notional state. Useful for tests. */
  reset(): void {
    this.usedNotional.clear();
  }

  private key(from: Address, d: Delegation): string {
    return [
      this.venueAddress.toLowerCase(),
      from.toLowerCase(),
      d.keeper.toLowerCase(),
      d.nonce.toString(),
    ].join(':');
  }
}

const ZERO_MOCK_VENUE = '0x0000000000000000000000000000000000000000';
