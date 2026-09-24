/**
 * EIP-712 delegation signing for TradeOnlyAgent.
 *
 * This file is the single most important code in the repo. The digest
 * we produce here must match, bit-for-bit, the digest computed by
 * `solidity/src/delegation/TradeOnlyAgent.sol::_delegationHash` and
 * `_domainSeparator`. Any drift between the two means either:
 *
 *   - on-chain `isValidDelegation` rejects valid signatures, or
 *   - (worse) on-chain accepts signatures that are not what we intended.
 *
 * Every constant below is annotated with the exact Solidity source
 * line it replicates. If you edit either side, edit the other.
 *
 * ## The `from` argument
 *
 * The Solidity `Delegation` struct does NOT include the delegator
 * address. Instead, `_delegationHash` hashes `_from` together with the
 * struct fields as the leading element of the outer `abi.encode`.
 * This is a deliberate deviation from textbook EIP-712:
 *
 *   - `TypedDataEncoder.hashTypedData` on the contract's exact
 *     typehash will NOT reproduce the contract digest — it will
 *     omit `_from` from the struct hash.
 *   - We therefore compute the digest manually here and sign it with
 *     `Wallet.signingKey.sign(digest)` (raw ECDSA over the digest
 *     bytes), NOT `Wallet.signMessage(digest)` which would add the
 *     EIP-191 framing `\x19Ethereum Signed Message:\n32` that the
 *     on-chain `ecrecover` in `_recover` does NOT expect.
 *
 * The test in `test/signing.test.ts` rebuilds the digest step-by-step
 * in JS using `AbiCoder` and asserts the intermediate bytes match this
 * module's output byte-for-byte. That is the drift guard.
 *
 * For the full spec see `docs/DELEGATION_SPEC.md` in the parent repo.
 */

import {
  BytesLike,
  concat,
  keccak256,
  toBeArray,
  recoverAddress,
} from 'ethers';

import type { Address, Bytes32, Delegation, Eip712Domain, Signature } from './types.js';

const UINT256_MAX = 2n ** 256n - 1n;
const UINT64_MAX = 2n ** 64n - 1n;

/**
 * `Delegation` type hash — the exact string from
 * `TradeOnlyAgent.sol:23-25`.
 */
export const DELEGATION_TYPE_STRING =
  'Delegation(address keeper,uint256[] assetIds,uint256 maxNotional,uint256 maxPerOrder,uint64 expiresAt,uint64 nonce,bytes32 salt)';

export const DELEGATION_TYPEHASH: Bytes32 = keccak256(
  utf8Bytes(DELEGATION_TYPE_STRING),
) as Bytes32;

/**
 * EIP-712 `Domain` type hash — the standard from EIP-712. Not
 * redefined by the contract.
 */
export const DOMAIN_TYPE_STRING =
  'EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)';

const DOMAIN_TYPEHASH: Bytes32 = keccak256(utf8Bytes(DOMAIN_TYPE_STRING)) as Bytes32;

function utf8Bytes(text: string): BytesLike {
  return new TextEncoder().encode(text);
}

/** Encode a uint256 as a 32-byte big-endian word. */
export function encodeUint256(value: bigint): BytesLike {
  if (value < 0n || value > UINT256_MAX) {
    throw new RangeError(`uint256 overflow: ${value}`);
  }
  return toBeArray(value, 32);
}

/** Encode a uint64 as a 32-byte ABI word. */
export function encodeUint64(value: bigint): BytesLike {
  if (value < 0n || value > UINT64_MAX) {
    throw new RangeError(`uint64 overflow: ${value}`);
  }
  return toBeArray(value, 32);
}

/**
 * Encode an address as a 32-byte ABI word (right-justified).
 */
export function encodeAddress(addr: Address): BytesLike {
  const lower = addr.slice(2).toLowerCase().padStart(64, '0');
  return ('0x' + lower) as `0x${string}`;
}

/** Encode a bytes32 as a 32-byte ABI word (identity, validated). */
export function encodeBytes32(v: Bytes32): BytesLike {
  if (v.length !== 66) throw new RangeError(`expected bytes32, got ${v.length}-char hex`);
  return v;
}

/** Encode a dynamic `uint256[]` in ABI encoding.
 *
 * Solidity's `abi.encode` of a dynamic array writes:
 *   [32-byte length][32-byte element][32-byte element]...
 *
 * For an **empty** array this produces a single 32-byte zero word.
 * Consequently
 *   `keccak256(abi.encode(uint256[](0))) == keccak256(bytes32(0))`,
 * which is exactly what `TradeOnlyAgent.sol:130` relies on.
 *
 * Do not "optimise" the empty case — the contract hashes the padded
 * encoding.
 */
export function encodeUint256Array(values: bigint[]): BytesLike {
  const parts: BytesLike[] = [encodeUint256(BigInt(values.length))];
  for (const v of values) {
    if (v < 0n || v > UINT256_MAX) {
      throw new RangeError(`uint256[] element out of range: ${v}`);
    }
    parts.push(encodeUint256(v));
  }
  return concat(parts);
}

/**
 * Compute the EIP-712 domain separator.
 *
 * Solidity source (TradeOnlyAgent.sol:147-156):
 *
 * ```solidity
 * function _domainSeparator() internal view returns (bytes32) {
 *     return keccak256(abi.encode(
 *         keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
 *         keccak256("TradeOnlyAgent v1"),
 *         keccak256("1"),
 *         block.chainid,
 *         address(this)
 *     ));
 * }
 * ```
 *
 * The `keccak256("TradeOnlyAgent v1")` and `keccak256("1")` calls
 * are the EIP-712 "hash of the string field" trick — the contract
 * hashes whatever strings are configured, so we hash the runtime
 * `domain.name` and `domain.version` (which must equal the
 * literals above for the digest to match).
 */
export function domainSeparator(domain: Eip712Domain): Bytes32 {
  const nameHash = keccak256(utf8Bytes(domain.name)) as Bytes32;
  const versionHash = keccak256(utf8Bytes(domain.version)) as Bytes32;
  const encoded = concat([
    DOMAIN_TYPEHASH,
    nameHash,
    versionHash,
    encodeUint256(BigInt(domain.chainId)),
    encodeAddress(domain.verifyingContract as Address),
  ]);
  return keccak256(encoded) as Bytes32;
}

/**
 * Compute the EIP-712 struct hash (a.k.a. `digestStruct`).
 *
 * Solidity source (TradeOnlyAgent.sol:125-137):
 *
 * ```solidity
 * bytes32 digestStruct = keccak256(abi.encode(
 *     _from,
 *     DELEGATION_TYPEHASH,
 *     d.keeper,
 *     keccak256(abi.encode(d.assetIds)),
 *     d.maxNotional,
 *     d.maxPerOrder,
 *     d.expiresAt,
 *     d.nonce,
 *     d.salt
 * ));
 * ```
 *
 * `assetIds` is a dynamic array, so we hash the ABI-encoded array
 * first and feed the resulting 32-byte value into the outer encode.
 * `_from` is the delegator address, not part of the struct itself.
 */
export function delegationStructHash(from: Address, d: Delegation): Bytes32 {
  const assetIdsHash = keccak256(encodeUint256Array(d.assetIds)) as Bytes32;
  const encoded = concat([
    encodeAddress(from),
    DELEGATION_TYPEHASH,
    encodeAddress(d.keeper),
    assetIdsHash,
    encodeUint256(d.maxNotional),
    encodeUint256(d.maxPerOrder),
    encodeUint64(d.expiresAt),
    encodeUint64(d.nonce),
    encodeBytes32(d.salt),
  ]);
  return keccak256(encoded) as Bytes32;
}

/**
 * Compute the final EIP-712 digest.
 *
 * Solidity source (TradeOnlyAgent.sol:138-144):
 *
 * ```solidity
 * return keccak256(abi.encodePacked(
 *     "\x19\x01",
 *     _domainSeparator(),
 *     digestStruct
 * ));
 * ```
 *
 * `abi.encodePacked` of a 2-byte prefix + two 32-byte values is a
 * byte-concat with no padding.
 */
export function delegationDigest(
  from: Address,
  d: Delegation,
  domain: Eip712Domain,
): Bytes32 {
  const ds = domainSeparator(domain);
  const dsHash = delegationStructHash(from, d);
  return keccak256(concat(['0x1901', ds, dsHash])) as Bytes32;
}

/**
 * Signer abstraction so `KeeperWallet` can be tested without a real
 * ethers Wallet. Implementations are passed a 32-byte digest and
 * return a Signature.
 */
export interface DigestSigner {
  /** Sign a raw 32-byte digest (no EIP-191 framing). Returns (v, r, s). */
  signRaw(message: Bytes32): Promise<Signature> | Signature;
  /** The signer's address, checksummed. */
  getAddress(): Promise<Address> | Address;
}

/**
 * Recover the signer address from a delegation + signature.
 *
 * `from` is the *intended* delegator — the same address baked into
 * the digest. The contract compares `ecrecover(digest) == from`, so
 * if the signature is valid, the recovered address must equal `from`.
 *
 * Offline verification only — this does NOT check expiry, revocation,
 * caps, or the canonicality of `s`. The on-chain `isValidDelegation`
 * does all of those.
 */
export function recoverDelegationSigner(
  from: Address,
  d: Delegation,
  domain: Eip712Domain,
  sig: Signature,
): string {
  const digest = delegationDigest(from, d, domain);
  return recoverFromDigest(digest, sig);
}

/** Recover an address from a signed digest. */
export function recoverFromDigest(digest: Bytes32, sig: Signature): string {
  // `sig.r` and `sig.s` are already `0x`-prefixed hex strings, so strip
  // the prefix before joining and prepend a single `0x` at the front.
  const compact = '0x' + sig.r.slice(2) + sig.s.slice(2) + (sig.v === 27 ? '1b' : '1c');
  return recoverAddress(digest, compact);
}
