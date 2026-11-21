/**
 * Environment configuration for the DSH HTTP bridge.
 *
 * The bridge never reads `.env` itself: `scripts/run.sh` parses `.env` on the
 * host and passes a filtered environment file to the container. This module
 * validates exactly that runtime environment.
 *
 * @module dsh-api-runtime/config
 */

import path from 'node:path';
import { fileURLToPath } from 'node:url';

const APP_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

export class ConfigError extends Error {
  constructor(message) {
    super(message);
    this.name = 'ConfigError';
  }
}

const LOG_LEVELS = new Set(['debug', 'info', 'warn', 'error']);

function readString(env, name, fallback = '') {
  const raw = env[name];
  if (raw === undefined) return fallback;
  return raw.trim();
}

function readInt(env, name, fallback, { min = 1, max = Number.MAX_SAFE_INTEGER } = {}) {
  const raw = readString(env, name);
  if (raw === '') return fallback;
  if (!/^[0-9]+$/.test(raw)) {
    throw new ConfigError(`${name} must be a positive integer, got ${JSON.stringify(raw)}`);
  }
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < min || value > max) {
    throw new ConfigError(`${name} must be between ${min} and ${max}, got ${value}`);
  }
  return value;
}

function readBool(env, name, fallback = false) {
  const raw = readString(env, name).toLowerCase();
  if (raw === '') return fallback;
  if (['1', 'true', 'yes', 'on'].includes(raw)) return true;
  if (['0', 'false', 'no', 'off'].includes(raw)) return false;
  throw new ConfigError(`${name} must be 0 or 1, got ${JSON.stringify(raw)}`);
}

/**
 * Load and validate bridge configuration from an environment object.
 *
 * @param {NodeJS.ProcessEnv} [env] environment to read (defaults to `process.env`)
 * @returns {Readonly<object>} validated configuration
 */
export function loadConfig(env = process.env) {
  const httpBind = readString(env, 'HTTP_BIND', '127.0.0.1');
  if (httpBind === '') throw new ConfigError('HTTP_BIND must not be empty');

  // Port 0 asks the OS for an ephemeral port; tests use it.
  const httpPort = readInt(env, 'HTTP_PORT', 3080, { min: 0, max: 65535 });

  const dshBin = readString(env, 'DSH_BIN', path.join(APP_ROOT, 'node_modules', '.bin', 'dsh'));
  if (dshBin === '') throw new ConfigError('DSH_BIN must not be empty');

  const dshCwd = readString(env, 'DSH_CWD', '/workspace');
  if (dshCwd === '') throw new ConfigError('DSH_CWD must not be empty');
  if (!path.isAbsolute(dshCwd)) {
    throw new ConfigError(`DSH_CWD must be an absolute path, got ${JSON.stringify(dshCwd)}`);
  }

  const dshHome = readString(env, 'DSH_HOME', '/home/node/.dsh');
  if (dshHome === '') throw new ConfigError('DSH_HOME must not be empty');

  const provider = readString(env, 'DSH_PROVIDER', 'deepseek-official');
  if (provider === '') throw new ConfigError('DSH_PROVIDER must not be empty');

  const model = readString(env, 'DSH_MODEL', 'deepseek-v4-flash');
  if (model === '') throw new ConfigError('DSH_MODEL must not be empty');

  const reasoningEffort = readString(env, 'DSH_REASONING_EFFORT');
  const maxTokensRaw = readString(env, 'DSH_MAX_TOKENS');
  const maxTokens = maxTokensRaw === '' ? undefined : readInt(env, 'DSH_MAX_TOKENS', undefined);

  const logLevel = readString(env, 'LOG_LEVEL', 'info').toLowerCase();
  if (!LOG_LEVELS.has(logLevel)) {
    throw new ConfigError(`LOG_LEVEL must be one of ${[...LOG_LEVELS].join(', ')}, got ${JSON.stringify(logLevel)}`);
  }

  const telemetryMode = readString(env, 'DSH_TELEMETRY_MODE', 'DISABLED') || 'DISABLED';

  return Object.freeze({
    httpBind,
    httpPort,
    dshBin,
    dshArgs: Object.freeze(['--profile', 'sdk']),
    dshCwd,
    dshHome,
    provider,
    model,
    reasoningEffort: reasoningEffort === '' ? undefined : reasoningEffort,
    maxTokens,
    initTimeoutMs: readInt(env, 'INIT_TIMEOUT_MS', 60_000, { min: 1_000 }),
    rpcTimeoutMs: readInt(env, 'RPC_TIMEOUT_MS', 300_000, { min: 1_000 }),
    maxInflight: readInt(env, 'MAX_INFLIGHT', 16, { min: 1, max: 100_000 }),
    maxBodyBytes: readInt(env, 'MAX_BODY_BYTES', 8_388_608, { min: 1024 }),
    enableApprovals: readBool(env, 'ENABLE_APPROVALS', false),
    enableUserQuestions: readBool(env, 'ENABLE_USER_QUESTIONS', false),
    allowUnauthenticatedExposure: readBool(env, 'ALLOW_UNAUTHENTICATED_EXPOSURE', false),
    logLevel,
    telemetryMode,
    // Bounded SSE fan-out: a client that falls further behind is disconnected
    // rather than growing bridge memory without limit.
    sseMaxBufferedBytes: 4 * 1024 * 1024,
    sseKeepaliveMs: 15_000,
    dshShutdownTimeoutMs: 10_000,
    dshTermTimeoutMs: 5_000,
    // Hard upper bound for stop(); keep well below run.sh's --stop-timeout.
    dshStopBudgetMs: readInt(env, 'STOP_BUDGET_MS', 25_000, { min: 100 }),
    restartWindowMs: 5 * 60_000,
    restartMaxInWindow: 10,
  });
}

/**
 * The loopback check used by `scripts/lib.sh` and documented in the README.
 *
 * @param {string} address
 * @returns {boolean}
 */
export function isLoopback(address) {
  if (address === 'localhost') return true;
  if (address === '::1' || address === '[::1]') return true;
  const match = /^127\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(address);
  return match !== null && match.slice(1).every((part) => Number(part) <= 255);
}
