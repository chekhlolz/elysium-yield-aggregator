/**
 * TS mirrors of the Solidity structs in `solidity/src/interfaces/ITradeOnlyAgent.sol`.
 *
 * Field names and ordering are deliberately identical to the Solidity source.
 * If you change anything here, re-check the digest in `src/signing.ts` and
 * the digest in `solidity/src/delegation/TradeOnlyAgent.sol`.
 *
 * Numeric types are `bigint` throughout. Solidity uint256 / uint64 don't fit
 * in JS numbers, and mixing `number` and `bigint` in a hot path is a real
 * footgun.
 */

/** Bytes32, as a hex string (0x-prefixed, 66 chars). */
export type Bytes32 = `0x${string}`;

/** Ethereum address, checksummed or lowercase hex string. */
export type Address = `0x${string}`;

/**
 * Mirror of `ITradeOnlyAgent.Delegation`.
 *
 * ```solidity
 * struct Delegation {
 *     address keeper;
 *     uint256[] assetIds;    // empty array = all assets
 *     uint256 maxNotional;   // USD per venue (6 decimals)
 *     uint256 maxPerOrder;   // USD per single order (6 decimals)
 *     uint64  expiresAt;     // 0 = never expires
 *     uint64  nonce;         // user-chosen ordering / de-dup
 *     bytes32  salt;         // user-chosen uniqueness
 * }
 * ```
 */
export interface Delegation {
  /** The keeper address that is being granted trade rights. */
  keeper: Address;
  /** Allowlist of asset IDs. Empty array = all assets permitted. */
  assetIds: bigint[];
  /** Per-venue notional cap, in USD 6-decimal units (1_000_000 = 1 USD). */
  maxNotional: bigint;
  /** Per-order notional cap, in USD 6-decimal units. */
  maxPerOrder: bigint;
  /** Unix seconds. `0` is the never-expires sentinel. */
  expiresAt: bigint;
  /** Nonce chosen by the delegator for ordering / de-dup. */
  nonce: bigint;
  /** Salt chosen by the delegator for uniqueness. */
  salt: Bytes32;
}

/**
 * Mirror of `ITradeOnlyAgent.Signature`.
 *
 * The contract's `_recover` requires `v == 27 || v == 28`. Ethers v6's
 * `signTypedData` returns 27/28 already; we enforce the same invariant
 * defensively at the boundary.
 */
export interface Signature {
  v: 27 | 28;
  r: Bytes32;
  s: Bytes32;
}

/**
 * EIP-712 typed-data fields for the `Delegation` type.
 *
 * Kept here next to `signing.ts` so a future reader can find the whole
 * type declaration in one file. The `types` array is the argument to
 * `TypedDataEncoder.hashTypedData` and must match the Solidity struct.
 */
export const DELEGATION_TYPE_NAME = 'Delegation' as const;

export const DELEGATION_FIELDS: readonly Readonly<{
  name: string;
  type: string;
}>[] = [
  { name: 'keeper', type: 'address' },
  { name: 'assetIds', type: 'uint256[]' },
  { name: 'maxNotional', type: 'uint256' },
  { name: 'maxPerOrder', type: 'uint256' },
  { name: 'expiresAt', type: 'uint64' },
  { name: 'nonce', type: 'uint64' },
  { name: 'salt', type: 'bytes32' },
] as const;

/**
 * EIP-712 domain fields.
 *
 * The domain name and version are literals from
 * `solidity/src/delegation/TradeOnlyAgent.sol:150-152` and are
 * bit-for-bit replicated here. Changing them breaks signatures.
 */
export const EIP712_DOMAIN_NAME = 'TradeOnlyAgent v1' as const;
export const EIP712_DOMAIN_VERSION = '1' as const;

/** Shape consumed by `TypedDataEncoder.hashTypedData` / `signTypedData`. */
export interface Eip712TypedData {
  types: {
    Delegation: Readonly<{ name: string; type: string }>[];
  };
  primaryType: 'Delegation';
  domain: Eip712Domain;
  message: Delegation;
}

export interface Eip712Domain {
  name: string;
  version: string;
  chainId: bigint | number;
  verifyingContract: string;
}

/** A venue is a counterparty that accepts (delegation, signature, notional).
 *
 * In Phase 1 (this package) `address` is optional because we only wire
 * up a mock venue. Phase 2 adds real venue adapters and makes
 * `address` required on those.
 */
export interface VenueConfig {
  /** Stable id used for config and logging. */
  id: string;
  /** On-chain venue address. Optional in Phase 1. */
  address?: Address;
  /** Adapter name. `mock` = offline; `elysium` = on-chain (Phase 2). */
  adapter?: 'mock' | 'elysium';
}

/** Runtime config loaded from `.env`. See `src/config.ts` for parsing. */
export interface KeeperConfig {
  chainId: number;
  rpcUrl: string;
  /** Keeper private key. NEVER log this. See SECURITY.md. */
  keeperPk: string;
  delegatorAddress: Address;
  /** Deployed `TradeOnlyAgent` address. EIP-712 verifyingContract. */
  agentAddress: Address;
  /** Optional `YieldAggregator` address for venue adapters. */
  aggregatorAddress?: Address;
  venues: VenueConfig[];
  watchIntervalMs: number;
  /** Client-side rate limit. See SECURITY.md. */
  maxTxsPerMinute: number;
}

/** Small helper so callers can build a zero salt deterministically. */
export const ZERO_SALT: Bytes32 = '0x0000000000000000000000000000000000000000000000000000000000000000';
