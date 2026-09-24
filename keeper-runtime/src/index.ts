/**
 * Public entry point for the keeper runtime.
 *
 * Everything production consumers need is re-exported here so callers
 * can `import { KeeperWallet } from 'keeper-runtime'` and not have to
 * reach into `src/` for internals.
 */

export { ConfigError, loadConfig, loadEnv, parseEnv, findEnvPath } from './config.js';
export {
  DELEGATION_TYPE_STRING,
  DELEGATION_TYPEHASH,
  DOMAIN_TYPE_STRING,
  domainSeparator,
  delegationStructHash,
  delegationDigest,
  recoverDelegationSigner,
  recoverFromDigest,
  encodeUint256,
  encodeUint64,
  encodeAddress,
  encodeBytes32,
  encodeUint256Array,
  type DigestSigner,
} from './signing.js';
export {
  KeeperWallet,
  KeeperError,
  TRADE_ONLY_AGENT_ABI,
  signatureFromBytes,
  signatureToBytes,
} from './keeper.js';
export { MockVenue, type VenueSubmitResult } from './mock-venue.js';
export {
  MockElysiumCoreWriter,
  type IVenueAdapter,
  type MockVenueState,
} from './venue-adapter.js';
export {
  KeeperDaemon,
  DEFAULT_DAEMON_CONFIG,
  type KeeperDaemonConfig,
} from './daemon.js';
export {
  EIP712_DOMAIN_NAME,
  EIP712_DOMAIN_VERSION,
  DELEGATION_FIELDS,
  DELEGATION_TYPE_NAME,
  ZERO_SALT,
  type Address,
  type Bytes32,
  type Delegation,
  type Eip712Domain,
  type Eip712TypedData,
  type KeeperConfig,
  type Signature,
  type VenueConfig,
} from './types.js';
export {
  type DaemonConfig,
  type DaemonEvent,
  type DaemonEventType,
  type KeeperDaemonStats,
  type PendingIntent,
  type Side,
  type SubmitResult,
  type SubmittedTrade,
  type Usd6,
} from './daemon-types.js';
export { maskAddress, maskPk, redactSecrets, isValidPrivateKey, isValidBytes32 } from './utils.js';
