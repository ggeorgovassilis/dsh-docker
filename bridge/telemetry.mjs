/**
 * Prometheus metrics and structured JSON logging for the DSH HTTP bridge.
 *
 * Metrics are deliberately bounded: no session ids, request ids, or raw URLs
 * become label values.
 *
 * @module dsh-api-runtime/telemetry
 */

import { Counter, Gauge, Histogram, Registry } from '@prometheus-io/client';

const LEVEL_ORDER = { debug: 10, info: 20, warn: 30, error: 40 };

// Metric labels must stay bounded: /v1/rpc is unauthenticated, so a client
// must not be able to create arbitrary Prometheus series. Unknown names are
// collapsed into `other`; logs still carry the raw method.
const RPC_METHOD_LABELS = new Set([
  'initialize',
  'session/prompt',
  'session/query',
  'session/resume',
  'session/wait',
  'session/working-directory/get',
  'session/working-directory/set',
  'shutdown',
]);

const NOTIFICATION_METHOD_LABELS = new Set([
  'session.event',
  'session.status',
  'session.query.completed',
  'subagent.started',
  'subagent.finished',
  'user-question.cancelled',
]);

/** Bounded `method` label for client requests. */
export function rpcMethodLabel(method) {
  return RPC_METHOD_LABELS.has(method) ? method : 'other';
}

/** Bounded `method` label for DSH notifications. */
export function notificationMethodLabel(method) {
  return NOTIFICATION_METHOD_LABELS.has(method) ? method : 'other';
}

const SECRET_KEY = /(key|token|secret|password|authorization|cookie)/i;
const MAX_FIELD_LENGTH = 512;

function sanitiseValue(key, value) {
  if (SECRET_KEY.test(key)) return '[redacted]';
  if (typeof value === 'string' && value.length > MAX_FIELD_LENGTH) {
    return `${value.slice(0, MAX_FIELD_LENGTH)}…`;
  }
  if (value instanceof Error) return value.message;
  return value;
}

/**
 * Create a JSON-lines logger.
 *
 * @param {{level?: string}} [options]
 */
export function createLogger({ level = 'info' } = {}) {
  const threshold = LEVEL_ORDER[level] ?? LEVEL_ORDER.info;

  function emit(levelName, msg, fields = {}) {
    if (LEVEL_ORDER[levelName] < threshold) return;
    const record = { ts: new Date().toISOString(), level: levelName, msg };
    for (const [key, value] of Object.entries(fields)) {
      if (value === undefined) continue;
      record[key] = sanitiseValue(key, value);
    }
    const line = `${JSON.stringify(record)}\n`;
    if (levelName === 'error' || levelName === 'warn') process.stderr.write(line);
    else process.stdout.write(line);
  }

  return {
    level,
    debug: (msg, fields) => emit('debug', msg, fields),
    info: (msg, fields) => emit('info', msg, fields),
    warn: (msg, fields) => emit('warn', msg, fields),
    error: (msg, fields) => emit('error', msg, fields),
    /** Forward one line of DSH stderr without letting it masquerade as bridge output. */
    dshStderr: (line) => {
      if (line.trim() === '') return;
      emit('info', `[dsh] ${line.slice(0, 4096)}`);
    },
  };
}

/**
 * Registry of every metric this bridge promises to expose.
 */
export class BridgeMetrics {
  constructor() {
    this.registry = new Registry();
    this.registry.setDefaultLabels({});

    this.httpRequests = new Counter({
      name: 'dsh_bridge_http_requests_total',
      help: 'HTTP requests handled by the bridge.',
      labelNames: ['method', 'route', 'status'],
      registers: [this.registry],
    });

    this.httpDuration = new Histogram({
      name: 'dsh_bridge_http_request_duration_seconds',
      help: 'HTTP request duration in seconds.',
      labelNames: ['method', 'route'],
      buckets: [0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1, 5, 15, 60, 300],
      registers: [this.registry],
    });

    this.rpcRequests = new Counter({
      name: 'dsh_bridge_rpc_requests_total',
      help: 'JSON-RPC requests forwarded to DSH.',
      labelNames: ['method', 'status'],
      registers: [this.registry],
    });

    this.rpcDuration = new Histogram({
      name: 'dsh_bridge_rpc_request_duration_seconds',
      help: 'JSON-RPC request duration in seconds.',
      labelNames: ['method'],
      buckets: [0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1, 5, 15, 60, 300],
      registers: [this.registry],
    });

    this.rpcInflight = new Gauge({
      name: 'dsh_bridge_rpc_inflight',
      help: 'Client requests currently waiting on DSH.',
      registers: [this.registry],
    });

    this.sseClients = new Gauge({
      name: 'dsh_bridge_sse_clients',
      help: 'Connected SSE clients.',
      registers: [this.registry],
    });

    this.events = new Counter({
      name: 'dsh_bridge_events_total',
      help: 'DSH notifications fanned out to SSE clients.',
      labelNames: ['method'],
      registers: [this.registry],
    });

    this.dshUp = new Gauge({
      name: 'dsh_bridge_dsh_up',
      help: '1 when the DSH child process has completed initialization.',
      registers: [this.registry],
    });

    this.dshRestarts = new Counter({
      name: 'dsh_bridge_dsh_restarts_total',
      help: 'DSH child restart attempts.',
      registers: [this.registry],
    });

    this.residentMemory = new Gauge({
      name: 'dsh_bridge_process_resident_memory_bytes',
      help: 'Bridge process resident set size in bytes.',
      registers: [this.registry],
      collect() {
        this.set(process.memoryUsage().rss);
      },
    });

    this.dshUp.set(0);
    this.rpcInflight.set(0);
    this.sseClients.set(0);
  }

  async render() {
    return this.registry.metrics();
  }

  contentType() {
    return this.registry.contentType;
  }
}
