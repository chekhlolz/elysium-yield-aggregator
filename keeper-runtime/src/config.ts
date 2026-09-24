/**
 * Runtime configuration.
 *
 * Loads from `.env` (if present) and from `process.env`. Values in
 * `process.env` take precedence — this is the standard 12-factor
 * pattern and lets operators override without touching the file.
 *
 * The keeper private key is loaded once here and never written to
 * disk or logged. See SECURITY.md.
 */

import { readFileSync, existsSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

import { getAddress } from 'ethers';

import { isValidPrivateKey } from './utils.js';
import type { Address, KeeperConfig, VenueConfig } from './types.js';

/** Thrown when a required env var is missing or malformed. */
export class ConfigError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'ConfigError';
  }
}

/** Minimal `.env` parser — no dependency, no shell injection.
 *
 * Supported syntax:
 *   KEY=value
 *   KEY = value        (surrounding whitespace trimmed)
 *   # comment
 *   KEY="quoted"       (quotes stripped)
 *   KEY='quoted'       (quotes stripped)
 *   export KEY=value   (export prefix ignored)
 *
 * Not supported (deliberately):
 *   - Inline comments (`KEY=value # comment` keeps the comment).
 *   - Variable interpolation (`$FOO`).
 *   - Multi-line values.
 */
export function parseEnv(text: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const rawLine of text.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (line.length === 0 || line.startsWith('#')) continue;
    const eq = line.indexOf('=');
    if (eq === -1) continue;
    const key = stripExport(line.slice(0, eq)).trim();
    if (key.length === 0) continue;
    const value = stripQuotes(line.slice(eq + 1).trim());
    out[key] = value;
  }
  return out;
}

function stripExport(s: string): string {
  return s.startsWith('export ') ? s.slice('export '.length) : s;
}

function stripQuotes(s: string): string {
  if (s.length >= 2) {
    const first = s[0];
    const last = s[s.length - 1];
    if ((first === '"' && last === '"') || (first === "'" && last === "'")) {
      return s.slice(1, -1);
    }
  }
  return s;
}

/** Locate `.env` starting from the current file and walking upward.
 *
 * We avoid `process.cwd()` because tests and editors often run with a
 * different cwd than the package root.
 */
export function findEnvPath(): string | undefined {
  const here = dirname(fileURLToPath(import.meta.url));
  let dir = here;
  for (let i = 0; i < 6; i++) {
    const candidate = resolve(dir, '.env');
    if (existsSync(candidate)) return candidate;
    const parent = dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  return undefined;
}

/** Load `.env` (if any) into an env-like map, preserving `process.env`. */
export function loadEnv(): Record<string, string | undefined> {
  const out: Record<string, string | undefined> = { ...process.env };
  const envPath = findEnvPath();
  if (envPath) {
    const text = readFileSync(envPath, 'utf8');
    for (const [k, v] of Object.entries(parseEnv(text))) {
      // Never overwrite an existing process.env value.
      if (out[k] === undefined) out[k] = v;
    }
  }
  return out;
}

function requireString(
  env: Record<string, string | undefined>,
  key: string,
): string {
  const v = env[key];
  if (v === undefined || v.trim() === '') {
    throw new ConfigError(`Missing required env var: ${key}`);
  }
  return v.trim();
}

function requireAddress(
  env: Record<string, string | undefined>,
  key: string,
): Address {
  const raw = requireString(env, key);
  try {
    return getAddress(raw) as Address;
  } catch {
    throw new ConfigError(`Env var ${key} is not a valid Ethereum address`);
  }
}

function parsePositiveInt(
  env: Record<string, string | undefined>,
  key: string,
  fallback: number,
): number {
  const raw = env[key];
  if (raw === undefined || raw.trim() === '') return fallback;
  const n = Number.parseInt(raw, 10);
  if (!Number.isFinite(n) || n <= 0) {
    throw new ConfigError(`Env var ${key} must be a positive integer, got "${raw}"`);
  }
  return n;
}

function parseVenues(raw: string | undefined): VenueConfig[] {
  if (!raw || raw.trim() === '') return [];
  // Phase 1: only the id is parsed. Addresses come from the venue
  // adapter in Phase 2 and are not yet wired into `.env`.
  return raw
    .split(',')
    .map((s) => s.trim())
    .filter((s) => s.length > 0)
    .map((id) => ({ id, adapter: 'mock' as const }));
}

/**
 * Load and validate runtime config.
 *
 * This is the single place that reads `KEEPER_PK`. Callers get the
 * value back but should not log it; use `KeeperWallet.address` for
 * logging.
 */
export function loadConfig(env: Record<string, string | undefined> = loadEnv()): KeeperConfig {
  const chainIdRaw = requireString(env, 'CHAIN_ID');
  const chainId = Number.parseInt(chainIdRaw, 10);
  if (!Number.isFinite(chainId) || chainId <= 0) {
    throw new ConfigError(`CHAIN_ID must be a positive integer, got "${chainIdRaw}"`);
  }

  const rpcUrl = requireString(env, 'RPC_URL');

  const keeperPk = requireString(env, 'KEEPER_PK');
  if (!isValidPrivateKey(keeperPk)) {
    // Deliberately do NOT include the pk in the error message.
    throw new ConfigError('KEEPER_PK must be a 32-byte hex string (0x-prefixed, 66 chars)');
  }

  const delegatorAddress = requireAddress(env, 'DELEGATOR_ADDRESS');
  const agentAddress = requireAddress(env, 'AGENT_ADDRESS');

  const aggregatorRaw = env['AGGREGATOR_ADDRESS'];
  let aggregatorAddress: Address | undefined;
  if (aggregatorRaw && aggregatorRaw.trim() !== '') {
    try {
      aggregatorAddress = getAddress(aggregatorRaw.trim()) as Address;
    } catch {
      throw new ConfigError('AGGREGATOR_ADDRESS is not a valid Ethereum address');
    }
  }

  return {
    chainId,
    rpcUrl,
    keeperPk,
    delegatorAddress,
    agentAddress,
    aggregatorAddress,
    venues: parseVenues(env['VENUES']),
    watchIntervalMs: parsePositiveInt(env, 'WATCH_INTERVAL_MS', 1000),
    maxTxsPerMinute: parsePositiveInt(env, 'MAX_TXS_PER_MINUTE', 60),
  };
}
