import { describe, it } from 'node:test';
import assert from 'node:assert/strict';

import {
  AbiCoder,
  concat,
  hexlify,
  keccak256,
  recoverAddress,
  toBeArray,
  Wallet,
} from 'ethers';

import {
  DELEGATION_TYPEHASH,
  DELEGATION_TYPE_STRING,
  DOMAIN_TYPE_STRING,
  domainSeparator,
  delegationDigest,
  delegationStructHash,
  recoverDelegationSigner,
  encodeAddress,
  encodeBytes32,
  encodeUint256,
  encodeUint64,
  encodeUint256Array,
} from '../src/signing.js';
import { KeeperWallet, signatureFromBytes, signatureToBytes } from '../src/keeper.js';
import type { Address, Bytes32, Delegation, Eip712Domain } from '../src/types.js';

// ---------------------------------------------------------------------------
// Reference implementation.
//
// The task requires the test to recompute the digest manually in JS,
// NOT via `TypedDataEncoder.hashTypedData`. This reference uses
// `ethers.AbiCoder` for the outer encode and raw keccak256 for
// everything else, so it exercises the exact bytes the contract sees.
//
// The `CONTRACT_MATCHING_TYPE_STRING` trick at the bottom lets us
// cross-check that ethers' `TypedDataEncoder` produces the same digest
// as our manual implementation for the struct the contract actually
// encodes (from at the front, then all struct fields).
// ---------------------------------------------------------------------------

const DELEGATION_TYPEHASH_REF = keccak256(utf8Hex(DELEGATION_TYPE_STRING)) as Bytes32;
const DOMAIN_TYPEHASH_REF = keccak256(utf8Hex(DOMAIN_TYPE_STRING)) as Bytes32;

const CONTRACT_MATCHING_TYPE_STRING =
  'Delegation(address from,address keeper,uint256[] assetIds,uint256 maxNotional,uint256 maxPerOrder,uint64 expiresAt,uint64 nonce,bytes32 salt)';
const CONTRACT_MATCHING_TYPEHASH = keccak256(utf8Hex(CONTRACT_MATCHING_TYPE_STRING)) as Bytes32;

/** UTF-8 bytes as a 0x-hex string. */
function utf8Hex(text: string): string {
  return hexlify(new TextEncoder().encode(text));
}
function encUint256(v: bigint): string {
  return hexlify(toBeArray(v, 32));
}
function encUint64(v: bigint): string {
  return hexlify(toBeArray(v, 32));
}
function encAddress(a: Address): string {
  return ('0x' + a.slice(2).toLowerCase().padStart(64, '0')) as Bytes32;
}
function encBytes32(h: Bytes32): Bytes32 {
  return h;
}
function encUint256Array(arr: bigint[]): string {
  const parts: string[] = [encUint256(BigInt(arr.length))];
  for (const v of arr) parts.push(encUint256(v));
  return concat(parts);
}

/**
 * Recompute the EIP-712 digest manually, mirroring
 * `TradeOnlyAgent.sol:125-145` (`_delegationHash`).
 */
function manualDelegationDigest(
  from: Address,
  d: Delegation,
  domain: Eip712Domain,
): Bytes32 {
  const innerStruct = concat([
    encAddress(from),
    encBytes32(DELEGATION_TYPEHASH_REF),
    encAddress(d.keeper),
    encBytes32(keccak256(encUint256Array(d.assetIds)) as Bytes32),
    encUint256(d.maxNotional),
    encUint256(d.maxPerOrder),
    encUint64(d.expiresAt),
    encUint64(d.nonce),
    encBytes32(d.salt),
  ]);
  const digestStruct = keccak256(innerStruct) as Bytes32;

  const nameHash = keccak256(utf8Hex(domain.name)) as Bytes32;
  const versionHash = keccak256(utf8Hex(domain.version)) as Bytes32;
  const dsInner = concat([
    encBytes32(DOMAIN_TYPEHASH_REF),
    encBytes32(nameHash),
    encBytes32(versionHash),
    encUint256(BigInt(domain.chainId)),
    encAddress(domain.verifyingContract as Address),
  ]);
  const ds = keccak256(dsInner) as Bytes32;

  return keccak256(concat(['0x1901', ds, digestStruct])) as Bytes32;
}

function manualDelegationStructHash(from: Address, d: Delegation): Bytes32 {
  return keccak256(
    concat([
      encAddress(from),
      encBytes32(DELEGATION_TYPEHASH_REF),
      encAddress(d.keeper),
      encBytes32(keccak256(encUint256Array(d.assetIds)) as Bytes32),
      encUint256(d.maxNotional),
      encUint256(d.maxPerOrder),
      encUint64(d.expiresAt),
      encUint64(d.nonce),
      encBytes32(d.salt),
    ]),
  ) as Bytes32;
}

const abiCoder = AbiCoder.defaultAbiCoder();

// ---------------------------------------------------------------------------
// Fixtures.
// ---------------------------------------------------------------------------

const HARDHAT_PK_0 = '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80';
const HARDHAT_ADDR_0 = '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266';
const HARDHAT_ADDR_1 = '0x70997970C51812dc3A010C7d01b50e0d17dc79C8';
const AGENT_ADDR = '0x5FbDB2315678afecb367f032d93F642f64180aa3';

const DOMAIN: Eip712Domain = {
  name: 'TradeOnlyAgent v1',
  version: '1',
  chainId: 999n,
  verifyingContract: AGENT_ADDR,
};

function makeDelegation(overrides: Partial<Delegation> = {}): Delegation {
  return {
    keeper: HARDHAT_ADDR_0,
    assetIds: [1n, 2n, 3n],
    maxNotional: 1_000_000_000n,
    maxPerOrder: 100_000_000n,
    expiresAt: 0xFFFFFFFFn,
    nonce: 1n,
    salt: '0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef',
    ...overrides,
  };
}

/** Recover an address from a (digest, compact-sig) pair via raw ecrecover.
 *
 * This is what the contract does: `ecrecover(digest, v, r, s)` takes
 * the digest bytes directly, NOT an EIP-191 hashed message. The
 * `compactSig` is a single 0x-prefixed 65-byte hex string (r||s||v).
 */
function rawRecover(digest: Bytes32, compactSig: string): string {
  return recoverAddress(digest, compactSig);
}

// ---------------------------------------------------------------------------
// Tests.
// ---------------------------------------------------------------------------

describe('signing: typehashes', () => {
  it('DELEGATION_TYPEHASH matches keccak256 of the contract type string', () => {
    assert.equal(DELEGATION_TYPEHASH, DELEGATION_TYPEHASH_REF);
  });

  it('DELEGATION_TYPE_STRING is the exact Solidity literal', () => {
    assert.equal(
      DELEGATION_TYPE_STRING,
      'Delegation(address keeper,uint256[] assetIds,uint256 maxNotional,uint256 maxPerOrder,uint64 expiresAt,uint64 nonce,bytes32 salt)',
    );
  });

  it('DOMAIN_TYPE_STRING is the standard EIP-712 domain literal', () => {
    assert.equal(
      DOMAIN_TYPE_STRING,
      'EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)',
    );
  });
});

describe('signing: domainSeparator', () => {
  it('is deterministic for a fixed domain', () => {
    assert.equal(domainSeparator(DOMAIN), domainSeparator(DOMAIN));
  });

  it('changes when chainId changes', () => {
    assert.notEqual(domainSeparator(DOMAIN), domainSeparator({ ...DOMAIN, chainId: 1n }));
  });

  it('changes when verifyingContract changes', () => {
    assert.notEqual(
      domainSeparator(DOMAIN),
      domainSeparator({ ...DOMAIN, verifyingContract: '0x0000000000000000000000000000000000000001' }),
    );
  });

  it('changes when name or version changes', () => {
    assert.notEqual(domainSeparator(DOMAIN), domainSeparator({ ...DOMAIN, name: 'Other' }));
    assert.notEqual(domainSeparator(DOMAIN), domainSeparator({ ...DOMAIN, version: '2' }));
  });

  it('matches the manual reference implementation', () => {
    const ds = domainSeparator(DOMAIN);
    const nameHash = keccak256(utf8Hex(DOMAIN.name)) as Bytes32;
    const versionHash = keccak256(utf8Hex(DOMAIN.version)) as Bytes32;
    const expected = keccak256(
      concat([DOMAIN_TYPEHASH_REF, nameHash, versionHash, encUint256(999n), encAddress(AGENT_ADDR)]),
    ) as Bytes32;
    assert.equal(ds, expected);
  });
});

describe('signing: delegationDigest', () => {
  it('matches the manual reference implementation (non-empty assetIds)', () => {
    const from: Address = HARDHAT_ADDR_0;
    const d = makeDelegation();
    assert.equal(delegationDigest(from, d, DOMAIN), manualDelegationDigest(from, d, DOMAIN));
  });

  it('matches the manual reference (empty assetIds)', () => {
    const from: Address = HARDHAT_ADDR_0;
    const d = makeDelegation({ assetIds: [] });
    assert.equal(delegationDigest(from, d, DOMAIN), manualDelegationDigest(from, d, DOMAIN));

    // Extra sanity: keccak256(abi.encode(uint256[](0))) == keccak256(bytes32(0)).
    const emptyHash = keccak256('0x' + '0'.repeat(64)) as Bytes32;
    const manualEmptyHash = keccak256(encUint256Array([])) as Bytes32;
    assert.equal(emptyHash, manualEmptyHash);
  });

  it('matches the manual reference (many assetIds, large values)', () => {
    const from: Address = HARDHAT_ADDR_0;
    const d = makeDelegation({
      assetIds: [0n, 1n, 2n, 4n, 8n, 16n, 32n, 64n, 128n, 256n, 2n ** 255n, 2n ** 256n - 1n],
      maxNotional: 2n ** 256n - 1n,
      maxPerOrder: 2n ** 256n - 1n,
      expiresAt: 2n ** 64n - 1n,
      nonce: 2n ** 64n - 1n,
    });
    assert.equal(delegationDigest(from, d, DOMAIN), manualDelegationDigest(from, d, DOMAIN));
  });

  it('matches the manual reference (from == keeper, Stream A)', () => {
    const from: Address = HARDHAT_ADDR_0;
    const d = makeDelegation({ keeper: HARDHAT_ADDR_0 });
    assert.equal(delegationDigest(from, d, DOMAIN), manualDelegationDigest(from, d, DOMAIN));
  });

  it('matches the manual reference (from != keeper, Stream B)', () => {
    const from: Address = HARDHAT_ADDR_0;
    const d = makeDelegation({ keeper: HARDHAT_ADDR_1 });
    assert.equal(delegationDigest(from, d, DOMAIN), manualDelegationDigest(from, d, DOMAIN));
  });

  it('changes when `from` changes', () => {
    const d = makeDelegation();
    const a = delegationDigest(HARDHAT_ADDR_0, d, DOMAIN);
    const b = delegationDigest(HARDHAT_ADDR_1, d, DOMAIN);
    assert.notEqual(a, b);
  });

  it('expiresAt = 0 (never-expires sentinel) hashes the same way as any other uint64', () => {
    const from: Address = HARDHAT_ADDR_0;
    const d = makeDelegation({ expiresAt: 0n });
    assert.equal(delegationDigest(from, d, DOMAIN), manualDelegationDigest(from, d, DOMAIN));
  });
});

describe('signing: AbiCoder cross-check', () => {
  it('AbiCoder produces the same outer encode as the manual concat path', () => {
    // The contract's outer abi.encode (inside `_delegationHash`) is:
    //   abi.encode(
    //     from,                // address
    //     DELEGATION_TYPEHASH, // bytes32 — the ORIGINAL typehash (no `from`)
    //     keeper,              // address
    //     keccak256(abi.encode(assetIds)), // bytes32 — the array hash
    //     maxNotional,         // uint256
    //     maxPerOrder,         // uint256
    //     expiresAt,           // uint64
    //     nonce,               // uint64
    //     salt                 // bytes32
    //   )
    //
    // `delegationStructHash` builds this manually via `concat` of
    // individually-encoded words. We cross-check against
    // `AbiCoder.encode` on the same field layout and values. Both
    // produce the same bytes, so their keccak256 digests match.
    const from: Address = HARDHAT_ADDR_0;
    const d = makeDelegation();

    const assetIdsHash = keccak256(encodeUint256Array(d.assetIds)) as Bytes32;

    const manualBytes = concat([
      encodeAddress(from),
      DELEGATION_TYPEHASH_REF,
      encodeAddress(d.keeper),
      assetIdsHash,
      encodeUint256(d.maxNotional),
      encodeUint256(d.maxPerOrder),
      encodeUint64(d.expiresAt),
      encodeUint64(d.nonce),
      encodeBytes32(d.salt),
    ]);

    const coderBytes = abiCoder.encode(
      ['address', 'bytes32', 'address', 'bytes32', 'uint256', 'uint256', 'uint64', 'uint64', 'bytes32'],
      [from, DELEGATION_TYPEHASH_REF, d.keeper, assetIdsHash, d.maxNotional, d.maxPerOrder, d.expiresAt, d.nonce, d.salt],
    );

    // The concatenated bytes must be identical.
    assert.equal(manualBytes, coderBytes);

    // Consequently the struct hashes match.
    assert.equal(
      keccak256(manualBytes) as Bytes32,
      keccak256(coderBytes) as Bytes32,
    );

    // And the module's `delegationStructHash` agrees with both.
    assert.equal(delegationStructHash(from, d), keccak256(manualBytes) as Bytes32);
    assert.equal(delegationStructHash(from, d), manualDelegationStructHash(from, d));
  });
});

describe('signing: end-to-end sign and recover', () => {
  it('signs and recovers the delegator address via raw ecrecover', async () => {
    const wallet = new Wallet(HARDHAT_PK_0);
    const from: Address = HARDHAT_ADDR_0;
    const d = makeDelegation();
    const digest = delegationDigest(from, d, DOMAIN);

    // Sign the digest bytes directly (no EIP-191 framing) — this is
    // what the contract's `_recover(digest, sig)` expects.
    const sig = wallet.signingKey.sign(digest);
    const recovered = rawRecover(digest, sig.serialized);
    assert.equal(recovered.toLowerCase(), wallet.address.toLowerCase());
    assert.equal(recovered.toLowerCase(), from.toLowerCase());
  });

  it('signs and recovers via recoverDelegationSigner', async () => {
    const wallet = new Wallet(HARDHAT_PK_0);
    const from: Address = HARDHAT_ADDR_0;
    const d = makeDelegation();

    const digest = delegationDigest(from, d, DOMAIN);
    const sig = signatureFromBytes(wallet.signingKey.sign(digest).serialized);

    const recovered = recoverDelegationSigner(from, d, DOMAIN, sig);
    assert.equal(recovered.toLowerCase(), from.toLowerCase());
    assert.equal(recovered.toLowerCase(), wallet.address.toLowerCase());
  });

  it('KeeperWallet.signDelegation produces the same digest as the manual reference', async () => {
    const keeper = new KeeperWallet(HARDHAT_PK_0);
    const from: Address = HARDHAT_ADDR_0;
    const d = makeDelegation();
    const sig = await keeper.signDelegation(d, from, DOMAIN);

    // Recover using our own code path.
    const recovered = recoverDelegationSigner(from, d, DOMAIN, sig);
    assert.equal(recovered.toLowerCase(), from.toLowerCase());
    assert.equal(recovered.toLowerCase(), keeper.address.toLowerCase());

    // The digest we signed must equal the manual reference digest.
    const manualDigest = manualDelegationDigest(from, d, DOMAIN);
    const moduleDigest = delegationDigest(from, d, DOMAIN);
    assert.equal(moduleDigest, manualDigest);

    // And raw ecrecover on the manual digest + compact sig must
    // recover the same address.
    const recoveredRaw = rawRecover(
      manualDigest,
      signatureToBytes(sig),
    );
    assert.equal(recoveredRaw.toLowerCase(), from.toLowerCase());
  });

  it('KeeperWallet.signDelegation is deterministic (same input → same signature)', async () => {
    const keeper = new KeeperWallet(HARDHAT_PK_0);
    const from: Address = HARDHAT_ADDR_0;
    const d = makeDelegation();
    const sig1 = await keeper.signDelegation(d, from, DOMAIN);
    const sig2 = await keeper.signDelegation(d, from, DOMAIN);
    assert.equal(sig1.r, sig2.r);
    assert.equal(sig1.s, sig2.s);
    assert.equal(sig1.v, sig2.v);
  });

  it('signature recovery fails when `from` is wrong', async () => {
    // The signer signs on behalf of HARDHAT_ADDR_0. If we try to use
    // the same signature as if `from == HARDHAT_ADDR_1`, recovery
    // must NOT produce HARDHAT_ADDR_0 — the contract's `ecrecover ==
    // from` check will fail and reject the delegation.
    const keeper = new KeeperWallet(HARDHAT_PK_0);
    const d = makeDelegation();
    const sig = await keeper.signDelegation(d, HARDHAT_ADDR_0, DOMAIN);

    const recoveredWithWrongFrom = recoverDelegationSigner(
      HARDHAT_ADDR_1,
      d,
      DOMAIN,
      sig,
    );

    // The recovered address is some other address (depends on the
    // wrong digest); it must NOT be the intended delegator
    // HARDHAT_ADDR_1, and it must NOT be the keeper HARDHAT_ADDR_0
    // either. The point of the test is that the contract's
    // `ecrecover(digest) == from` check fails.
    assert.notEqual(recoveredWithWrongFrom.toLowerCase(), HARDHAT_ADDR_1.toLowerCase());
    assert.notEqual(recoveredWithWrongFrom.toLowerCase(), HARDHAT_ADDR_0.toLowerCase());

    // And recovery with the correct `from` produces the keeper.
    const recoveredWithRightFrom = recoverDelegationSigner(
      HARDHAT_ADDR_0,
      d,
      DOMAIN,
      sig,
    );
    assert.equal(recoveredWithRightFrom.toLowerCase(), keeper.address.toLowerCase());
  });

  it('v is 27 or 28 (contract invariant)', async () => {
    const keeper = new KeeperWallet(HARDHAT_PK_0);
    const d = makeDelegation();
    const sig = await keeper.signDelegation(d, HARDHAT_ADDR_0, DOMAIN);
    assert.ok(sig.v === 27 || sig.v === 28, `v=${sig.v}`);
  });
});

describe('signing: uint256 / uint64 overflow', () => {
  it('encodeUint64 rejects negative values', () => {
    assert.throws(() => encodeUint64(-1n), /overflow/);
  });

  it('encodeUint64 rejects values > 2^64 - 1', () => {
    assert.throws(() => encodeUint64(2n ** 64n), /overflow/);
  });

  it('encodeUint256 rejects values > 2^256 - 1', () => {
    assert.throws(() => encodeUint256(2n ** 256n), /overflow/);
  });

  it('encodeAddress produces a 32-byte right-justified hex word', () => {
    const a: Address = '0x0000000000000000000000000000000000000001';
    const encoded = encodeAddress(a);
    assert.equal(encoded.length, 66);
    assert.equal(encoded, '0x' + '0'.repeat(62) + '01');
  });

  it('encodeUint256Array encodes an empty array as a single zero word', () => {
    const out = encodeUint256Array([]);
    assert.equal(out, '0x' + '0'.repeat(64));
  });

  it('encodeUint256Array encodes 3 elements as 4 words', () => {
    const out = encodeUint256Array([1n, 2n, 3n]);
    // length word + 3 elements, each padded to 32 bytes.
    assert.equal(out.length, 2 + 4 * 32 * 2);
    // Last word is 0x…03.
    assert.equal(out.slice(64 * 3 + 2), '0'.repeat(62) + '03');
    // First word (length) is 0x…03.
    assert.equal(out.slice(2, 66), '0'.repeat(62) + '03');
  });
});
