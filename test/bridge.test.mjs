/**
 * Unit and fake-DSH integration tests for the bridge.
 *
 * Everything runs with Node's built-in test runner and a deterministic
 * JSON-RPC fixture, so no model credentials or host npm tree are required.
 */

import assert from 'node:assert/strict';
import { after, describe, it } from 'node:test';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { ConfigError, isLoopback, loadConfig } from '../bridge/config.mjs';
import { classifyMessage, createBridge, RequestValidationError } from '../bridge/server.mjs';
import { notificationMethodLabel, rpcMethodLabel } from '../bridge/telemetry.mjs';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const FAKE_DSH = path.join(ROOT, 'test', 'fake-dsh.mjs');

function baseEnv(overrides = {}) {
  return {
    HTTP_BIND: '127.0.0.1',
    HTTP_PORT: '0',
    DSH_BIN: FAKE_DSH,
    DSH_CWD: ROOT,
    DSH_HOME: path.join(os.tmpdir(), 'dsh-api-runtime-test-home'),
    DSH_PROVIDER: 'deepseek-official',
    DSH_MODEL: 'deepseek-v4-flash',
    DSH_TELEMETRY_MODE: 'DISABLED',
    LOG_LEVEL: 'error',
    INIT_TIMEOUT_MS: '10000',
    RPC_TIMEOUT_MS: '5000',
    MAX_INFLIGHT: '4',
    MAX_BODY_BYTES: '65536',
    ...overrides,
  };
}

function recordingLogger() {
  const entries = [];
  const push = (level) => (msg, fields) => entries.push({ level, msg, fields });
  return {
    entries,
    level: 'debug',
    debug: push('debug'),
    info: push('info'),
    warn: push('warn'),
    error: push('error'),
    dshStderr: (line) => entries.push({ level: 'dsh', msg: line }),
  };
}

async function withBridge(overrides, fn) {
  const logger = recordingLogger();
  const config = loadConfig(baseEnv(overrides));
  const bridge = createBridge(config, { logger });
  try {
    await bridge.start();
    await fn(bridge, logger);
  } finally {
    await bridge.stop();
  }
}

async function postRpc(url, body, { headers = {}, raw = null } = {}) {
  const response = await fetch(`${url}/v1/rpc`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', ...headers },
    body: raw ?? JSON.stringify(body),
  });
  const text = await response.text();
  return { status: response.status, headers: response.headers, body: text === '' ? null : JSON.parse(text) };
}

async function waitFor(check, { timeoutMs = 5000, intervalMs = 25 } = {}) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const result = await check();
    if (result) return result;
    if (Date.now() > deadline) throw new Error('condition not met before timeout');
    await new Promise((resolve) => setTimeout(resolve, intervalMs));
  }
}

function openSse(baseUrl, { sessionId } = {}) {
  const target = new URL('/v1/events', baseUrl);
  if (sessionId) target.searchParams.set('sessionId', sessionId);
  const controller = new AbortController();
  const messages = [];
  const waiters = [];

  const ready = fetch(target, {
    signal: controller.signal,
    headers: { accept: 'text/event-stream' },
  }).then(async (response) => {
    assert.equal(response.status, 200, 'SSE should start with 200');
    assert.match(response.headers.get('content-type') ?? '', /text\/event-stream/);
    const reader = response.body.getReader();
    const decoder = new TextDecoder();
    let buffer = '';

    (async () => {
      try {
        for (;;) {
          const { value, done } = await reader.read();
          if (done) return;
          buffer += decoder.decode(value, { stream: true });
          let index = buffer.indexOf('\n\n');
          while (index >= 0) {
            const frame = buffer.slice(0, index);
            buffer = buffer.slice(index + 2);
            const data = frame
              .split('\n')
              .filter((line) => line.startsWith('data: '))
              .map((line) => line.slice(6))
              .join('\n');
            if (data) {
              const message = JSON.parse(data);
              if (waiters.length > 0) waiters.shift()(message);
              else messages.push(message);
            }
            index = buffer.indexOf('\n\n');
          }
        }
      } catch {
        // aborted by the test
      }
    })();
    return response;
  });

  return {
    ready,
    next(timeoutMs = 5000) {
      if (messages.length > 0) return Promise.resolve(messages.shift());
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error('timed out waiting for SSE message')), timeoutMs);
        waiters.push((message) => {
          clearTimeout(timer);
          resolve(message);
        });
      });
    },
    close() {
      controller.abort();
    },
  };
}

describe('configuration', () => {
  it('applies verified defaults', () => {
    const config = loadConfig(baseEnv());
    assert.equal(config.httpBind, '127.0.0.1');
    assert.equal(config.httpPort, 0);
    assert.equal(config.provider, 'deepseek-official');
    assert.equal(config.model, 'deepseek-v4-flash');
    assert.deepEqual(config.dshArgs, ['--profile', 'sdk']);
    assert.equal(config.enableApprovals, false);
    assert.equal(config.enableUserQuestions, false);
    assert.equal(config.telemetryMode, 'DISABLED');
  });

  it('rejects invalid values', () => {
    assert.throws(() => loadConfig(baseEnv({ HTTP_PORT: 'abc' })), ConfigError);
    assert.throws(() => loadConfig(baseEnv({ HTTP_PORT: '70000' })), ConfigError);
    assert.throws(() => loadConfig(baseEnv({ ENABLE_APPROVALS: 'maybe' })), ConfigError);
    assert.throws(() => loadConfig(baseEnv({ DSH_CWD: 'relative/path' })), ConfigError);
    assert.throws(() => loadConfig(baseEnv({ LOG_LEVEL: 'verbose' })), ConfigError);
    assert.throws(() => loadConfig(baseEnv({ MAX_INFLIGHT: '0' })), ConfigError);
    assert.throws(() => loadConfig(baseEnv({ DSH_MAX_TOKENS: '-5' })), ConfigError);
  });

  it('recognises loopback addresses', () => {
    for (const address of ['127.0.0.1', '127.1.2.3', '::1', '[::1]', 'localhost']) {
      assert.equal(isLoopback(address), true, address);
    }
    for (const address of ['0.0.0.0', '::', '192.168.1.10', '10.0.0.1']) {
      assert.equal(isLoopback(address), false, address);
    }
  });
});

describe('JSON-RPC classification', () => {
  it('accepts the three supported shapes', () => {
    assert.equal(classifyMessage({ jsonrpc: '2.0', id: 1, method: 'session/prompt', params: {} }).kind, 'request');
    assert.equal(classifyMessage({ jsonrpc: '2.0', method: 'session/prompt', params: {} }).kind, 'notification');
    assert.equal(classifyMessage({ jsonrpc: '2.0', id: 7, result: {} }).kind, 'response');
    assert.equal(classifyMessage({ jsonrpc: '2.0', id: 'x', error: { code: -32000, message: 'no' } }).kind, 'response');
  });

  it('rejects malformed shapes with -32600', () => {
    const invalid = [
      [],
      [{}],
      'text',
      null,
      { id: 1, method: 'x' },
      { jsonrpc: '1.0', id: 1, method: 'x' },
      { jsonrpc: '2.0', id: null, method: 'x' },
      { jsonrpc: '2.0', id: true, method: 'x' },
      { jsonrpc: '2.0', id: 1, method: '' },
      { jsonrpc: '2.0', id: 1, method: 'x', result: {} },
      { jsonrpc: '2.0', id: 1 },
      { jsonrpc: '2.0', id: 1, result: {}, error: { code: 1, message: 'x' } },
      { jsonrpc: '2.0', id: 1, error: 'not-an-object' },
      { jsonrpc: '2.0', id: 'bridge-init-1', method: 'x' },
    ];
    for (const body of invalid) {
      assert.throws(
        () => classifyMessage(body),
        (error) => error instanceof RequestValidationError && error.code === -32600,
        JSON.stringify(body),
      );
    }
  });
});

describe('metric label cardinality', () => {
  it('collapses unknown methods into a single bounded bucket', () => {
    assert.equal(rpcMethodLabel('session/prompt'), 'session/prompt');
    assert.equal(rpcMethodLabel('session/working-directory/set'), 'session/working-directory/set');
    assert.equal(rpcMethodLabel('zzz-not-a-method'), 'other');
    assert.equal(rpcMethodLabel('__proto__'), 'other');
    assert.equal(notificationMethodLabel('session.status'), 'session.status');
    assert.equal(notificationMethodLabel('evil/notification'), 'other');
  });
});

describe('bridge with fake DSH', () => {
  it('initializes, reports status, and serves health endpoints', async () => {
    await withBridge({}, async (bridge) => {
      const base = bridge.url;

      const health = await fetch(`${base}/healthz`);
      assert.equal(health.status, 200);

      const ready = await fetch(`${base}/readyz`);
      assert.equal(ready.status, 200);

      const status = await (await fetch(`${base}/v1/status`)).json();
      assert.equal(status.ready, true);
      assert.equal(status.dshVersion, '0.0.0-test');
      assert.equal(status.serverInfo.name, 'deepseek-harness-sdk-runtime');
      assert.equal(status.config.provider, 'deepseek-official');
      assert.equal(status.config.model, 'deepseek-v4-flash');
      assert.equal(status.inflight, 0);
      assert.ok(status.uptimeMs >= 0);
    });
  });

  it('forwards session/prompt and streams notifications over SSE', async () => {
    await withBridge({}, async (bridge) => {
      const base = bridge.url;
      const sse = openSse(base, { sessionId: 'demo' });
      try {
        await sse.ready;

        const result = await postRpc(base, {
          jsonrpc: '2.0',
          id: 1,
          method: 'session/prompt',
          params: { sessionId: 'demo', contentBlocks: [{ type: 'text', text: 'list files' }] },
        });
        assert.equal(result.status, 200);
        assert.equal(result.body.jsonrpc, '2.0');
        assert.equal(result.body.id, 1);
        assert.equal(typeof result.body.result.messageId, 'string');

        const running = await sse.next();
        assert.equal(running.method, 'session.status');
        assert.deepEqual(running.params, { sessionId: 'demo', status: 'running' });

        const received = [];
        let idle;
        for (;;) {
          const message = await sse.next();
          received.push(message);
          if (message.method === 'session.status' && message.params.status === 'idle') {
            idle = message;
            break;
          }
        }

        const event = received.find((message) => message.method === 'session.event');
        assert.ok(event, 'SSE should deliver session.event');
        assert.equal(event.params.sessionId, 'demo');
        assert.equal(event.params.event.content[0].text, 'echo: list files');

        assert.equal(idle.params.status, 'idle');

        const wait = await postRpc(base, { jsonrpc: '2.0', id: 2, method: 'session/wait', params: { sessionId: 'demo' } });
        assert.equal(wait.status, 200);
        assert.deepEqual(wait.body.result, {});
      } finally {
        sse.close();
      }
    });
  });

  it('filters SSE by session id', async () => {
    await withBridge({}, async (bridge) => {
      const base = bridge.url;
      const sse = openSse(base, { sessionId: 'wanted' });
      try {
        await sse.ready;
        await postRpc(base, {
          jsonrpc: '2.0',
          id: 1,
          method: 'session/prompt',
          params: { sessionId: 'ignored', contentBlocks: [{ type: 'text', text: 'nope' }] },
        });
        await postRpc(base, {
          jsonrpc: '2.0',
          id: 2,
          method: 'session/prompt',
          params: { sessionId: 'wanted', contentBlocks: [{ type: 'text', text: 'yes' }] },
        });

        const message = await sse.next();
        assert.equal(message.params.sessionId, 'wanted');
      } finally {
        sse.close();
      }
    });
  });

  it('accepts notifications, returns 202, and rejects bad input', async () => {
    await withBridge({ MAX_BODY_BYTES: '4096' }, async (bridge) => {
      const base = bridge.url;

      const notification = await postRpc(base, {
        jsonrpc: '2.0',
        method: 'session/prompt',
        params: { sessionId: 'n', contentBlocks: [{ type: 'text', text: 'fire and forget' }] },
      });
      assert.equal(notification.status, 202);
      assert.equal(notification.body, null);

      const malformed = await postRpc(base, null, { raw: '{not json' });
      assert.equal(malformed.status, 400);
      assert.equal(malformed.body.error.code, -32700);
      assert.equal(malformed.body.id, null);

      const batch = await postRpc(base, [{ jsonrpc: '2.0', id: 1, method: 'x' }]);
      assert.equal(batch.status, 400);
      assert.equal(batch.body.error.code, -32600);

      const wrongType = await postRpc(base, { jsonrpc: '2.0', id: 1, method: 'x' }, {
        headers: { 'content-type': 'text/plain' },
      });
      assert.equal(wrongType.status, 415);

      const oversized = await postRpc(base, null, {
        raw: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'x', params: { pad: 'x'.repeat(5000) } }),
      });
      assert.equal(oversized.status, 413);
      assert.equal(oversized.body.error.code, -32600);
    });
  });

  it('maps a JSON-RPC error to HTTP 200 and preserves the id', async () => {
    await withBridge({}, async (bridge) => {
      const result = await postRpc(bridge.url, { jsonrpc: '2.0', id: 'abc', method: 'does/not/exist' });
      assert.equal(result.status, 200);
      assert.equal(result.body.id, 'abc');
      assert.equal(result.body.error.code, -32601);
    });
  });

  it('rejects duplicate in-flight ids with 409', async () => {
    await withBridge({}, async (bridge) => {
      const base = bridge.url;
      const first = postRpc(base, { jsonrpc: '2.0', id: 42, method: 'testing/slow', params: { ms: 300 } });
      const second = postRpc(base, { jsonrpc: '2.0', id: 42, method: 'testing/slow', params: { ms: 300 } });
      const [a, b] = await Promise.all([first, second]);
      const statuses = [a.status, b.status].sort((x, y) => x - y);
      assert.deepEqual(statuses, [200, 409]);
      const rejected = a.status === 409 ? a : b;
      assert.equal(rejected.body.error.code, -32600);
    });
  });

  it('enforces MAX_INFLIGHT with 429', async () => {
    await withBridge({ MAX_INFLIGHT: '1' }, async (bridge) => {
      const base = bridge.url;
      const first = postRpc(base, { jsonrpc: '2.0', id: 1, method: 'testing/slow', params: { ms: 300 } });
      await waitFor(async () => {
        const status = await (await fetch(`${base}/v1/status`)).json();
        return status.inflight === 1;
      });
      const second = await postRpc(base, { jsonrpc: '2.0', id: 2, method: 'testing/slow', params: { ms: 50 } });
      assert.equal(second.status, 429);
      assert.equal(second.body.error.code, -32002);
      await first;
    });
  });

  it('exposes the required Prometheus metrics', async () => {
    await withBridge({}, async (bridge) => {
      const base = bridge.url;
      await postRpc(base, {
        jsonrpc: '2.0',
        id: 1,
        method: 'session/prompt',
        params: { sessionId: 'm', contentBlocks: [{ type: 'text', text: 'metrics' }] },
      });
      const response = await fetch(`${base}/metrics`);
      assert.equal(response.status, 200);
      assert.match(response.headers.get('content-type') ?? '', /text\/plain/);
      const text = await response.text();

      for (const metric of [
        'dsh_bridge_http_requests_total',
        'dsh_bridge_http_request_duration_seconds',
        'dsh_bridge_rpc_requests_total',
        'dsh_bridge_rpc_request_duration_seconds',
        'dsh_bridge_rpc_inflight',
        'dsh_bridge_sse_clients',
        'dsh_bridge_events_total',
        'dsh_bridge_dsh_up',
        'dsh_bridge_dsh_restarts_total',
        'dsh_bridge_process_resident_memory_bytes',
      ]) {
        assert.match(text, new RegExp(`^(?:# (?:HELP|TYPE) )?${metric}\\b`, 'm'), metric);
      }
      assert.doesNotMatch(text, /session_id="/);
      assert.doesNotMatch(text, /request_id="/);
    });
  });

  it('bounds method label cardinality on the unauthenticated endpoint', async () => {
    await withBridge({}, async (bridge) => {
      const base = bridge.url;
      const unknown = 'zzz-unbounded-method-abc';

      const rejected = await postRpc(base, { jsonrpc: '2.0', id: 1, method: unknown });
      assert.equal(rejected.status, 200);
      assert.equal(rejected.body.error.code, -32601);

      const known = await postRpc(base, {
        jsonrpc: '2.0',
        id: 2,
        method: 'session/prompt',
        params: { sessionId: 'labels', contentBlocks: [{ type: 'text', text: 'hi' }] },
      });
      assert.equal(known.status, 200);

      const text = await (await fetch(`${base}/metrics`)).text();
      assert.ok(!text.includes(unknown), 'raw method must never become a metric label');
      assert.match(text, /dsh_bridge_rpc_requests_total\{method="other",status="error"\}/);
      assert.match(text, /dsh_bridge_rpc_requests_total\{method="session\/prompt",status="ok"\}/);
      assert.match(text, /dsh_bridge_rpc_request_duration_seconds_count\{method="other"\}/);
    });
  });

  it('restarts DSH after a crash and counts restarts', async () => {
    await withBridge({}, async (bridge) => {
      const base = bridge.url;
      const crash = await postRpc(base, { jsonrpc: '2.0', id: 1, method: 'testing/crash' });
      assert.equal(crash.status, 200);

      await waitFor(async () => {
        const text = await (await fetch(`${base}/metrics`)).text();
        const match = /^dsh_bridge_dsh_restarts_total (\d+)$/m.exec(text);
        return match !== null && Number(match[1]) >= 1;
      }, { timeoutMs: 10_000 });

      await waitFor(async () => {
        const response = await fetch(`${base}/readyz`);
        return response.status === 200;
      }, { timeoutMs: 10_000 });

      const metrics = await (await fetch(`${base}/metrics`)).text();
      const match = /^dsh_bridge_dsh_restarts_total (\d+)$/m.exec(metrics);
      assert.ok(match, 'restart counter should be exported');
      assert.ok(Number(match[1]) >= 1);

      const prompt = await postRpc(base, {
        jsonrpc: '2.0',
        id: 2,
        method: 'session/prompt',
        params: { sessionId: 'after-restart', contentBlocks: [{ type: 'text', text: 'alive' }] },
      });
      assert.equal(prompt.status, 200);
    });
  });

  it('stops within STOP_BUDGET_MS even when DSH ignores shutdown', async () => {
    const config = loadConfig(baseEnv({ STOP_BUDGET_MS: '700' }));
    const bridge = createBridge(config, { logger: recordingLogger() });
    process.env.FAKE_DSH_IGNORE_SHUTDOWN = '1';
    try {
      await bridge.start();
      const started = Date.now();
      await bridge.stop();
      const elapsed = Date.now() - started;
      assert.ok(elapsed < 5000, `stop took ${elapsed}ms`);
    } finally {
      delete process.env.FAKE_DSH_IGNORE_SHUTDOWN;
      await bridge.stop().catch(() => {});
    }
  });

  it('fails startup when DSH initialization fails', async () => {
    const config = loadConfig(baseEnv());
    const bridge = createBridge(config, { logger: recordingLogger() });
    process.env.FAKE_DSH_INIT_ERROR = '1';
    try {
      await assert.rejects(() => bridge.start(), /initialize failed/);
    } finally {
      delete process.env.FAKE_DSH_INIT_ERROR;
      await bridge.stop();
    }
  });
});

after(() => {
  // Nothing global to tear down; every bridge stops in withBridge().
});
