/**
 * HTTP listener for the DSH SDK runtime: JSON-RPC over POST, notifications
 * over SSE, status, health, readiness, and Prometheus metrics.
 *
 * @module dsh-api-runtime/server
 */

import http from 'node:http';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';

import { ConfigError, isLoopback, loadConfig } from './config.mjs';
import {
  DshRuntime,
  DshTimeoutError,
  DshUnavailableError,
  DuplicateIdError,
  idKey,
  isBridgeInternalId,
} from './dsh.mjs';
import { BridgeMetrics, createLogger, notificationMethodLabel, rpcMethodLabel } from './telemetry.mjs';

const ROUTES = new Set(['/v1/rpc', '/v1/events', '/v1/status', '/healthz', '/readyz', '/metrics']);

const JSON_RPC_ERRORS = {
  parse: { code: -32700, message: 'Parse error' },
  invalidRequest: { code: -32600, message: 'Invalid Request' },
  internal: { code: -32603, message: 'Internal error' },
  unavailable: { code: -32000, message: 'DSH unavailable' },
  timeout: { code: -32001, message: 'DSH timeout' },
  busy: { code: -32002, message: 'Busy' },
};

class BodyTooLargeError extends Error {}

/** Validation failure carrying the JSON-RPC error to return. */
export class RequestValidationError extends Error {
  constructor(code, message, status = 400) {
    super(message);
    this.name = 'RequestValidationError';
    this.code = code;
    this.status = status;
  }
}

function isPlainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function assertValidId(id) {
  const ok = (typeof id === 'string' && id.length > 0)
    || (typeof id === 'number' && Number.isFinite(id));
  if (!ok) {
    throw new RequestValidationError(
      JSON_RPC_ERRORS.invalidRequest.code,
      'JSON-RPC id must be a non-empty string or a finite number',
    );
  }
}

/**
 * Classify one decoded JSON-RPC body.
 *
 * @param {unknown} body
 * @returns {{kind: 'request'|'notification'|'response', message: object}}
 */
export function classifyMessage(body) {
  if (Array.isArray(body)) {
    throw new RequestValidationError(JSON_RPC_ERRORS.invalidRequest.code, 'Batch requests are not supported');
  }
  if (!isPlainObject(body)) {
    throw new RequestValidationError(JSON_RPC_ERRORS.invalidRequest.code, 'Body must be a JSON object');
  }
  if (body.jsonrpc !== '2.0') {
    throw new RequestValidationError(JSON_RPC_ERRORS.invalidRequest.code, 'jsonrpc must be "2.0"');
  }

  const hasId = Object.prototype.hasOwnProperty.call(body, 'id');
  const hasResult = Object.prototype.hasOwnProperty.call(body, 'result');
  const hasError = Object.prototype.hasOwnProperty.call(body, 'error');

  if (Object.prototype.hasOwnProperty.call(body, 'method')) {
    if (typeof body.method !== 'string' || body.method.trim() === '') {
      throw new RequestValidationError(JSON_RPC_ERRORS.invalidRequest.code, 'method must be a non-empty string');
    }
    if (hasResult || hasError) {
      throw new RequestValidationError(JSON_RPC_ERRORS.invalidRequest.code, 'A request cannot carry result or error');
    }
    if (!hasId) return { kind: 'notification', message: body };
    assertValidId(body.id);
    if (isBridgeInternalId(body.id)) {
      throw new RequestValidationError(
        JSON_RPC_ERRORS.invalidRequest.code,
        'JSON-RPC ids starting with "bridge-" are reserved for the bridge',
      );
    }
    return { kind: 'request', message: body };
  }

  if (!hasId || hasResult === hasError) {
    throw new RequestValidationError(
      JSON_RPC_ERRORS.invalidRequest.code,
      'A response requires an id and exactly one of result or error',
    );
  }
  assertValidId(body.id);
  if (hasError && (!isPlainObject(body.error) || typeof body.error.code !== 'number')) {
    throw new RequestValidationError(JSON_RPC_ERRORS.invalidRequest.code, 'error must be an object with a numeric code');
  }
  return { kind: 'response', message: body };
}

function errorBody(id, code, message, data) {
  const error = { code, message };
  if (data !== undefined) error.data = data;
  return { jsonrpc: '2.0', id: id ?? null, error };
}

function readBody(req, maxBytes) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let total = 0;
    let settled = false;

    req.on('data', (chunk) => {
      if (settled) return;
      total += chunk.length;
      if (total > maxBytes) {
        settled = true;
        // Keep draining so the client can read the 413 response.
        req.removeAllListeners('data');
        req.resume();
        reject(new BodyTooLargeError());
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => {
      if (settled) return;
      settled = true;
      resolve(Buffer.concat(chunks));
    });
    req.on('error', (error) => {
      if (settled) return;
      settled = true;
      reject(error);
    });
  });
}

function notificationSessionIds(message) {
  const params = isPlainObject(message.params) ? message.params : {};
  const ids = new Set();
  for (const key of ['sessionId', 'parentSessionId', 'childSessionId']) {
    if (typeof params[key] === 'string') ids.add(params[key]);
  }
  if (isPlainObject(params.event) && typeof params.event.sessionId === 'string') {
    ids.add(params.event.sessionId);
  }
  return ids;
}

/**
 * Build a bridge instance without binding a socket. Tests use this directly.
 *
 * @param {ReturnType<typeof loadConfig>} config
 * @param {{logger?: object, metrics?: object, runtime?: object}} [deps]
 */
export function createBridge(config, deps = {}) {
  const logger = deps.logger ?? createLogger({ level: config.logLevel });
  const metrics = deps.metrics ?? new BridgeMetrics();
  const runtime = deps.runtime ?? new DshRuntime({ config, logger, metrics });

  const startedAt = Date.now();
  const sseClients = new Set();
  const hostPending = new Map();
  const sockets = new Set();

  let server = null;
  let closing = false;
  let keepaliveTimer = null;
  let sseSequence = 0;
  let inflight = 0;

  function sendJson(res, status, body, extraHeaders = {}) {
    const payload = JSON.stringify(body);
    res.writeHead(status, {
      'content-type': 'application/json; charset=utf-8',
      'content-length': Buffer.byteLength(payload),
      'cache-control': 'no-store',
      ...extraHeaders,
    });
    res.end(payload);
  }

  function sendRpcError(res, status, id, code, message) {
    sendJson(res, status, errorBody(id, code, message));
  }

  function dropSseClient(client, reason) {
    if (!sseClients.delete(client)) return;
    metrics.sseClients.set(sseClients.size);
    logger.warn('closing SSE client', { reason, remaining: sseClients.size });
    client.res.destroy();
  }

  function writeSse(client, message) {
    if (client.res.destroyed || client.res.writableEnded) {
      dropSseClient(client, 'closed');
      return;
    }
    if (client.res.writableLength > config.sseMaxBufferedBytes) {
      dropSseClient(client, 'slow-client');
      return;
    }
    const frame = `id: ${++sseSequence}\nevent: rpc\ndata: ${JSON.stringify(message)}\n\n`;
    client.res.write(frame);
  }

  function broadcast(message) {
    for (const client of sseClients) {
      if (client.sessionId) {
        const ids = notificationSessionIds(message);
        if (ids.size > 0 && !ids.has(client.sessionId)) continue;
      }
      writeSse(client, message);
    }
  }

  function autoAnswerHostRequest(message, reason) {
    const result = message.method === 'user-question/ask' ? { cancelled: true } : { outcome: 'cancelled' };
    logger.warn('cancelling server-to-client request', { method: message.method, rpcId: message.id, reason });
    runtime.sendResponse({ jsonrpc: '2.0', id: message.id, result }).catch((error) => {
      logger.warn('could not send cancellation for server-to-client request', error);
    });
  }

  function onHostRequest(message) {
    if (message.method === 'approval/request' && !config.enableApprovals) {
      autoAnswerHostRequest(message, 'approvals-disabled');
      return;
    }
    if (message.method === 'user-question/ask' && !config.enableUserQuestions) {
      autoAnswerHostRequest(message, 'user-questions-disabled');
      return;
    }
    if (sseClients.size === 0) {
      autoAnswerHostRequest(message, 'no-sse-client');
      return;
    }

    const key = idKey(message.id);
    const timer = setTimeout(() => {
      hostPending.delete(key);
      autoAnswerHostRequest(message, 'client-timeout');
    }, config.rpcTimeoutMs);
    timer.unref?.();
    hostPending.set(key, { message, timer });
    broadcast(message);
  }

  async function handleRpc(req, res, requestId) {
    const contentType = (req.headers['content-type'] ?? '').split(';')[0].trim().toLowerCase();
    if (contentType !== 'application/json') {
      sendRpcError(res, 415, null, JSON_RPC_ERRORS.invalidRequest.code, 'Content-Type must be application/json');
      return;
    }

    let decodedId = null;
    try {
      const buffer = await readBody(req, config.maxBodyBytes);
      if (buffer.length === 0) {
        throw new RequestValidationError(JSON_RPC_ERRORS.parse.code, 'Empty body');
      }

      let decoded;
      try {
        decoded = JSON.parse(buffer.toString('utf8'));
      } catch {
        throw new RequestValidationError(JSON_RPC_ERRORS.parse.code, 'Malformed JSON');
      }
      if (isPlainObject(decoded) && (typeof decoded.id === 'string' || typeof decoded.id === 'number')) {
        decodedId = decoded.id;
      }

      const { kind, message } = classifyMessage(decoded);
      await dispatchRpc(kind, message, res, requestId);
    } catch (error) {
      if (res.headersSent) {
        res.destroy();
        return;
      }
      if (error instanceof BodyTooLargeError) {
        sendRpcError(res, 413, decodedId, JSON_RPC_ERRORS.invalidRequest.code, `Body exceeds ${config.maxBodyBytes} bytes`);
        return;
      }
      if (error instanceof RequestValidationError) {
        sendRpcError(res, error.status, decodedId, error.code, error.message);
        return;
      }
      logger.error('unhandled /v1/rpc failure', { requestId, error });
      sendRpcError(res, 500, decodedId, JSON_RPC_ERRORS.internal.code, JSON_RPC_ERRORS.internal.message);
    }
  }

  async function dispatchRpc(kind, message, res, requestId) {
    if (closing) {
      sendRpcError(res, 503, message.id, JSON_RPC_ERRORS.unavailable.code, 'Bridge is shutting down');
      return;
    }

    if (kind === 'response') {
      const key = idKey(message.id);
      const entry = hostPending.get(key);
      if (!entry) {
        sendRpcError(res, 400, message.id, JSON_RPC_ERRORS.invalidRequest.code, 'No matching server-to-client request');
        return;
      }
      hostPending.delete(key);
      clearTimeout(entry.timer);
      try {
        await runtime.sendResponse(message);
      } catch (error) {
        logger.warn('could not forward client response to dsh', error);
        sendRpcError(res, 503, message.id, JSON_RPC_ERRORS.unavailable.code, 'DSH unavailable');
        return;
      }
      res.writeHead(202).end();
      return;
    }

    if (!runtime.ready) {
      sendRpcError(res, 503, message.id, JSON_RPC_ERRORS.unavailable.code, 'DSH is not ready');
      return;
    }

    if (kind === 'notification') {
      try {
        await runtime.sendNotification(message);
        res.writeHead(202).end();
      } catch (error) {
        logger.warn('could not forward notification to dsh', error);
        sendRpcError(res, 503, null, JSON_RPC_ERRORS.unavailable.code, 'DSH unavailable');
      }
      return;
    }

    const method = message.method;
    const methodLabel = rpcMethodLabel(method);
    if (inflight >= config.maxInflight) {
      metrics.rpcRequests.inc({ method: methodLabel, status: 'busy' });
      sendRpcError(res, 429, message.id, JSON_RPC_ERRORS.busy.code, 'Too many in-flight requests');
      return;
    }

    inflight += 1;
    metrics.rpcInflight.set(inflight);
    const started = process.hrtime.bigint();
    const stopTimer = metrics.rpcDuration.startTimer({ method: methodLabel });
    const sessionId = typeof message.params?.sessionId === 'string' ? message.params.sessionId : undefined;
    let outcome = 'ok';
    try {
      const response = await runtime.sendRequest(message, { timeoutMs: config.rpcTimeoutMs });
      outcome = response.error ? 'error' : 'ok';
      metrics.rpcRequests.inc({ method: methodLabel, status: outcome });
      // A JSON-RPC error is still a valid DSH response: HTTP 200 by design.
      sendJson(res, 200, response);
    } catch (error) {
      if (error instanceof DuplicateIdError) {
        outcome = 'duplicate';
        metrics.rpcRequests.inc({ method: methodLabel, status: outcome });
        sendRpcError(res, 409, message.id, JSON_RPC_ERRORS.invalidRequest.code, 'Request id is already in flight');
      } else if (error instanceof DshTimeoutError) {
        outcome = 'timeout';
        metrics.rpcRequests.inc({ method: methodLabel, status: outcome });
        sendRpcError(res, 504, message.id, JSON_RPC_ERRORS.timeout.code, 'DSH request timed out');
      } else if (error instanceof DshUnavailableError) {
        outcome = 'unavailable';
        metrics.rpcRequests.inc({ method: methodLabel, status: outcome });
        sendRpcError(res, 503, message.id, JSON_RPC_ERRORS.unavailable.code, 'DSH unavailable');
      } else {
        outcome = 'error';
        metrics.rpcRequests.inc({ method: methodLabel, status: outcome });
        logger.error('rpc forwarding failed', { requestId, rpcId: String(message.id), method, sessionId, error });
        sendRpcError(res, 500, message.id, JSON_RPC_ERRORS.internal.code, JSON_RPC_ERRORS.internal.message);
      }
    } finally {
      inflight -= 1;
      metrics.rpcInflight.set(inflight);
      stopTimer();
      logger.debug('rpc request', {
        requestId,
        rpcId: String(message.id),
        method,
        sessionId,
        status: outcome,
        durationMs: Math.round(Number(process.hrtime.bigint() - started) / 1e6),
      });
    }
  }

  function handleEvents(req, res, url) {
    const sessionId = url.searchParams.get('sessionId') || undefined;

    res.writeHead(200, {
      'content-type': 'text/event-stream; charset=utf-8',
      'cache-control': 'no-cache, no-transform',
      connection: 'keep-alive',
      'x-accel-buffering': 'no',
    });
    res.flushHeaders?.();
    res.write(': connected\n\n');

    const client = { res, sessionId };
    sseClients.add(client);
    metrics.sseClients.set(sseClients.size);

    const cleanup = () => {
      if (sseClients.delete(client)) metrics.sseClients.set(sseClients.size);
    };
    req.on('close', cleanup);
    res.on('close', cleanup);
    logger.debug('SSE client connected', { sessionId, clients: sseClients.size });
  }

  function handleStatus(res) {
    sendJson(res, 200, {
      ready: runtime.ready && !closing,
      dshVersion: runtime.dshVersion,
      serverInfo: runtime.serverInfo,
      pid: process.pid,
      uptimeMs: Date.now() - startedAt,
      inflight,
      sseClients: sseClients.size,
      lastExit: runtime.lastExit,
      config: {
        provider: config.provider,
        model: config.model,
        cwd: config.dshCwd,
      },
    });
  }

  async function handleRequest(req, res) {
    const started = process.hrtime.bigint();
    const requestId = randomUUID();
    const url = new URL(req.url ?? '/', 'http://bridge.invalid');
    const route = ROUTES.has(url.pathname) ? url.pathname : 'other';

    let recorded = false;
    const recordRequest = () => {
      if (recorded) return;
      recorded = true;
      const seconds = Number(process.hrtime.bigint() - started) / 1e9;
      metrics.httpRequests.inc({ method: req.method, route, status: String(res.statusCode) });
      metrics.httpDuration.observe({ method: req.method, route }, seconds);
      const fields = { requestId, method: req.method, route, status: res.statusCode, durationMs: Math.round(seconds * 1000) };
      if (res.statusCode >= 500) logger.error('http request', fields);
      else if (res.statusCode >= 400) logger.warn('http request', fields);
      else logger.debug('http request', fields);
    };
    res.on('finish', recordRequest);
    // SSE responses end with 'close' rather than 'finish'.
    res.on('close', recordRequest);

    try {
      if (closing) {
        sendRpcError(res, 503, null, JSON_RPC_ERRORS.unavailable.code, 'Bridge is shutting down');
        return;
      }

      if (route === 'other') {
        sendJson(res, 404, { error: 'Not found' });
        return;
      }

      if (url.pathname === '/v1/rpc') {
        if (req.method !== 'POST') {
          sendJson(res, 405, { error: 'Method not allowed' }, { allow: 'POST' });
          return;
        }
        await handleRpc(req, res, requestId);
        return;
      }

      if (url.pathname === '/v1/events') {
        if (req.method !== 'GET') {
          sendJson(res, 405, { error: 'Method not allowed' }, { allow: 'GET' });
          return;
        }
        handleEvents(req, res, url);
        return;
      }

      if (req.method !== 'GET') {
        sendJson(res, 405, { error: 'Method not allowed' }, { allow: 'GET' });
        return;
      }

      switch (url.pathname) {
        case '/healthz':
          sendJson(res, 200, { status: 'ok' });
          return;
        case '/readyz':
          if (runtime.ready && !closing) sendJson(res, 200, { status: 'ready' });
          else sendJson(res, 503, { status: 'not-ready' });
          return;
        case '/v1/status':
          handleStatus(res);
          return;
        case '/metrics': {
          const body = await metrics.render();
          res.writeHead(200, { 'content-type': metrics.contentType() });
          res.end(body);
          return;
        }
        default:
          sendJson(res, 404, { error: 'Not found' });
      }
    } catch (error) {
      logger.error('unhandled http failure', { requestId, error });
      if (!res.headersSent) {
        sendRpcError(res, 500, null, JSON_RPC_ERRORS.internal.code, JSON_RPC_ERRORS.internal.message);
      } else {
        res.destroy();
      }
    }
  }

  runtime.on('notification', (message) => {
    metrics.events.inc({ method: notificationMethodLabel(message.method) });
    broadcast(message);
  });
  runtime.on('hostRequest', onHostRequest);
  runtime.on('exit', (lastExit) => {
    logger.warn('dsh child gone', lastExit);
  });

  return {
    runtime,
    metrics,
    logger,
    get server() {
      return server;
    },
    get url() {
      const host = config.httpBind === '0.0.0.0' || config.httpBind === '::' ? '127.0.0.1' : config.httpBind;
      const address = server?.address();
      const port = address && typeof address === 'object' ? address.port : config.httpPort;
      return `http://${host}:${port}`;
    },

    async start() {
      await runtime.start();
      server = http.createServer((req, res) => {
        handleRequest(req, res).catch((error) => {
          logger.error('request handler rejected', error);
          if (!res.headersSent) res.writeHead(500).end();
        });
      });
      server.headersTimeout = 10_000;
      server.requestTimeout = 30_000;
      server.keepAliveTimeout = 65_000;
      server.timeout = 0;
      server.maxConnections = 1024;
      server.on('connection', (socket) => {
        sockets.add(socket);
        socket.on('close', () => sockets.delete(socket));
      });

      keepaliveTimer = setInterval(() => {
        for (const client of sseClients) {
          if (client.res.destroyed || client.res.writableEnded) {
            dropSseClient(client, 'closed');
            continue;
          }
          if (client.res.writableLength > config.sseMaxBufferedBytes) {
            dropSseClient(client, 'slow-client');
            continue;
          }
          client.res.write(': ping\n\n');
        }
      }, config.sseKeepaliveMs);
      keepaliveTimer.unref?.();

      await new Promise((resolve, reject) => {
        const onError = (error) => reject(error);
        server.once('error', onError);
        server.listen(config.httpPort, config.httpBind, () => {
          server.removeListener('error', onError);
          resolve();
        });
      });

      if (!isLoopback(config.httpBind) && !config.allowUnauthenticatedExposure) {
        // Inside the container the listener is intentionally wide; the host
        // publish address is what `scripts/run.sh` validates.
        const emit = process.env.DSH_CONTAINER === '1' ? 'debug' : 'warn';
        logger[emit]('bridge is listening on a non-loopback address without authentication', {
          bind: config.httpBind,
        });
      }
      logger.info('bridge listening', {
        url: this.url,
        bind: config.httpBind,
        port: config.httpPort,
        authentication: 'none',
      });
    },

    async stop() {
      closing = true;
      if (keepaliveTimer) {
        clearInterval(keepaliveTimer);
        keepaliveTimer = null;
      }
      for (const client of [...sseClients]) dropSseClient(client, 'shutdown');
      for (const [key, entry] of hostPending) {
        clearTimeout(entry.timer);
        hostPending.delete(key);
      }
      if (server) {
        const closed = new Promise((resolve) => server.close(resolve));
        for (const socket of sockets) socket.destroy();
        await closed;
        server = null;
      }
      await runtime.stop();
      logger.info('bridge stopped');
    },
  };
}

async function main() {
  let config;
  try {
    config = loadConfig(process.env);
  } catch (error) {
    const message = error instanceof ConfigError ? error.message : String(error);
    process.stderr.write(`${JSON.stringify({ ts: new Date().toISOString(), level: 'error', msg: `configuration error: ${message}` })}\n`);
    process.exit(1);
  }

  const bridge = createBridge(config);
  bridge.runtime.on('fatal', (error) => {
    bridge.logger.error('fatal dsh supervision failure', error);
    process.exitCode = 1;
    void bridge.stop().finally(() => process.exit(1));
  });

  let stopping = false;
  const shutdown = (signal) => {
    if (stopping) return;
    stopping = true;
    bridge.logger.info('received signal, shutting down', { signal });
    bridge.stop()
      .then(() => process.exit(0))
      .catch((error) => {
        bridge.logger.error('shutdown failed', error);
        process.exit(1);
      });
  };
  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));

  try {
    await bridge.start();
  } catch (error) {
    bridge.logger.error('bridge failed to start', error);
    await bridge.stop().catch(() => {});
    process.exit(1);
  }
}

const entrypoint = process.argv[1] ? path.resolve(process.argv[1]) : '';
if (entrypoint === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    process.stderr.write(`${JSON.stringify({ ts: new Date().toISOString(), level: 'error', msg: `bridge crashed: ${error?.message ?? error}` })}\n`);
    process.exit(1);
  });
}
