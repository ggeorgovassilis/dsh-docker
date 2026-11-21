/**
 * Supervision of one DSH SDK child process (`dsh --profile sdk`).
 *
 * Responsibilities: spawn, newline-delimited JSON-RPC framing, the single
 * process-wide `initialize` handshake, pending-request correlation, stderr
 * draining, and restart behaviour.
 *
 * @module dsh-api-runtime/dsh
 */

import { execFile, spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { EventEmitter, once } from 'node:events';
import readline from 'node:readline';

import { logSafePreview } from './util.mjs';

const INTERNAL_ID_PREFIX = 'bridge-';

export class DshError extends Error {
  constructor(message, code = 'DSH_ERROR') {
    super(message);
    this.name = 'DshError';
    this.code = code;
  }
}

export class DshUnavailableError extends DshError {
  constructor(message = 'DSH runtime is unavailable') {
    super(message, 'DSH_UNAVAILABLE');
  }
}

export class DshTimeoutError extends DshError {
  constructor(message = 'DSH request timed out') {
    super(message, 'DSH_TIMEOUT');
  }
}

export class DuplicateIdError extends DshError {
  constructor(message = 'JSON-RPC id is already in flight') {
    super(message, 'DUPLICATE_ID');
  }
}

/** Correlation key that distinguishes `1` from `"1"`. */
export function idKey(id) {
  return `${typeof id}:${String(id)}`;
}

/** True for ids the bridge reserves for its own requests. */
export function isBridgeInternalId(id) {
  return typeof id === 'string' && id.startsWith(INTERNAL_ID_PREFIX);
}

function internalId(label) {
  return `${INTERNAL_ID_PREFIX}${label}-${randomUUID()}`;
}

function isObject(value) {
  return value !== null && typeof value === 'object';
}

export class DshRuntime extends EventEmitter {
  /**
   * @param {{config: object, logger: object, metrics: object}} options
   */
  constructor({ config, logger, metrics }) {
    super();
    this.config = config;
    this.logger = logger;
    this.metrics = metrics;

    /** @type {import('node:child_process').ChildProcess | null} */
    this.child = null;
    this.pending = new Map();
    this.ready = false;
    this.serverInfo = null;
    this.dshVersion = null;
    this.lastExit = null;
    this.shuttingDown = false;
    this.starting = false;
    this.restartTimer = null;
    this.restartTimes = [];
    this.consecutiveRestarts = 0;
  }

  /**
   * Spawn the child and perform the process-wide initialize handshake.
   * Rejects when the child cannot be spawned or initialization fails.
   */
  async start({ initial = true } = {}) {
    if (this.starting || (this.child && this.ready)) return;
    this.starting = true;
    try {
      if (this.dshVersion === null) this.dshVersion = await this.#detectVersion();
      this.#spawn();
      await this.#initialize();
      this.consecutiveRestarts = 0;
      this.metrics.dshUp.set(1);
      this.logger.info('dsh ready', {
        pid: this.child?.pid,
        dshVersion: this.dshVersion,
        provider: this.config.provider,
        model: this.config.model,
      });
    } catch (error) {
      this.ready = false;
      this.metrics.dshUp.set(0);
      // A failed first start must not leave a half-configured runtime behind,
      // and must not be retried behind the caller's back.
      if (initial) this.shuttingDown = true;
      if (this.child) this.child.kill('SIGKILL');
      throw error;
    } finally {
      this.starting = false;
    }
  }

  /** Stop the child, first asking DSH to shut down cleanly. */
  async stop() {
    this.shuttingDown = true;
    if (this.restartTimer) {
      clearTimeout(this.restartTimer);
      this.restartTimer = null;
    }
    const child = this.child;
    if (!child || child.exitCode !== null || child.signalCode !== null) {
      this.ready = false;
      this.metrics.dshUp.set(0);
      return;
    }

    // One deadline for the whole teardown so raising an individual phase can
    // never exceed the container's stop timeout.
    const deadline = Date.now() + this.config.dshStopBudgetMs;
    const remaining = () => Math.max(0, deadline - Date.now());
    const phaseTimeout = (cap) => Math.max(0, Math.min(cap, remaining()));

    try {
      await this.sendRequest(
        { jsonrpc: '2.0', id: internalId('shutdown'), method: 'shutdown' },
        { timeoutMs: phaseTimeout(this.config.dshShutdownTimeoutMs), allowBeforeReady: true },
      );
    } catch (error) {
      this.logger.warn('dsh shutdown request did not complete', error);
    }
    this.ready = false;
    this.metrics.dshUp.set(0);

    if (await this.#waitForExit(phaseTimeout(this.config.dshShutdownTimeoutMs))) return;

    this.logger.warn('sending SIGTERM to dsh');
    child.kill('SIGTERM');
    if (await this.#waitForExit(phaseTimeout(this.config.dshTermTimeoutMs))) return;

    this.logger.warn('sending SIGKILL to dsh');
    child.kill('SIGKILL');
    await this.#waitForExit(phaseTimeout(2_000));
  }

  /**
   * Forward one JSON-RPC request and resolve with DSH's complete response
   * object (which may carry `error` instead of `result`).
   *
   * @param {object} message
   * @param {{timeoutMs?: number, allowBeforeReady?: boolean}} [options]
   */
  async sendRequest(message, { timeoutMs = this.config.rpcTimeoutMs, allowBeforeReady = false } = {}) {
    if (!this.ready && !allowBeforeReady) throw new DshUnavailableError();
    const key = idKey(message.id);
    if (this.pending.has(key)) throw new DuplicateIdError();

    const promise = new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(key);
        reject(new DshTimeoutError(`JSON-RPC request ${String(message.id)} timed out after ${timeoutMs}ms`));
      }, timeoutMs);
      timer.unref?.();
      this.pending.set(key, { resolve, reject, timer });
    });

    this.#write(message).catch((error) => {
      const entry = this.pending.get(key);
      if (!entry) return;
      this.pending.delete(key);
      clearTimeout(entry.timer);
      entry.reject(error);
    });

    return promise;
  }

  /** Forward a JSON-RPC notification. Notifications never create pending entries. */
  async sendNotification(message) {
    if (!this.ready) throw new DshUnavailableError();
    await this.#write(message);
  }

  /** Forward a client answer to a server-to-client request. */
  async sendResponse(message) {
    if (!this.ready) throw new DshUnavailableError();
    await this.#write(message);
  }

  #spawn() {
    const { dshBin, dshArgs, dshCwd, dshHome, telemetryMode } = this.config;
    const isScript = /\.(?:mjs|cjs|js)$/i.test(dshBin);
    const command = isScript ? process.execPath : dshBin;
    const args = isScript ? [dshBin, ...dshArgs] : [...dshArgs];

    const env = {
      ...process.env,
      HOME: process.env.HOME || '/home/node',
      DSH_HOME: dshHome,
      DSH_TELEMETRY_MODE: telemetryMode,
      // The native addon loader materialises .node files under os.tmpdir() and
      // dlopen()s them. The container mounts /tmp noexec, so load the shipped
      // prebuilds in place instead.
      NARB_DISABLE_NATIVE_CACHE: '1',
      NO_COLOR: '1',
      TERM: 'dumb',
    };

    this.logger.info('spawning dsh', { command, args, cwd: dshCwd });

    const child = spawn(command, args, {
      cwd: dshCwd,
      env,
      stdio: ['pipe', 'pipe', 'pipe'],
      shell: false,
    });
    this.child = child;

    const lines = readline.createInterface({ input: child.stdout, crlfDelay: Infinity });
    lines.on('line', (line) => this.#onStdoutLine(line));

    const stderrLines = readline.createInterface({ input: child.stderr, crlfDelay: Infinity });
    stderrLines.on('line', (line) => this.logger.dshStderr(line));

    child.stdin.on('error', (error) => {
      this.logger.warn('dsh stdin error', error);
    });

    child.on('error', (error) => {
      this.logger.error('dsh spawn error', error);
      this.lastExit = {
        code: null,
        signal: null,
        at: new Date().toISOString(),
        error: error.message,
      };
      this.#handleExit(child);
    });

    child.on('exit', (code, signal) => {
      this.lastExit = { code, signal, at: new Date().toISOString(), error: null };
      this.#handleExit(child);
    });
  }

  #onStdoutLine(line) {
    if (line.trim() === '') return;

    let message;
    try {
      message = JSON.parse(line);
    } catch {
      this.logger.warn('ignoring malformed dsh stdout line', { preview: logSafePreview(line) });
      return;
    }

    if (!isObject(message)) {
      this.logger.warn('ignoring non-object dsh stdout line', { preview: logSafePreview(line) });
      return;
    }

    const hasId = Object.prototype.hasOwnProperty.call(message, 'id');
    const hasMethod = typeof message.method === 'string';

    if (hasMethod && !hasId) {
      this.emit('notification', message);
      return;
    }

    if (hasMethod && hasId) {
      this.emit('hostRequest', message);
      return;
    }

    if (hasId && (Object.prototype.hasOwnProperty.call(message, 'result')
      || Object.prototype.hasOwnProperty.call(message, 'error'))) {
      const key = idKey(message.id);
      const entry = this.pending.get(key);
      if (!entry) {
        this.logger.warn('discarding response for unknown request id', { rpcId: String(message.id) });
        return;
      }
      this.pending.delete(key);
      clearTimeout(entry.timer);
      entry.resolve(message);
      return;
    }

    this.logger.warn('ignoring unrecognised dsh stdout message', { preview: logSafePreview(line) });
  }

  #handleExit(child) {
    if (this.child !== child) return;
    this.child = null;
    const wasReady = this.ready;
    this.ready = false;
    this.metrics.dshUp.set(0);

    const error = new DshUnavailableError('DSH child exited');
    for (const [key, entry] of this.pending) {
      this.pending.delete(key);
      clearTimeout(entry.timer);
      entry.reject(error);
    }

    this.emit('exit', this.lastExit);

    if (this.shuttingDown) return;

    this.logger.warn('dsh exited', { ...this.lastExit, wasReady });
    this.#scheduleRestart();
  }

  #scheduleRestart() {
    const now = Date.now();
    this.restartTimes = this.restartTimes.filter((at) => now - at < this.config.restartWindowMs);
    this.restartTimes.push(now);

    if (this.restartTimes.length > this.config.restartMaxInWindow) {
      this.logger.error('dsh restart budget exhausted in the restart window', {
        restarts: this.restartTimes.length,
        windowMs: this.config.restartWindowMs,
      });
      this.emit('fatal', new DshError('DSH restart budget exhausted'));
      return;
    }

    this.consecutiveRestarts += 1;
    const delayMs = Math.min(1_000 * 2 ** (this.consecutiveRestarts - 1), 30_000);
    this.logger.warn('restarting dsh after backoff', { delayMs, attempt: this.consecutiveRestarts });
    this.metrics.dshRestarts.inc();

    this.restartTimer = setTimeout(() => {
      this.restartTimer = null;
      this.start({ initial: false }).catch((error) => {
        this.logger.error('dsh restart failed', error);
        if (this.child) {
          this.child.kill('SIGKILL');
        } else {
          this.#scheduleRestart();
        }
      });
    }, delayMs);
    this.restartTimer.unref?.();
  }

  async #initialize() {
    const params = {
      cwd: this.config.dshCwd,
      provider: this.config.provider,
      model: this.config.model,
      approvalRequests: this.config.enableApprovals,
      capabilities: { userQuestions: this.config.enableUserQuestions },
    };
    if (this.config.reasoningEffort !== undefined) params.reasoningEffort = this.config.reasoningEffort;
    if (this.config.maxTokens !== undefined) params.maxTokens = this.config.maxTokens;

    const response = await this.sendRequest(
      { jsonrpc: '2.0', id: internalId('init'), method: 'initialize', params },
      { timeoutMs: this.config.initTimeoutMs, allowBeforeReady: true },
    ).catch((error) => {
      throw new DshError(`DSH initialize failed: ${error.message}`, 'DSH_INIT_FAILED');
    });

    if (response.error) {
      throw new DshError(
        `DSH initialize failed: ${JSON.stringify(response.error)}`,
        'DSH_INIT_FAILED',
      );
    }

    this.serverInfo = response.result?.serverInfo ?? null;
    this.ready = true;
  }

  async #write(message) {
    const child = this.child;
    if (!child || !child.stdin || child.stdin.destroyed) {
      throw new DshUnavailableError();
    }

    const payload = `${JSON.stringify(message)}\n`;
    if (child.stdin.write(payload)) return;

    const controller = new AbortController();
    try {
      await Promise.race([
        once(child.stdin, 'drain', { signal: controller.signal }),
        once(child, 'exit', { signal: controller.signal }),
      ]);
    } catch (error) {
      if (error?.name === 'AbortError') return;
      throw new DshUnavailableError(`DSH stdin closed: ${error.message}`);
    } finally {
      controller.abort();
    }

    if (this.child !== child) throw new DshUnavailableError();
  }

  #waitForExit(timeoutMs) {
    const child = this.child;
    if (!child || child.exitCode !== null || child.signalCode !== null) return Promise.resolve(true);
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        child.removeListener('exit', onExit);
        resolve(false);
      }, timeoutMs);
      timer.unref?.();
      function onExit() {
        clearTimeout(timer);
        resolve(true);
      }
      child.once('exit', onExit);
    });
  }

  async #detectVersion() {
    const { dshBin } = this.config;
    const isScript = /\.(?:mjs|cjs|js)$/i.test(dshBin);
    const command = isScript ? process.execPath : dshBin;
    const args = isScript ? [dshBin, '--version'] : ['--version'];

    try {
      const { stdout } = await new Promise((resolve, reject) => {
        execFile(command, args, { timeout: 15_000, env: process.env }, (error, stdout, stderr) => {
          if (error) reject(Object.assign(error, { stderr }));
          else resolve({ stdout, stderr });
        });
      });
      const version = stdout.trim().split(/\r?\n/).pop()?.trim();
      return version || null;
    } catch (error) {
      this.logger.debug('could not read dsh --version', error);
      return null;
    }
  }
}
