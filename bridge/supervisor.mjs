/**
 * Process supervisor for the DSH API runtime container.
 *
 * Runs the three long-lived processes that make up the runtime and fans
 * SIGTERM/SIGINT out to all of them so `docker stop` shuts everything down
 * cleanly instead of only the first child:
 *
 *   1. `dsh web`            — the official web UI, bound to loopback only.
 *   2. `web-proxy.mjs`      — reverse proxy exposing the web UI on a
 *                             publishable address.
 *   3. `server.mjs`         — the JSON-RPC SDK bridge.
 *
 * If any child exits unexpectedly, the supervisor tears down the rest and
 * exits non-zero so the orchestrator can restart the container.
 *
 * @module dsh-api-runtime/supervisor
 */

import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));

const DSH_BIN = process.env.DSH_BIN || '/app/node_modules/.bin/dsh';
const WEB_INTERNAL_HOST = process.env.WEB_INTERNAL_HOST || '127.0.0.1';
const WEB_INTERNAL_PORT = process.env.WEB_INTERNAL_PORT || '8081';

// The container is capped by --memory, so a child can be killed by the kernel
// OOM killer without any log line of its own. Read the cgroup to tell that
// apart from a crash.
const CGROUP_DIR = process.env.CGROUP_DIR || '/sys/fs/cgroup';

const children = new Map();
let stopping = false;
let exitCode = 0;

function readCgroupNumber(name) {
  try {
    const value = fs.readFileSync(path.join(CGROUP_DIR, name), 'utf8').trim();
    return value === 'max' ? null : Number(value);
  } catch {
    return null;
  }
}

function readOomKills() {
  try {
    const match = /^oom_kill (\d+)$/m.exec(fs.readFileSync(path.join(CGROUP_DIR, 'memory.events'), 'utf8'));
    return match ? Number(match[1]) : 0;
  } catch {
    return 0;
  }
}

function memory() {
  return {
    maxBytes: readCgroupNumber('memory.max'),
    currentBytes: readCgroupNumber('memory.current'),
    peakBytes: readCgroupNumber('memory.peak'),
    oomKills: readOomKills(),
  };
}

function launch(name, command, args) {
  const child = spawn(command, args, { stdio: 'inherit', env: process.env });
  children.set(name, child);
  child.on('exit', (code, signal) => {
    children.delete(name);
    if (!stopping) {
      const oomKilled = signal === 'SIGKILL' && readOomKills() > 0;
      const stat = oomKilled ? memory() : undefined;
      process.stderr.write(`${JSON.stringify({
        level: 'error',
        msg: oomKilled ? 'supervised process killed by the out-of-memory killer' : 'supervised process exited',
        name,
        code: code ?? null,
        signal: signal ?? null,
        ...(oomKilled ? { oomKilled, memory: stat, hint: 'raise MEMORY_LIMIT in .env and run scripts/run.sh -d' } : {}),
      })}\n`);
      shutdown(code && code > 0 ? code : 1);
    } else {
      finish();
    }
  });
  return child;
}

function terminateChildren() {
  for (const child of children.values()) child.kill('SIGTERM');
}

function finish() {
  if (stopping && children.size === 0) process.exit(exitCode);
}

function shutdown(code) {
  if (stopping) return;
  stopping = true;
  exitCode = code;
  terminateChildren();

  // Force-kill stragglers so the container cannot hang on shutdown.
  const force = setTimeout(() => {
    for (const child of children.values()) {
      if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL');
    }
  }, 20_000);
  force.unref();

  finish();
}

process.on('SIGTERM', () => shutdown(0));
process.on('SIGINT', () => shutdown(0));

const limits = memory();
if (limits.maxBytes !== null) {
  process.stderr.write(`${JSON.stringify({ level: 'info', msg: 'container memory limit', memory: limits })}\n`);
}

launch('dsh-web', DSH_BIN, ['web', '--no-open', '--host', WEB_INTERNAL_HOST, '--port', WEB_INTERNAL_PORT]);
launch('web-proxy', process.execPath, [path.join(HERE, 'web-proxy.mjs')]);
launch('sdk-bridge', process.execPath, [path.join(HERE, 'server.mjs')]);
