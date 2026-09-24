/**
 * KeeperWallet — wraps the keeper private key and exposes
 *   - address derivation,
 *   - delegation signing,
 *   - revoke transaction submission.
 *
 * ## Security
 *
 * The private key is held in a class-private field, loaded exactly
 * once in the constructor, and never copied. There is no accessor
 * for `pk`; the only way out of this class is `address`, `sign*`, and
 * `revoke`. See SECURITY.md.
 *
 * - **Never log `pk`.** Only `maskAddress(this.address)` in logs.
 * - **Never write `pk` to disk.**
 * - **Never put `pk` in a URL, query string, or error message.**
 *
 * ## Signing flow
 *
 * The contract's `_delegationHash` returns a `bytes32` digest and
 * passes it to `ecrecover(digest, v, r, s)`. Ethers v6's
 * `Wallet.signMessage` produces exactly this shape: it signs
 * `keccak256("\x19Ethereum Signed Message:\n32" || digest)`, which is
 * what `ecrecover` expects to see. We therefore sign the raw digest
 * produced by {@link delegationDigest} with `signMessage`.
 */

import { Contract, Wallet, type JsonRpcProvider, type ContractTransaction } from 'ethers';

import { isValidPrivateKey, maskAddress } from './utils.js';
import {
  type Address,
  type Bytes32,
  type Delegation,
  type Eip712Domain,
  type Signature,
} from './types.js';
import { delegationDigest } from './signing.js';

/** TradeOnlyAgent ABI subset — just the methods this runtime calls. */
export const TRADE_ONLY_AGENT_ABI = [
  'function revoke(address keeper)',
  'function isRevoked(address keeper) view returns (bool)',
  'function isValidDelegation(address from, tuple(address keeper, uint256[] assetIds, uint256 maxNotional, uint256 maxPerOrder, uint64 expiresAt, uint64 nonce, bytes32 salt) d, tuple(uint8 v, bytes32 r, bytes32 s) sig) view returns (bool)',
  'function remainingNotional(address venue, address delegator, tuple(address keeper, uint256[] assetIds, uint256 maxNotional, uint256 maxPerOrder, uint64 expiresAt, uint64 nonce, bytes32 salt) d) view returns (uint256)',
] as const;

/** Thrown when the wallet is asked to do something unsafe. */
export class KeeperError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'KeeperError';
  }
}

/**
 * The keeper wallet.
 *
 * @param pk 32-byte hex private key, with or without `0x` prefix.
 */
export class KeeperWallet {
  private readonly signer: Wallet;

  constructor(pk: string) {
    if (!isValidPrivateKey(pk)) {
      throw new KeeperError('KEEPER_PK must be a 32-byte hex string (66 chars with 0x)');
    }
    this.signer = new Wallet(pk);
  }

  /** Construct from a config-shaped object. */
  static fromConfig(config: { keeperPk: string }): KeeperWallet {
    return new KeeperWallet(config.keeperPk);
  }

  /** The keeper address (checksummed). */
  get address(): Address {
    return this.signer.address as Address;
  }

  /** Log-safe masked address. Use this in all log output. */
  get maskedAddress(): string {
    return maskAddress(this.address);
  }

  /**
   * Sign a delegation. Returns the raw (v, r, s) tuple.
   *
   * @param d The delegation to sign.
   * @param from The delegator address. Baked into the digest.
   *   Usually `from == this.address` for Stream A; for Stream B the
   *   caller passes the delegator address and the keeper signs on
   *   their behalf (the keeper must be authorised by the delegator
   *   out of band).
   * @param domain EIP-712 domain (chainId, verifyingContract, …).
   */
  async signDelegation(
    d: Delegation,
    from: Address,
    domain: Eip712Domain,
  ): Promise<Signature> {
    const digest = delegationDigest(from, d, domain);
    return this.signRaw(digest);
  }

  /**
   * Sign an arbitrary 32-byte digest. The signature is a raw
   * ECDSA over the digest bytes themselves — NOT wrapped in the
   * EIP-191 "\x19Ethereum Signed Message:\n32" prefix.
   *
   * This is what the contract expects: `_recover` passes the digest
   * directly to `ecrecover(digest, v, r, s)`, which is the raw
   * ECDSA check. `Wallet.signingKey.sign(bytes)` performs exactly
   * that check; `Wallet.signMessage` would wrap the digest in
   * EIP-191 framing and produce a signature the contract cannot
   * verify.
   *
   * This is the primitive that {@link signDelegation} uses. Exposed
   * separately so callers can sign other messages with the same key.
   */
  async signRaw(messageHash: Bytes32): Promise<Signature> {
    if (messageHash.length !== 66) {
      throw new KeeperError(
        `expected bytes32 message hash, got ${messageHash.length}-char hex`,
      );
    }
    const sig = this.signer.signingKey.sign(messageHash);
    return signatureFromBytes(sig.serialized);
  }

  /**
   * Submit a `revoke(keeper)` transaction to the TradeOnlyAgent.
   *
   * **The delegator submits this, not the keeper.** The `msg.sender`
   * on-chain is `this.address`; if the keeper is revoked, that
   * address is the one being revoked. In Stream A this is what we
   * want (the keeper authorises the revocation of itself). In Stream
   * B this method must be called with the delegator's wallet, not
   * the keeper's — use `KeeperWallet` constructed from the
   * delegator pk.
   */
  async revoke(
    agentAddress: string,
    keeperAddress: string,
    provider: JsonRpcProvider,
  ): Promise<ContractTransaction> {
    const conn = this.signer.connect(provider);
    const contract = new Contract(agentAddress, TRADE_ONLY_AGENT_ABI, conn);
    return contract.revoke(keeperAddress);
  }
}

/** Split a 65-byte compact signature into (v, r, s) with v ∈ {27, 28}. */
export function signatureFromBytes(compact: string): Signature {
  if (compact.length !== 132) {
    throw new KeeperError(
      `expected 65-byte compact signature, got ${compact.length}-char hex`,
    );
  }
  const r = '0x' + compact.slice(2, 66);
  const s = '0x' + compact.slice(66, 130);
  const vHex = compact.slice(130, 132);
  let v: number;
  if (vHex === '1b') v = 27;
  else if (vHex === '1c') v = 28;
  else {
    throw new KeeperError(`unexpected v byte 0x${vHex}`);
  }
  return { v: v as 27 | 28, r: r as Bytes32, s: s as Bytes32 };
}

/** Join (v, r, s) into a 65-byte compact signature. */
export function signatureToBytes(sig: Signature): string {
  // `sig.r` and `sig.s` are already `0x`-prefixed hex strings, so strip
  // the prefix before joining and prepend a single `0x` at the front.
  return '0x' + sig.r.slice(2) + sig.s.slice(2) + (sig.v === 27 ? '1b' : '1c');
}
