#!/usr/bin/env node
/**
 * Deterministic stand-in for the `dsh` binary.
 *
 * With `web` it serves a trivial HTTP endpoint on WEB_INTERNAL_HOST:PORT, like
 * `dsh web` does. Otherwise it speaks the newline-delimited JSON-RPC protocol
 * for the subset the SDK bridge uses, so CI can exercise the bridge without
 * model credentials.
 * Behaviour knobs (environment):
 *   FAKE_DSH_VERSION          version printed by `--version`
 *   FAKE_DSH_INIT_ERROR=1     answer `initialize` with a JSON-RPC error
 *   FAKE_DSH_EXIT_AFTER_INIT=1 exit shortly after answering `initialize`
 */

import http from 'node:http';
import readline from 'node:readline';

const VERSION = process.env.FAKE_DSH_VERSION ?? '0.0.0-test';

if (process.argv.includes('--version')) {
  process.stdout.write(`${VERSION}\n`);
  process.exit(0);
}

if (process.argv.includes('web')) {
  const host = process.env.WEB_INTERNAL_HOST || '127.0.0.1';
  const port = Number(process.env.WEB_INTERNAL_PORT || 8081);
  const server = http.createServer((_req, res) => {
    res.writeHead(200, { 'content-type': 'text/plain' });
    res.end('fake dsh web\n');
  });
  server.listen(port, host, () => process.stderr.write(`[fake-dsh] web on ${host}:${port}\n`));
  const stop = () => server.close(() => process.exit(0));
  process.on('SIGTERM', stop);
  process.on('SIGINT', stop);
} else {

const write = (message) => process.stdout.write(`${JSON.stringify(message)}\n`);
const log = (message) => process.stderr.write(`[fake-dsh] ${message}\n`);
const reply = (id, result) => write({ jsonrpc: '2.0', id, result });
const fail = (id, code, message) => write({ jsonrpc: '2.0', id, error: { code, message } });

const sessions = new Map();
let promptSequence = 0;

function sessionState(sessionId) {
  if (!sessions.has(sessionId)) {
    sessions.set(sessionId, { busy: false, waiters: [], timers: [] });
  }
  return sessions.get(sessionId);
}

function settleWaiters(state) {
  for (const resolve of state.waiters.splice(0)) resolve();
}

function scheduleTurn(sessionId, text) {
  const state = sessionState(sessionId);
  state.busy = true;
  state.timers = [
    setTimeout(() => {
      write({ jsonrpc: '2.0', method: 'session.status', params: { sessionId, status: 'running' } });
    }, 5),
    setTimeout(() => {
      write({
        jsonrpc: '2.0',
        method: 'session.event',
        params: {
          sessionId,
          event: {
            type: 'assistant/message',
            sessionId,
            role: 'assistant',
            content: [{ type: 'text', text: `echo: ${text}` }],
          },
        },
      });
    }, 15),
    setTimeout(() => {
      write({
        jsonrpc: '2.0',
        method: 'session.query.completed',
        params: { sessionId, commandId: 'fake-command', finalResponse: `echo: ${text}`, finishReason: 'stop' },
      });
      write({ jsonrpc: '2.0', method: 'session.status', params: { sessionId, status: 'idle' } });
      state.busy = false;
      state.timers = [];
      settleWaiters(state);
    }, 25),
  ];
}

const handlers = {
  initialize(id, params) {
    if (process.env.FAKE_DSH_INIT_ERROR === '1') {
      fail(id, -32000, 'fake initialize failure');
      return;
    }
    if (!params || typeof params.cwd !== 'string' || typeof params.provider !== 'string' || typeof params.model !== 'string') {
      fail(id, -32602, 'invalid initialize params');
      return;
    }
    log(`initialize cwd=${params.cwd} provider=${params.provider} model=${params.model}`);
    reply(id, { serverInfo: { name: 'deepseek-harness-sdk-runtime', version: '0.0.1' } });
    if (process.env.FAKE_DSH_EXIT_AFTER_INIT === '1') {
      setTimeout(() => process.exit(3), 10);
    }
  },

  'session/prompt'(id, params) {
    if (!params || typeof params.sessionId !== 'string' || !Array.isArray(params.contentBlocks)) {
      fail(id, -32602, 'invalid session/prompt params');
      return;
    }
    promptSequence += 1;
    const messageId = `fake-msg-${promptSequence}`;
    const text = params.contentBlocks
      .filter((block) => block?.type === 'text' && typeof block.text === 'string')
      .map((block) => block.text)
      .join(' ');
    reply(id, { messageId });
    scheduleTurn(params.sessionId, text);
  },

  'session/query'(id, params) {
    handlers['session/prompt'](id, params);
  },

  'session/wait'(id, params) {
    if (!params || typeof params.sessionId !== 'string') {
      fail(id, -32602, 'invalid session/wait params');
      return;
    }
    const state = sessions.get(params.sessionId);
    if (!state || !state.busy) {
      reply(id, {});
      return;
    }
    state.waiters.push(() => reply(id, {}));
  },

  'session/resume'(id, params) {
    if (!params || typeof params.sessionId !== 'string') {
      fail(id, -32602, 'invalid session/resume params');
      return;
    }
    reply(id, {});
  },

  'session/working-directory/get'(id) {
    reply(id, { cwd: process.cwd() });
  },

  'testing/slow'(id, params) {
    const ms = Number(params?.ms ?? 50);
    setTimeout(() => reply(id, { sleptMs: ms }), ms);
  },

  'testing/crash'(id) {
    reply(id, { crashing: true });
    setTimeout(() => process.exit(4), 10);
  },

  shutdown(id) {
    reply(id, {});
    if (process.env.FAKE_DSH_IGNORE_SHUTDOWN !== '1') {
      setTimeout(() => process.exit(0), 5);
    }
  },
};

const lines = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });

lines.on('line', (line) => {
  if (line.trim() === '') return;
  let message;
  try {
    message = JSON.parse(line);
  } catch {
    log(`ignoring malformed line: ${line.slice(0, 120)}`);
    return;
  }

  const { id, method, params } = message;
  const handler = Object.prototype.hasOwnProperty.call(handlers, method) ? handlers[method] : null;
  if (!handler) {
    if (id !== undefined) fail(id, -32601, `Method not found: ${method}`);
    return;
  }
  try {
    handler(id, params);
  } catch (error) {
    if (id !== undefined) fail(id, -32603, `fake handler error: ${error.message}`);
  }
});

lines.on('close', () => process.exit(0));
process.on('SIGTERM', () => process.exit(0));
process.on('SIGINT', () => process.exit(0));
}
