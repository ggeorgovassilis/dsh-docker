/**
 * Reverse proxy that exposes the DSH web UI on a publishable address.
 *
 * `dsh web` deliberately refuses to bind a wildcard address (it would expose
 * remote code execution to the network), so it listens on loopback only. This
 * proxy binds a publishable address and forwards HTTP and WebSocket traffic to
 * that loopback listener.
 *
 * The Host header is rewritten to the loopback target. DSH's auth cookie and
 * browser-trust fence are bound to the authority (host:port) they see, so
 * presenting the loopback authority consistently keeps the fence happy no
 * matter what host:port the client actually connects through.
 *
 * @module dsh-api-runtime/web-proxy
 */

import http from 'node:http';
import net from 'node:net';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

export function createWebProxy({ bind, port, targetHost, targetPort }) {
  const authority = `${targetHost}:${targetPort}`;

  const server = http.createServer((req, res) => {
    const headers = { ...req.headers };
    headers.host = authority;

    const upstream = http.request(
      {
        host: targetHost,
        port: targetPort,
        method: req.method,
        path: req.url,
        headers,
      },
      (upstreamRes) => {
        res.writeHead(upstreamRes.statusCode ?? 502, upstreamRes.headers);
        upstreamRes.pipe(res);
      },
    );

    upstream.on('error', () => {
      if (!res.headersSent) res.writeHead(502, { 'content-type': 'text/plain' });
      res.end('Bad gateway');
    });

    req.on('error', () => upstream.destroy());
    res.on('close', () => upstream.destroy());
    req.pipe(upstream);
  });

  server.on('upgrade', (req, socket, head) => {
    const headers = { ...req.headers };
    headers.host = authority;

    const lines = [`${req.method} ${req.url} HTTP/${req.httpVersion}`];
    for (const [name, value] of Object.entries(headers)) {
      if (value === undefined) continue;
      if (Array.isArray(value)) for (const item of value) lines.push(`${name}: ${item}`);
      else lines.push(`${name}: ${value}`);
    }

    const upstream = net.connect(targetPort, targetHost, () => {
      upstream.write(`${lines.join('\r\n')}\r\n\r\n`);
      if (head && head.length > 0) upstream.write(head);
      socket.pipe(upstream);
      upstream.pipe(socket);
    });

    upstream.on('error', () => socket.destroy());
    upstream.on('close', () => socket.destroy());
    socket.on('error', () => upstream.destroy());
    socket.on('close', () => upstream.destroy());
  });

  server.on('clientError', (_error, socket) => {
    if (socket.writable) socket.end('HTTP/1.1 400 Bad Request\r\n\r\n');
  });

  return server;
}

function main() {
  const bind = process.env.WEB_BIND || '0.0.0.0';
  const port = Number(process.env.WEB_PORT || 8080);
  const targetHost = process.env.WEB_INTERNAL_HOST || '127.0.0.1';
  const targetPort = Number(process.env.WEB_INTERNAL_PORT || 8081);

  const server = createWebProxy({ bind, port, targetHost, targetPort });

  server.listen(port, bind, () => {
    process.stdout.write(`${JSON.stringify({ level: 'info', msg: 'web proxy listening', bind, port, target: `${targetHost}:${targetPort}` })}\n`);
  });

  let stopping = false;
  const stop = () => {
    if (stopping) return;
    stopping = true;
    server.close(() => process.exit(0));
  };
  process.on('SIGTERM', stop);
  process.on('SIGINT', stop);
}

const entrypoint = process.argv[1] ? path.resolve(process.argv[1]) : '';
if (entrypoint === fileURLToPath(import.meta.url)) {
  main();
}
