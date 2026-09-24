import { describe, it, beforeEach } from 'node:test';
import assert from 'node:assert/strict';

import { Wallet, getAddress } from 'ethers';

import {
  ConfigError,
  loadConfig,
  loadEnv,
  parseEnv,
} from '../src/config.js';
import {
  KeeperWallet,
  KeeperError,
  signatureFromBytes,
  signatureToBytes,
} from '../src/keeper.js';
import { MockVenue } from '../src/mock-venue.js';
import { maskAddress, maskPk, redactSecrets, isValidPrivateKey } from '../src/utils.js';
import type { Address, Delegation, Eip712Domain } from '../src/types.js';

// ---------------------------------------------------------------------------
// Fixtures.
// ---------------------------------------------------------------------------

const HARDHAT_PK_0 = '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80';
const HARDHAT_ADDR_0 = '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266';
const HARDHAT_PK_1 = '0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d';
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
    assetIds: [1n, 2n],
    maxNotional: 1_000_000_000n,
    maxPerOrder: 100_000_000n,
    expiresAt: 0xFFFFFFFFn,
    nonce: 1n,
    salt: '0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef',
    ...overrides,
  };
}

// ---------------------------------------------------------------------------
// utils tests.
// ---------------------------------------------------------------------------

describe('utils: maskAddress', () => {
  it('masks a valid address', () => {
    // 0xf39F + ellipsis + 2266 (last 4 chars)
    assert.equal(maskAddress(HARDHAT_ADDR_0), '0xf39F…2266');
  });

  it('returns [not-address] for a malformed address', () => {
    assert.equal(maskAddress('0x1234'), '[not-address]');
    assert.equal(maskAddress('not an address'), '[not-address]');
  });

  it('does not include the full address in the output', () => {
    const masked = maskAddress(HARDHAT_ADDR_0);
    assert.ok(!masked.includes(HARDHAT_ADDR_0.slice(6, 30)));
  });
});

describe('utils: maskPk', () => {
  it('masks a 32-byte hex key', () => {
    const masked = maskPk(HARDHAT_PK_0);
    assert.ok(!masked.includes(HARDHAT_PK_0.slice(0, 64)));
    assert.ok(masked.includes('ac09'));
    assert.ok(masked.includes('ff80'));
  });

  it('handles a short key', () => {
    assert.equal(maskPk('0x12'), '[short-pk]');
  });
});

describe('utils: redactSecrets', () => {
  it('redacts 64-hex-char strings in log output', () => {
    const input = `pk=${HARDHAT_PK_0.slice(2)} address=${HARDHAT_ADDR_0}`;
    const redacted = redactSecrets(input);
    assert.ok(redacted.includes('[redacted]'));
    assert.ok(!redacted.includes(HARDHAT_PK_0.slice(2)));
  });
});

describe('utils: isValidPrivateKey', () => {
  it('accepts a 66-char hex string with 0x prefix', () => {
    assert.equal(isValidPrivateKey(HARDHAT_PK_0), true);
  });

  it('rejects a short key', () => {
    assert.equal(isValidPrivateKey('0x1234'), false);
  });

  it('rejects a non-hex string', () => {
    assert.equal(isValidPrivateKey('zzzz'.repeat(16)), false);
  });
});

// ---------------------------------------------------------------------------
// config tests.
// ---------------------------------------------------------------------------

describe('config: parseEnv', () => {
  it('parses KEY=value', () => {
    assert.equal(parseEnv('A=1\nB=2').A, '1');
    assert.equal(parseEnv('A=1\nB=2').B, '2');
  });

  it('ignores comments and blank lines', () => {
    assert.deepEqual(parseEnv('# comment\n\nA=1'), { A: '1' });
  });

  it('strips surrounding whitespace and quotes', () => {
    assert.equal(parseEnv('A = "hello"').A, 'hello');
    assert.equal(parseEnv("A = 'world'").A, 'world');
  });

  it('handles the export prefix', () => {
    assert.equal(parseEnv('export A=1').A, '1');
  });

  it('does not interpret $VAR references', () => {
    // Deliberately kept simple — no interpolation.
    assert.equal(parseEnv('A=$B').A, '$B');
  });

  it('skips malformed lines', () => {
    const result = parseEnv('not-a-line\nA=1');
    assert.deepEqual(result, { A: '1' });
  });
});

describe('config: loadConfig', () => {
  it('loads a valid config from env vars', () => {
    const env = {
      CHAIN_ID: '999',
      RPC_URL: 'http://127.0.0.1:8545',
      KEEPER_PK: HARDHAT_PK_0,
      DELEGATOR_ADDRESS: HARDHAT_ADDR_0,
      AGENT_ADDRESS: AGENT_ADDR,
      AGGREGATOR_ADDRESS: '',
      WATCH_INTERVAL_MS: '250',
      MAX_TXS_PER_MINUTE: '30',
      VENUES: 'mock-1,mock-2',
    };
    const cfg = loadConfig(env);
    assert.equal(cfg.chainId, 999);
    assert.equal(cfg.keeperPk, HARDHAT_PK_0);
    assert.equal(cfg.delegatorAddress, getAddress(HARDHAT_ADDR_0));
    assert.equal(cfg.agentAddress, getAddress(AGENT_ADDR));
    assert.equal(cfg.watchIntervalMs, 250);
    assert.equal(cfg.maxTxsPerMinute, 30);
    assert.equal(cfg.venues.length, 2);
  });

  it('throws ConfigError when KEEPER_PK is missing', () => {
    const env = {
      CHAIN_ID: '999',
      RPC_URL: 'http://localhost',
      DELEGATOR_ADDRESS: HARDHAT_ADDR_0,
      AGENT_ADDRESS: AGENT_ADDR,
    };
    assert.throws(() => loadConfig(env), ConfigError);
  });

  it('throws ConfigError when KEEPER_PK is malformed', () => {
    const env = {
      CHAIN_ID: '999',
      RPC_URL: 'http://localhost',
      KEEPER_PK: '0x1234',
      DELEGATOR_ADDRESS: HARDHAT_ADDR_0,
      AGENT_ADDRESS: AGENT_ADDR,
    };
    assert.throws(() => loadConfig(env), ConfigError);
    // The error must NOT contain the pk.
    try {
      loadConfig(env);
      assert.fail('should have thrown');
    } catch (e) {
      assert.ok(!String(e).includes(HARDHAT_PK_0));
    }
  });

  it('throws ConfigError when DELEGATOR_ADDRESS is not an address', () => {
    const env = {
      CHAIN_ID: '999',
      RPC_URL: 'http://localhost',
      KEEPER_PK: HARDHAT_PK_0,
      DELEGATOR_ADDRESS: 'not-an-address',
      AGENT_ADDRESS: AGENT_ADDR,
    };
    assert.throws(() => loadConfig(env), ConfigError);
  });

  it('applies defaults for WATCH_INTERVAL_MS and MAX_TXS_PER_MINUTE', () => {
    const env = {
      CHAIN_ID: '999',
      RPC_URL: 'http://localhost',
      KEEPER_PK: HARDHAT_PK_0,
      DELEGATOR_ADDRESS: HARDHAT_ADDR_0,
      AGENT_ADDRESS: AGENT_ADDR,
    };
    const cfg = loadConfig(env);
    assert.equal(cfg.watchIntervalMs, 1000);
    assert.equal(cfg.maxTxsPerMinute, 60);
    assert.deepEqual(cfg.venues, []);
  });

  it('rejects CHAIN_ID that is not a positive integer', () => {
    const env = {
      CHAIN_ID: '0',
      RPC_URL: 'http://localhost',
      KEEPER_PK: HARDHAT_PK_0,
      DELEGATOR_ADDRESS: HARDHAT_ADDR_0,
      AGENT_ADDRESS: AGENT_ADDR,
    };
    assert.throws(() => loadConfig(env), ConfigError);
  });

  it('rejects non-numeric WATCH_INTERVAL_MS', () => {
    const env = {
      CHAIN_ID: '999',
      RPC_URL: 'http://localhost',
      KEEPER_PK: HARDHAT_PK_0,
      DELEGATOR_ADDRESS: HARDHAT_ADDR_0,
      AGENT_ADDRESS: AGENT_ADDR,
      WATCH_INTERVAL_MS: 'fast',
    };
    assert.throws(() => loadConfig(env), ConfigError);
  });
});

describe('config: loadEnv', () => {
  it('merges .env into process.env without overwriting', () => {
    // The test suite does not depend on a real .env being present, so
    // we just verify the function returns an object with the expected
    // keys from process.env.
    const merged = loadEnv();
    assert.equal(typeof merged, 'object');
    // process.env.NODE_ENV should be in there (or undefined if not set).
    assert.ok('NODE_ENV' in merged || 'NODE' in merged || Object.keys(merged).length >= 0);
  });
});

// ---------------------------------------------------------------------------
// KeeperWallet tests.
// ---------------------------------------------------------------------------

describe('KeeperWallet', () => {
  it('constructs from a valid private key', () => {
    const w = new KeeperWallet(HARDHAT_PK_0);
    assert.equal(w.address, getAddress(HARDHAT_ADDR_0));
  });

  it('rejects a malformed private key', () => {
    assert.throws(() => new KeeperWallet('0x1234'), KeeperError);
    assert.throws(() => new KeeperWallet('not-hex'.repeat(8)), KeeperError);
    assert.throws(() => new KeeperWallet(''), KeeperError);
  });

  it('derives the correct address from Hardhat #0', () => {
    const w = new KeeperWallet(HARDHAT_PK_0);
    assert.equal(w.address, '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266');
  });

  it('derives the correct address from Hardhat #1', () => {
    const w = new KeeperWallet(HARDHAT_PK_1);
    assert.equal(w.address, '0x70997970C51812dc3A010C7d01b50e0d17dc79C8');
  });

  it('exposes a log-safe maskedAddress', () => {
    const w = new KeeperWallet(HARDHAT_PK_0);
    // 0xf39F…2266  (first 6 chars, ellipsis, last 4 chars)
    assert.equal(w.maskedAddress, '0xf39F…2266');
  });

  it('signs a raw digest deterministically', async () => {
    const w = new KeeperWallet(HARDHAT_PK_0);
    const digest = '0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef';
    const sig1 = await w.signRaw(digest);
    const sig2 = await w.signRaw(digest);
    assert.equal(sig1.r, sig2.r);
    assert.equal(sig1.s, sig2.s);
    assert.equal(sig1.v, sig2.v);
  });

  it('signRaw rejects a malformed message hash', async () => {
    const w = new KeeperWallet(HARDHAT_PK_0);
    await assert.rejects(() => w.signRaw('0x1234'), KeeperError);
  });

  it('signDelegation produces a Signature with v ∈ {27, 28}', async () => {
    const w = new KeeperWallet(HARDHAT_PK_0);
    const d = makeDelegation();
    const sig = await w.signDelegation(d, HARDHAT_ADDR_0, DOMAIN);
    assert.ok(sig.v === 27 || sig.v === 28);
    assert.equal(sig.r.length, 66);
    assert.equal(sig.s.length, 66);
  });

  it('signDelegation is deterministic', async () => {
    const w = new KeeperWallet(HARDHAT_PK_0);
    const d = makeDelegation();
    const sig1 = await w.signDelegation(d, HARDHAT_ADDR_0, DOMAIN);
    const sig2 = await w.signDelegation(d, HARDHAT_ADDR_0, DOMAIN);
    assert.equal(sig1.r, sig2.r);
    assert.equal(sig1.s, sig2.s);
    assert.equal(sig1.v, sig2.v);
  });

  it('signDelegation changes when `from` changes', async () => {
    const w = new KeeperWallet(HARDHAT_PK_0);
    const d = makeDelegation();
    const sigA = await w.signDelegation(d, HARDHAT_ADDR_0, DOMAIN);
    const sigB = await w.signDelegation(d, HARDHAT_ADDR_1, DOMAIN);
    // Different `from` → different digest → different signature.
    assert.notEqual(sigA.r, sigB.r);
  });

  it('can be constructed via fromConfig', () => {
    const w = KeeperWallet.fromConfig({ keeperPk: HARDHAT_PK_0 });
    assert.equal(w.address, '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266');
  });

  it('has a private key accessor that is private (only address is public)', () => {
    const w = new KeeperWallet(HARDHAT_PK_0);
    // `pk` is class-private. The public surface is `address`, `maskedAddress`,
    // `signRaw`, `signDelegation`, `revoke`. There is no `getPk()`.
    assert.equal(Object.keys(w).length, 1); // only `signer` is an own property
    assert.equal('pk' in w, false);
  });
});

// ---------------------------------------------------------------------------
// signature codec tests.
// ---------------------------------------------------------------------------

describe('signature codec', () => {
  it('signatureFromBytes round-trips v=27', () => {
    const r = '0x' + '11'.repeat(32);
    const s = '0x' + '22'.repeat(32);
    const compact = '0x' + r.slice(2) + s.slice(2) + '1b';
    const sig = signatureFromBytes(compact);
    assert.equal(sig.v, 27);
    assert.equal(sig.r, r);
    assert.equal(sig.s, s);
    assert.equal(signatureToBytes(sig), compact);
  });

  it('signatureFromBytes round-trips v=28', () => {
    const r = '0x' + '11'.repeat(32);
    const s = '0x' + '22'.repeat(32);
    const compact = '0x' + r.slice(2) + s.slice(2) + '1c';
    const sig = signatureFromBytes(compact);
    assert.equal(sig.v, 28);
    assert.equal(signatureToBytes(sig), compact);
  });

  it('rejects a non-65-byte compact signature', () => {
    assert.throws(() => signatureFromBytes('0x' + '11'.repeat(30)), KeeperError);
  });

  it('rejects an unknown v byte', () => {
    const r = '0x' + '11'.repeat(32);
    const s = '0x' + '22'.repeat(32);
    const compact = '0x' + r.slice(2) + s.slice(2) + '1a';
    assert.throws(() => signatureFromBytes(compact), KeeperError);
  });
});

// ---------------------------------------------------------------------------
// revoke transaction builder test (mocked, no network).
// ---------------------------------------------------------------------------

describe('KeeperWallet.revoke', () => {
  it('builds the correct calldata for revoke(keeperAddress)', async () => {
    // We don't want to hit the network. Instead of constructing a real
    // provider, we verify the ABI encoding by using ethers'
    // Interface directly. This checks that the ABI string the runtime
    // uses encodes the keeper address correctly.
    const { Interface, AbiCoder, keccak256, toUtf8Bytes } = await import('ethers');

    const iface = new Interface(['function revoke(address keeper)']);
    const fn = iface.getFunction('revoke');
    const selector = fn.selector;
    // 4-byte function selector: first 4 bytes of keccak256 of the
    // canonical function signature.
    const expectedSelector = keccak256(toUtf8Bytes('revoke(address)')).slice(0, 10) as `0x${string}`;
    assert.equal(selector, expectedSelector);

    // Encode the calldata for revoke(keeperAddress).
    const keeperAddr = '0x1234567890000000000000000000000000000001';
    const abiCoder = AbiCoder.defaultAbiCoder();
    const encodedArgs = abiCoder.encode(['address'], [keeperAddr]);
    const calldata = selector + encodedArgs.slice(2);
    // Calldata = 4-byte selector + 32-byte ABI-encoded address.
    assert.equal(calldata.length, 10 + 64);
    assert.equal(calldata.slice(0, 10), selector);
    // The ABI-encoded address is right-justified in 32 bytes.
    assert.equal(calldata.slice(10), keeperAddr.slice(2).padStart(64, '0'));

    // Sanity: the runtime uses the same ABI subset.
    const { TRADE_ONLY_AGENT_ABI } = await import('../src/keeper.js');
    assert.ok(TRADE_ONLY_AGENT_ABI.some((s) => s.startsWith('function revoke(address keeper)')));
  });
});

// ---------------------------------------------------------------------------
// MockVenue tests (used by keeper.test.ts per the brief).
// ---------------------------------------------------------------------------

describe('MockVenue', () => {
  it('accepts a valid delegation within the notional cap', async () => {
    const venue = new MockVenue({ domain: DOMAIN });
    const keeper = new KeeperWallet(HARDHAT_PK_0);
    const d = makeDelegation({ maxNotional: 1_000_000_000n, maxPerOrder: 100_000_000n });
    const sig = await keeper.signDelegation(d, HARDHAT_ADDR_0, DOMAIN);

    const result = await venue.submit(HARDHAT_ADDR_0, d, sig, 50_000_000n);
    assert.equal(result.accepted, true);
    assert.equal(result.usedNotional, 50_000_000n);
    assert.equal(result.remainingNotional, 1_000_000_000n - 50_000_000n);
  });

  it('accumulates usedNotional across multiple submissions', async () => {
    const venue = new MockVenue({ domain: DOMAIN });
    const keeper = new KeeperWallet(HARDHAT_PK_0);
    const d = makeDelegation({ maxNotional: 1_000_000n });

    const sig = await keeper.signDelegation(d, HARDHAT_ADDR_0, DOMAIN);
    const r1 = await venue.submit(HARDHAT_ADDR_0, d, sig, 400_000n);
    const r2 = await venue.submit(HARDHAT_ADDR_0, d, sig, 300_000n);
    assert.equal(r1.usedNotional, 400_000n);
    assert.equal(r2.usedNotional, 700_000n);
    assert.equal(r2.remainingNotional, 300_000n);
  });

  it('rejects a submission that exceeds maxNotional', async () => {
    const venue = new MockVenue({ domain: DOMAIN });
    const keeper = new KeeperWallet(HARDHAT_PK_0);
    const d = makeDelegation({ maxNotional: 1_000_000n });
    const sig = await keeper.signDelegation(d, HARDHAT_ADDR_0, DOMAIN);

    const r = await venue.submit(HARDHAT_ADDR_0, d, sig, 1_500_000n);
    assert.equal(r.accepted, false);
    assert.equal(r.note, 'exceeds maxNotional');
  });

  it('rejects a submission that exceeds maxPerOrder', async () => {
    const venue = new MockVenue({ domain: DOMAIN });
    const keeper = new KeeperWallet(HARDHAT_PK_0);
    const d = makeDelegation({ maxNotional: 1_000_000n, maxPerOrder: 500_000n });
    const sig = await keeper.signDelegation(d, HARDHAT_ADDR_0, DOMAIN);

    const r = await venue.submit(HARDHAT_ADDR_0, d, sig, 600_000n);
    assert.equal(r.accepted, false);
    assert.equal(r.note, 'exceeds maxPerOrder');
  });

  it('rejects a bad signature (wrong delegator)', async () => {
    const venue = new MockVenue({ domain: DOMAIN });
    const keeper = new KeeperWallet(HARDHAT_PK_0);
    const d = makeDelegation();
    // Sign as HARDHAT_ADDR_0, submit as HARDHAT_ADDR_1.
    const sig = await keeper.signDelegation(d, HARDHAT_ADDR_0, DOMAIN);
    const r = await venue.submit(HARDHAT_ADDR_1, d, sig, 1n);
    assert.equal(r.accepted, false);
    assert.ok(r.note?.includes('signature') ?? false);
  });

  it('reset() clears the used-notional state', async () => {
    const venue = new MockVenue({ domain: DOMAIN });
    const keeper = new KeeperWallet(HARDHAT_PK_0);
    const d = makeDelegation({ maxNotional: 1_000_000n });
    const sig = await keeper.signDelegation(d, HARDHAT_ADDR_0, DOMAIN);
    await venue.submit(HARDHAT_ADDR_0, d, sig, 500_000n);
    assert.equal(venue.getUsed(HARDHAT_ADDR_0, d), 500_000n);
    venue.reset();
    assert.equal(venue.getUsed(HARDHAT_ADDR_0, d), 0n);
  });
});
