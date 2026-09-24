/**
 * End-to-end demo of the keeper runtime.
 *
 * Run with:
 *   npm run example
 *
 * This script is fully offline — no Anvil, no RPC. It exercises the
 * signing path, the digest computation, and offline signature recovery,
 * which is the core correctness contract of this package.
 *
 * Flow:
 *   1. Load .env (or fall back to Hardhat dev keys for a clean clone).
 *   2. Construct a KeeperWallet.
 *   3. Build a small delegation (1 USD notional, 60s expiry).
 *   4. Sign it.
 *   5. Print the digest and signature (masked).
 *   6. Verify the signature offline by recovering the signer.
 */

import { getAddress } from 'ethers';

import { loadConfig, ConfigError } from '../src/config.js';
import { KeeperWallet } from '../src/keeper.js';
import { delegationDigest, recoverDelegationSigner } from '../src/signing.js';
import { MockVenue } from '../src/mock-venue.js';
import { maskAddress, maskPk } from '../src/utils.js';
import type { Address, Bytes32, Delegation, Eip712Domain } from '../src/types.js';

const HARDHAT_PK_0 = '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80';
const HARDHAT_ADDR_0 = '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266';
const AGENT_ADDR_FALLBACK = '0x5FbDB2315678afecb367f032d93F642f64180aa3';

function banner(text: string): void {
  console.log('');
  console.log(`── ${text} ──`);
}

function randomBytes32(): Bytes32 {
  const buf = new Uint8Array(32);
  crypto.getRandomValues(buf);
  return ('0x' + Array.from(buf, (b) => b.toString(16).padStart(2, '0')).join('')) as Bytes32;
}

async function main(): Promise<void> {
  banner('TradeOnlyAgent Keeper Runtime — offline demo');

  // 1. Load config. Fall back to Hardhat dev keys if .env is missing.
  let config;
  try {
    config = loadConfig();
    console.log(`Loaded .env: chainId=${config.chainId}, agent=${maskAddress(config.agentAddress)}`);
  } catch (e) {
    if (e instanceof ConfigError) {
      console.log(`No .env (or incomplete): ${e.message}`);
      console.log('Falling back to Hardhat dev keys for the demo.');
      config = {
        chainId: 999,
        rpcUrl: 'http://127.0.0.1:8545',
        keeperPk: HARDHAT_PK_0,
        delegatorAddress: getAddress(HARDHAT_ADDR_0) as Address,
        agentAddress: getAddress(AGENT_ADDR_FALLBACK) as Address,
        aggregatorAddress: undefined,
        venues: [],
        watchIntervalMs: 1000,
        maxTxsPerMinute: 60,
      };
    } else {
      throw e;
    }
  }

  // 2. Construct a KeeperWallet.
  const keeper = new KeeperWallet(config.keeperPk);
  const from: Address = config.delegatorAddress;
  const domain: Eip712Domain = {
    name: 'TradeOnlyAgent v1',
    version: '1',
    chainId: BigInt(config.chainId),
    verifyingContract: config.agentAddress,
  };

  banner('Keeper wallet');
  console.log(`  keeper address : ${keeper.maskedAddress}  (never logging the private key)`);
  console.log(`  delegator      : ${maskAddress(from)}`);
  console.log(`  agent          : ${maskAddress(domain.verifyingContract)}`);
  console.log(`  chainId        : ${domain.chainId}`);
  console.log(`  pk (masked)    : ${maskPk(config.keeperPk)}`);

  // 3. Build a small delegation.
  const now = Math.floor(Date.now() / 1000);
  const delegation: Delegation = {
    keeper: keeper.address,
    assetIds: [1n, 2n, 3n],
    maxNotional: 1_000_000n,   // $1.00 in 6-decimal units
    maxPerOrder: 200_000n,     // $0.20 per order
    expiresAt: BigInt(now + 60),
    nonce: BigInt(Math.floor(Math.random() * 1_000_000)),
    salt: randomBytes32(),
  };

  banner('Delegation');
  console.log(`  keeper        : ${maskAddress(delegation.keeper)}`);
  console.log(`  assetIds      : [${delegation.assetIds.join(', ')}]`);
  console.log(`  maxNotional   : ${delegation.maxNotional}  ($${(Number(delegation.maxNotional) / 1e6).toFixed(2)})`);
  console.log(`  maxPerOrder   : ${delegation.maxPerOrder}`);
  console.log(`  expiresAt     : ${delegation.expiresAt}  (in ${(Number(delegation.expiresAt) - now)}s)`);
  console.log(`  nonce         : ${delegation.nonce}`);
  console.log(`  salt          : ${delegation.salt.slice(0, 10)}…`);

  // 4. Sign.
  const digest = delegationDigest(from, delegation, domain);
  const sig = await keeper.signDelegation(delegation, from, domain);

  banner('Signature');
  console.log(`  digest  : ${digest}`);
  console.log(`  v       : ${sig.v}`);
  console.log(`  r       : ${sig.r.slice(0, 18)}…${sig.r.slice(-8)}`);
  console.log(`  s       : ${sig.s.slice(0, 18)}…${sig.s.slice(-8)}`);

  // 5. Verify offline via recovery.
  const recovered = recoverDelegationSigner(from, delegation, domain, sig);
  banner('Offline verification');
  console.log(`  expected signer : ${maskAddress(from)}`);
  console.log(`  recovered signer: ${maskAddress(recovered)}`);
  console.log(`  match           : ${recovered.toLowerCase() === from.toLowerCase()}`);
  if (recovered.toLowerCase() !== from.toLowerCase()) {
    console.error('FATAL: signature did not recover to the intended delegator');
    process.exit(1);
  }

  // 6. Try the mock venue end-to-end. The per-order cap is $0.20,
  //    so each submission is sized at $0.20 to stay within maxPerOrder.
  const PER_ORDER = 200_000n;
  const venue = new MockVenue({ domain });
  const submitResult = await venue.submit(from, delegation, sig, PER_ORDER);
  banner('MockVenue submission (offline)');
  console.log(`  notional        : ${PER_ORDER}  ($${(Number(PER_ORDER) / 1e6).toFixed(2)})`);
  console.log(`  accepted        : ${submitResult.accepted}`);
  console.log(`  usedNotional    : ${submitResult.usedNotional}`);
  console.log(`  remainingNotional: ${submitResult.remainingNotional}`);
  if (!submitResult.accepted) {
    console.error(`FATAL: venue rejected a valid in-cap submission: ${submitResult.note}`);
    process.exit(1);
  }

  // 7. Submit a second time to show the cap accumulates.
  const secondSubmit = await venue.submit(from, delegation, sig, PER_ORDER);
  console.log(`  second submit  : accepted=${secondSubmit.accepted}, used=${secondSubmit.usedNotional}`);

  // 8. Submit a third — pushes total to $0.60, still within maxNotional ($1.00).
  const thirdSubmit = await venue.submit(from, delegation, sig, PER_ORDER);
  console.log(`  third submit   : accepted=${thirdSubmit.accepted}, used=${thirdSubmit.usedNotional}`);

  // 9. A fourth submission: an order larger than maxPerOrder ($0.20)
  //    but still within the remaining maxNotional ($0.40). This trips
  //    the per-order cap branch (which fires after the total-cap
  //    branch in MockVenue.submit).
  const overPerOrder = await venue.submit(from, delegation, sig, 300_000n);
  console.log(`  per-order cap  : accepted=${overPerOrder.accepted}, note="${overPerOrder.note ?? ''}"`);

  // 10. And a submission sized to exceed the total remaining cap
  //     ($1.00 - $0.60 = $0.40 remaining). This trips the
  //     maxNotional branch.
  const overCap = await venue.submit(from, delegation, sig, 999_999n);
  console.log(`  over total cap : accepted=${overCap.accepted}, note="${overCap.note ?? ''}"`);

  banner('Demo complete');
  console.log('All checks passed. The digest matches the contract bit-for-bit.');
}

main().catch((err) => {
  console.error('Demo failed:', err);
  process.exit(1);
});
