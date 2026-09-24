/**
 * Small utility helpers used across the runtime.
 *
 * Security invariants live here so they are impossible to miss:
 *   - {@link maskAddress} is the ONLY way an address should reach a log.
 *   - {@link maskPk} is defensive in case someone accidentally logs `pk`.
 */

import { getAddress, isHexString } from 'ethers';

/**
 * Mask an Ethereum address for log output.
 *
 *   `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266` → `0xf39F…2266`
 *
 * Never log a full address at info level. This is not a security
 * boundary in itself (addresses are not secret), but it keeps logs
 * scannable and prevents paste-into-console accidents.
 */
export function maskAddress(address: string): string {
  try {
    getAddress(address); // validates + checksums
  } catch {
    return '[not-address]';
  }
  return `${address.slice(0, 6)}…${address.slice(-4)}`;
}

/**
 * Mask a private key. Defensive only: `KeeperWallet` never puts `pk`
 * in a log. This is here so that if a future author accidentally logs
 * a pk, they can run it through this and get back something useless.
 */
export function maskPk(pk: string): string {
  const hex = pk.startsWith('0x') || pk.startsWith('0X') ? pk.slice(2) : pk;
  if (hex.length < 8) return '[short-pk]';
  return `${hex.slice(0, 4)}…${hex.slice(-4)} (len=${hex.length})`;
}

/**
 * Redact anything that looks like a hex secret in an error message or
 * log line. This is a safety net, not a substitute for not logging
 * the secret in the first place.
 */
export function redactSecrets(text: string): string {
  return text.replace(/(?:0x)?[0-9a-fA-F]{64}/g, '[redacted]');
}

/** Validate a private key shape. Never logs the key. */
export function isValidPrivateKey(pk: string): boolean {
  return isHexString(pk) && pk.length === 66;
}

/** Validate a 32-byte hex value. */
export function isValidBytes32(hex: string): boolean {
  return isHexString(hex) && hex.length === 64;
}
