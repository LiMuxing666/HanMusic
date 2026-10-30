import { isIP } from 'node:net';
import { resolve } from 'node:path';

export const AUDD_URL = 'https://api.audd.io/';
export const MAX_AUDIO_BYTES = 8 * 1024 * 1024;

function integer(value, name, fallback, min, max) {
  if (value === undefined) return fallback;
  if (!/^(0|[1-9]\d*)$/.test(String(value))) throw new Error(`Invalid ${name}`);
  const number = Number(value);
  if (!Number.isSafeInteger(number) || number < min || number > max) {
    throw new Error(`Invalid ${name}`);
  }
  return number;
}

function boolean(value, name) {
  if (value === undefined || value === false || value === 'false') return false;
  if (value === true || value === 'true') return true;
  throw new Error(`Invalid ${name}`);
}

export function isLoopback(address) {
  return address === '::1' || address === '::ffff:127.0.0.1' ||
    (isIP(address) === 4 && address.startsWith('127.'));
}

export function normalizeConfig(input = {}) {
  const nodeEnv = input.nodeEnv ?? 'production';
  if (!['production', 'development', 'test'].includes(nodeEnv)) {
    throw new Error('Invalid NODE_ENV');
  }
  const token = input.token ?? '';
  if (typeof token !== 'string' || token.length > 512 ||
      /[\x00-\x20\x7f]/.test(token) ||
      (token && nodeEnv !== 'test' &&
        (/^(test|test[-_]?token|demo|example|changeme|change[-_]?me|your[-_].*|replace[-_].*)$/i.test(token) || token.length < 8))) {
    throw new Error('Invalid AUDD_API_TOKEN');
  }
  const host = input.host ?? '127.0.0.1';
  if (typeof host !== 'string' || !isIP(host)) throw new Error('Invalid HOST');
  const budgetFile = input.budgetFile ?? './data/budget.json';
  if (typeof budgetFile !== 'string' || !budgetFile.trim() || budgetFile.includes('\0')) {
    throw new Error('Invalid BUDGET_FILE');
  }
  const upstreamUrl = input.upstreamUrl ?? AUDD_URL;
  if (upstreamUrl !== AUDD_URL) {
    let parsed;
    try { parsed = new URL(upstreamUrl); } catch { throw new Error('Invalid upstream URL'); }
    const hostname = parsed.hostname.replace(/^\[|\]$/g, '');
    if (nodeEnv !== 'test' || parsed.protocol !== 'http:' || !isLoopback(hostname) ||
        parsed.username || parsed.password || parsed.search || parsed.hash) {
      throw new Error('Test upstream must be an explicit loopback HTTP URL');
    }
  }
  if (input.now !== undefined && input.now !== Date.now &&
      (nodeEnv !== 'test' || typeof input.now !== 'function')) {
    throw new Error('Clock override is test-only');
  }
  return Object.freeze({
    nodeEnv, token, host, upstreamUrl,
    port: integer(input.port, 'PORT', 8787, nodeEnv === 'test' ? 0 : 1, 65535),
    budgetFile: resolve(budgetFile),
    trustProxyLoopback: boolean(input.trustProxyLoopback, 'TRUST_PROXY_LOOPBACK'),
    ipLimit: integer(input.ipLimit, 'IP_LIMIT_HOUR', 10, 1, 1000),
    dailyLimit: integer(input.dailyLimit, 'DAILY_LIMIT', 100, 1, 100000),
    concurrency: integer(input.concurrency, 'MAX_CONCURRENT', 2, 1, 32),
    ipCacheSize: integer(input.ipCacheSize, 'IP_CACHE_SIZE', 4096, 1, 100000),
    bodyTimeoutMs: integer(input.bodyTimeoutMs, 'BODY_TIMEOUT_MS', 10000, 1, 10000),
    upstreamTimeoutMs: integer(input.upstreamTimeoutMs, 'UPSTREAM_TIMEOUT_MS', 25000, 1, 25000),
    now: input.now ?? Date.now,
  });
}

export function readConfigFromEnv(env = process.env) {
  // The upstream destination is deliberately not configurable through env.
  return normalizeConfig({
    nodeEnv: env.NODE_ENV,
    token: env.AUDD_API_TOKEN,
    host: env.HOST,
    port: env.PORT,
    budgetFile: env.BUDGET_FILE,
    trustProxyLoopback: env.TRUST_PROXY_LOOPBACK,
    ipLimit: env.IP_LIMIT_HOUR,
    dailyLimit: env.DAILY_LIMIT,
    concurrency: env.MAX_CONCURRENT,
    ipCacheSize: env.IP_CACHE_SIZE,
    bodyTimeoutMs: env.BODY_TIMEOUT_MS,
    upstreamTimeoutMs: env.UPSTREAM_TIMEOUT_MS,
  });
}
