# DSH API Runtime — Proposal

**Status:** proposal — resolve the blocking questions in [Open questions](#open-questions) before implementing.  
**Target:** the standalone repository `ggeorgovassilis/dsh-docker` (not a fork of `deepseek-harness-docker`).  
**Goal:** a Docker image that runs DeepSeek Harness as an unauthenticated HTTP API (JSON-RPC over HTTP plus SSE events), with Prometheus metrics, configured entirely from `.env` and operated via `docker exec`, and a one-command DSH update flow.

[Acceptance criteria](#acceptance-criteria) is the completion contract.

### Requirement map

| Requirement | Where it is specified |
|---|---|
| Everything runs in Docker (build and DSH run) | [Container image](#container-image), [Shell scripts](#shell-scripts) |
| Configuration through `.env`, operation via `docker exec` | [Configuration](#configuration), [Security](#security) |
| Shell scripts to build, run, stop, smoke-test, and upgrade | [Shell scripts](#shell-scripts) |
| DSH exposed over HTTP, no authentication | [HTTP API](#http-api), [Security](#security) |
| Telemetry exposed over HTTP (Prometheus) | [Telemetry](#telemetry) |
| Easy DSH updates via version/tag configuration | [Versioning and upgrades](#versioning-and-upgrades) |

---

## Scope and non-goals

### In scope

- Build a container image containing:
  - the official `@deepseek-ai/dsh` npm package, pinned to an exact version;
  - a small HTTP bridge that exposes the DSH SDK runtime over HTTP;
  - Prometheus metrics over HTTP.
- Run the image with `docker run` or `docker compose`.
- Configure everything from one `.env` file; operate it with `.env` and `docker exec`.
- Build, run, stop, smoke-test, and upgrade with shell scripts.
- Expose DSH **without authentication**.

### Non-goals

- DSH Web UI, noVNC, Chromium, X11, Browser Use, plugin market, Super Agent.
- `gh`, `pnpm` plugin management, third-party DSH plugins.
- Multi-tenant authentication or authorization.
- Kubernetes manifests (the image must be Kubernetes-friendly, but manifests are out of scope).
- Reimplementing DSH or its SDK protocol.
- A web-based management interface. DSH ships one by default; we do not expose it. Configuration happens through `.env`, and anything `.env` does not cover is done with `docker exec`.

The security consequences of "no authentication" are documented once, in [Security](#security).

---

## Key decisions

| Decision | Choice | Rationale |
|---|---|---|
| DSH surface | `dsh --profile sdk` | The SDK is the API. It speaks newline-delimited JSON-RPC over stdio. |
| HTTP transport | `POST /v1/rpc` + `GET /v1/events` (SSE) | Simple, firewall-friendly, no WebSocket dependency. |
| Process model | one bridge + one DSH child per container | Simplest lifecycle and blast radius; scale with more containers. |
| Bridge | Node.js 24 ESM, Node's built-in `http` module | Same runtime as DSH; no second toolchain or extra framework dependency. |
| Initialization | bridge always auto-initializes | Clients can call `session/prompt` immediately; config comes from `.env`. |
| Config | flat `.env` dotenv file | Required by the project; keep it strict and shell-safe. |
| Management surface | `.env` + `docker exec`, no web UI | DSH's default web interface is a management surface we do not want to expose. |
| Telemetry | Prometheus `/metrics` on the API port | Pull metrics over HTTP; no OTLP push in v1. |
| DSH telemetry | disabled by default | Avoid sending product/session telemetry to DeepSeek. |
| Versioning | exact DSH version pinned in `package.json`; `.env` `IMAGE_TAG` defaults to it | Reproducible builds; one source of truth. |
| Auth | none, by requirement | Default bind is `127.0.0.1`; wide bind requires an explicit opt-in flag. |

### Important correction about "HTTP API"

`dsh --profile sdk` is **stdio JSON-RPC**, not HTTP. The bridge is therefore mandatory, not optional. Do not expose the DSH Web server as the API; it is a different surface and drags in the Web/browser stack.

---

## Architecture

```mermaid
flowchart LR
  client["API client"] -->|"POST /v1/rpc"| bridge["HTTP bridge<br/>(Node.js)"]
  client -->|"GET /v1/events (SSE)"| bridge
  bridge -->|"JSON-RPC lines"| dsh["dsh --profile sdk<br/>(child process)"]
  dsh -->|"notifications"| bridge
  bridge -->|"SSE"| client

  bridge -->|"/metrics"| prom["Prometheus scraper"]
  bridge -->|"JSON logs"| stdout["Container stdout/stderr"]

  workspace[("Workspace volume")] --- dsh
  home[("DSH home volume")] --- dsh
```

One HTTP listener on `HTTP_PORT` (default `3080`) serves `/v1/rpc`, `/v1/events`, `/v1/status`, `/healthz`, `/readyz`, and `/metrics`.

---

## Repository layout

```text
dsh-api-runtime/
├── .env.example
├── .gitignore
├── Dockerfile
├── package.json
├── package-lock.json
├── README.md
├── bridge/
│   ├── server.mjs        # HTTP listener, routing, SSE, lifecycle
│   ├── dsh.mjs           # spawn, framing, JSON-RPC, init, supervision
│   ├── telemetry.mjs     # Prometheus metrics + JSON logging
│   └── config.mjs        # env parsing/validation
├── scripts/
│   ├── lib.sh            # strict .env loader, validation helpers
│   ├── build.sh
│   ├── run.sh
│   ├── stop.sh
│   ├── smoke.sh
│   ├── verify.sh
│   └── update-dsh.sh
├── test/
│   ├── fake-dsh.mjs      # deterministic JSON-RPC fixture for CI
│   └── bridge.test.mjs
└── .github/workflows/
    ├── ci.yml
    └── update-dsh.yml
```

Host requirements: Linux (preferred), Bash 4+, Docker Engine 24+, Docker Buildx, and `git` (for revision labels). All Node/npm work happens in disposable containers.

---

## Configuration

### Contract

- `.env` is a flat, dotenv-style file: `KEY=VALUE`, one per line.
- Blank lines and lines starting with `#` are ignored.
- Values are **literal**. No shell expansion, no command substitution, no `eval`, no `source`.
- Surrounding single or double quotes are stripped.
- Duplicate keys are rejected.
- Keys must match `^[A-Z][A-Z0-9_]*$`.
- `.env` is git-ignored. `.env.example` is committed.
- `ENG_FILE=/path/to/file` overrides the default path (CI use).
- `scripts/lib.sh` refuses to proceed if `.env` is group/world-readable, unless `ALLOW_INSECURE_ENG=1` is set.

`package.json` is the single source of truth for the DSH version. `.env` does **not** carry a separate DSH version; `IMAGE_TAG` is the only tag knob and defaults to the pinned DSH version.

### `.env.example`

```dotenv
# Build
IMAGE_TAG=0.2.2-rc.3        # defaults to the pinned @deepseek-ai/dsh version
NODE_IMAGE=node:24-trixie
NODE_IMAGE_DIGEST=
RUNTIME_IMAGE=node:24-trixie-slim
RUNTIME_IMAGE_DIGEST=

# Runtime
CONTAINER_NAME=dsh-api
BIND_ADDRESS=127.0.0.1
HTTP_PORT=3080
ALLOW_UNAUTHENTICATED_EXPOSURE=0
DSH_HOME_VOLUME=dsh-api-home
WORKSPACE_HOST=/srv/dsh-workspace
WORKSPACE=/workspace
DSH_CWD=/workspace

# Provider/model (verified against @deepseek-ai/dsh 0.2.2-rc.3)
DSH_PROVIDER=deepseek-official
DSH_MODEL=deepseek-v4-flash
DSH_REASONING_EFFORT=
DSH_MAX_TOKENS=

# Model credentials. Never commit this file.
DEEPSEEK_API_KEY=replace-me

# Bridge behavior
INIT_TIMEOUT_MS=60000
RPC_TIMEOUT_MS=300000
MAX_INFLIGHT=16
MAX_BODY_BYTES=8388608
ENABLE_APPROVALS=0
ENABLE_USER_QUESTIONS=0

# Telemetry
LOG_LEVEL=info
DSH_TELEMETRY_MODE=DISABLED
```

### Required validation

`scripts/lib.sh` must fail with a clear message when:

- `.env` is missing or unreadable;
- required keys are missing;
- `IMAGE_TAG` is not a valid Docker tag (no `+` build metadata, no `/`);
- `NODE_IMAGE` or `RUNTIME_IMAGE` already contains an inline digest (`*_DIGEST` are the digest inputs);
- `BIND_ADDRESS` is non-loopback and `ALLOW_UNAUTHENTICATED_EXPOSURE != 1`;
- no model credential is available;
- `DSH_PROVIDER`, `DSH_MODEL`, or `DSH_CWD` is empty.

### Runtime environment

`run.sh` must not pass the whole `.env` file to Docker. Generate a temporary runtime env file containing only:

- `DEEPSEEK_API_KEY` and any provider credentials;
- `DSH_*`;
- `LOG_*`;
- `INIT_TIMEOUT_MS`, `RPC_TIMEOUT_MS`, `MAX_INFLIGHT`, `MAX_BODY_BYTES`, `ENABLE_APPROVALS`, `ENABLE_USER_QUESTIONS`;
- `WORKSPACE`, `DSH_CWD`.

Delete the temporary file on exit. Never print its contents.

---

## Container image

### Dockerfile shape

```dockerfile
# syntax=docker/dockerfile:1.7

# build.sh appends "@sha256:..." when a digest is set.
ARG NODE_IMAGE=node:24-trixie
ARG RUNTIME_IMAGE=node:24-trixie-slim
FROM ${NODE_IMAGE} AS deps

ARG DSH_VERSION
RUN apt-get update \
 && apt-get install --yes --no-install-recommends python3 make g++ \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY package.json package-lock.json ./
# Explicit lifecycle-script allowlist; do not blanket-allow all scripts.
RUN npm ci --omit=dev --ignore-scripts \
 && npm rebuild --foreground-scripts node-pty koffi @deepseek-ai/dsh-subprocess-local @google/genai protobufjs \
 && test "$(/app/node_modules/.bin/dsh --version)" = "$DSH_VERSION"

FROM ${RUNTIME_IMAGE}

RUN apt-get update \
 && apt-get install --yes --no-install-recommends \
      ca-certificates \
      git \
      openssh-client \
      ripgrep \
      tini \
      procps \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY package.json ./
COPY bridge ./bridge

# NODE_ENV is deliberately not set: agent-run commands inherit this
# environment, and NODE_ENV=production would change their install behaviour.
ENV HOME=/home/node \
    DSH_HOME=/home/node/.dsh \
    DSH_BIN=/app/node_modules/.bin/dsh \
    DSH_CWD=/workspace \
    DSH_TELEMETRY_MODE=DISABLED \
    NARB_DISABLE_NATIVE_CACHE=1 \
    DSH_CONTAINER=1 \
    HTTP_BIND=0.0.0.0 \
    HTTP_PORT=3080

# Chown only the writable directories. node_modules stays world-readable and
# the bridge never writes to /app, so a recursive chown of /app is avoided.
RUN mkdir -p /home/node/.dsh /workspace \
 && chown node:node /home/node/.dsh /workspace

USER node
WORKDIR /workspace
EXPOSE 3080

ARG DSH_VERSION
ARG IMAGE_VERSION=dev
ARG IMAGE_REVISION=unknown
LABEL org.opencontainers.image.title="DSH API Runtime" \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.revision="${IMAGE_REVISION}" \
      io.example.dsh.version="${DSH_VERSION}"

HEALTHCHECK --interval=30s --timeout=3s --start-period=20s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.HTTP_PORT||3080)+'/readyz').then(r => process.exit(r.ok ? 0 : 1)).catch(() => process.exit(1))"

ENTRYPOINT ["/usr/bin/tini", "--", "node", "/app/bridge/server.mjs"]
```

Notes:

- The `deps` stage is disposable; the runtime image must not contain a compiler.
- `package.json` pins `@deepseek-ai/dsh` exactly; `package-lock.json` is the authority for transitive versions.
- `package.json` also pins the Prometheus client/exporter used by `bridge/telemetry.mjs`.
- `build.sh` is responsible for appending image digests. Pass complete references (`node:24-trixie@sha256:...`) as `NODE_IMAGE` / `RUNTIME_IMAGE` build args; the `FROM` line must not compose digests itself.
- `@deepseek-ai/dsh` is installed as a project dependency, not globally, so the lockfile stays authoritative.
- `node-pty` is the main native dependency. Validate the rebuild allowlist against the DSH version you pin.
- Do not install `pnpm`, Chromium, X11, noVNC, Browser Use, or `gh`.
- The runtime image does **not** set `NODE_ENV=production`. The bridge inherits
  its environment into agent-run commands, and `production` would change their
  dependency-install behaviour.
- `HTTP_BIND=0.0.0.0` is set *inside* the image because Docker port publishing
  (`-p`) only reaches a container process that binds a non-loopback interface.
  Loopback enforcement therefore lives in `scripts/run.sh`/`scripts/lib.sh` on
  the host `BIND_ADDRESS`, not in the image. Running the image directly with a
  wide `-p` bypasses that guard.
- `DSH_CONTAINER=1` marks the process as running inside the image so the bridge
  downgrades its non-loopback warning; `NARB_DISABLE_NATIVE_CACHE=1` keeps DSH's
  native addon loader from copying `.node` files into the `noexec` `/tmp`.

### Build reproducibility

- Pin `NODE_IMAGE`/`RUNTIME_IMAGE` by digest for release builds.
- Commit `package-lock.json`.
- Build with BuildKit; add `--sbom=true --provenance=mode=max` for release builds.
- Optionally sign with cosign and scan with Trivy/Grype in CI.
- Do not publish a floating `latest` tag. Tag by exact DSH version, e.g. `dsh-api-runtime:0.2.2-rc.3`.

### Runtime security

Use these flags in `scripts/run.sh`:

```text
--read-only
--tmpfs /tmp:rw,noexec,nosuid,nodev,size=256m
--cap-drop ALL
--security-opt no-new-privileges:true
--pids-limit 512
--user 1000:1000
--stop-timeout 30
```

Mount only:

- `${DSH_HOME_VOLUME}:/home/node/.dsh`
- `${WORKSPACE_HOST}:${WORKSPACE}`

Do not mount the Docker socket. Do not run privileged. Do not use host networking.

---

## DSH child process

### Spawn

```text
dsh --profile sdk
```

- Executable: `DSH_BIN`, default `/app/node_modules/.bin/dsh`. The smoke test overrides it with a fixture.
- `cwd`: `DSH_CWD` (normally `/workspace`).
- `HOME`: `/home/node`; `DSH_HOME`: `/home/node/.dsh`.
- Read `dsh --version` once at startup for `/v1/status`.
- `DSH_TELEMETRY_MODE`: `DISABLED` unless explicitly overridden.
- `NO_COLOR=1`, `TERM=dumb`.
- Pass model credentials through the environment.
- `stdio`: pipe stdin/stdout/stderr.

### Framing

- One JSON-RPC message per `\n`-terminated line.
- Read stdout with `readline`.
- Ignore malformed lines but log them at `warn` with a bounded preview.
- Write `JSON.stringify(message) + "\n"` to stdin.
- Honor stdin backpressure.
- Consume stderr continuously and forward it to the container's stderr with a `[dsh]` prefix. Never let a pipe fill and deadlock the child.

### Initialization

The bridge always auto-initializes on child start:

```json
{
  "jsonrpc": "2.0",
  "id": "bridge-init-<uuid>",
  "method": "initialize",
  "params": {
    "cwd": "/workspace",
    "provider": "deepseek-official",
    "model": "deepseek-v4-flash",
    "approvalRequests": false,
    "capabilities": { "userQuestions": false }
  }
}
```

- `reasoningEffort` and `maxTokens` are included only when set in `.env`.
- `approvalRequests` is `true` only when `ENABLE_APPROVALS=1`.
- `capabilities.userQuestions` is `true` only when `ENABLE_USER_QUESTIONS=1`.
- `/readyz` returns `200` only after a successful `initialize` response.
- If initialization fails, log the JSON-RPC error and exit nonzero. Do not serve a half-configured runtime.

The bridge's `initialize` is process-wide. Do not also accept a client `initialize`; DSH will reject the second handshake. For per-request model selection, use one container per model.

### Supervision

- `tini` is PID 1; the bridge is PID 2; DSH is a child of the bridge.
- On child exit:
  - reject all pending RPCs with a JSON-RPC error;
  - mark `/readyz` unavailable;
  - restart with exponential backoff: 1s, 2s, 4s, 8s, capped at 30s;
  - re-run initialization;
  - after 10 restarts in 5 minutes, exit nonzero so the orchestrator restarts the container.
- On `SIGTERM`/`SIGINT`:
  - stop accepting new HTTP requests;
  - send the DSH `shutdown` request;
  - wait up to 10s for exit;
  - `SIGTERM` the child, wait 5s, then `SIGKILL`;
  - close SSE clients and exit 0.

---

## HTTP API

### Endpoints

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/v1/rpc` | Send one JSON-RPC request, notification, or response. |
| `GET` | `/v1/events` | SSE stream of DSH notifications. |
| `GET` | `/v1/status` | Non-secret runtime status. |
| `GET` | `/healthz` | Process liveness. |
| `GET` | `/readyz` | DSH child ready for traffic. |
| `GET` | `/metrics` | Prometheus metrics. |

No authentication. No CORS by default. Add `CORS_ORIGIN` only if a browser client requires it.

### `POST /v1/rpc`

Request body: one JSON object, `Content-Type: application/json`, max `MAX_BODY_BYTES`.

Accepted shapes:

1. **JSON-RPC request** — `jsonrpc`, `id`, `method`, optional `params`.
   - Forward to DSH.
   - Wait for the matching response, up to `RPC_TIMEOUT_MS`.
   - Return the DSH response object with HTTP `200`, even when it is a JSON-RPC error.
2. **JSON-RPC notification** — `jsonrpc`, `method`, no `id`.
   - Forward to DSH.
   - Return HTTP `202` with an empty body.
3. **JSON-RPC response** — `jsonrpc`, `id`, exactly one of `result` or `error`.
   - Forward to DSH, used only when server-to-client requests are enabled.
   - Return HTTP `202`.

Reject batch arrays with `400`.

Error mapping:

| Condition | HTTP | JSON-RPC error |
|---|---:|---|
| Malformed JSON | 400 | `-32700` Parse error |
| Invalid JSON-RPC shape | 400 | `-32600` Invalid Request |
| Body too large | 413 | `-32600` |
| DSH not ready | 503 | `-32000` DSH unavailable |
| Too many in-flight requests | 429 | `-32002` Busy |
| RPC timeout | 504 | `-32001` DSH timeout |
| Bridge internal failure | 500 | `-32603` Internal error |

Example:

```bash
curl -sS http://127.0.0.1:3080/v1/rpc \
  -H 'content-type: application/json' \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "session/prompt",
    "params": {
      "sessionId": "demo",
      "contentBlocks": [{ "type": "text", "text": "List the files in /workspace" }]
    }
  }'
```

`session/prompt` returns only an enqueue receipt, for example:

```json
{"jsonrpc":"2.0","id":1,"result":{"messageId":"..."}}
```

It does **not** return the model's final answer. Clients must consume `/v1/events` and/or call `session/wait`.

> **Timeouts do not cancel work.** DSH has no cancel method. If an HTTP request times out, the underlying agent work may continue; a `504` means the bridge stopped waiting, not that the run stopped. Use `session/wait` with a generous timeout, or watch `/v1/events` for `session.status: idle`. Do not blindly retry a prompt after a timeout unless you can tolerate duplicate work.

Wait for the session to become idle:

```bash
curl -sS http://127.0.0.1:3080/v1/rpc \
  -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":2,"method":"session/wait","params":{"sessionId":"demo"}}'
```

### `GET /v1/events`

Server-Sent Events stream:

```bash
curl -N http://127.0.0.1:3080/v1/events
```

```text
id: 42
event: rpc
data: {"jsonrpc":"2.0","method":"session.event","params":{"sessionId":"demo","event":{...}}}

```

- Every DSH notification is forwarded verbatim.
- The SSE event name is `rpc`. Browser `EventSource` clients must register `addEventListener("rpc", ...)`; `onmessage` only receives `message` events.
- `id:` is a monotonically increasing sequence number.
- Keepalive comment every 15s:
  ```text
  : ping
  ```
- Optional `?sessionId=` filter. Filtering is best-effort; `subagent.*` notifications may reference multiple sessions.
- Do not buffer unbounded history. If a slow client falls behind, close it rather than growing memory without bound.
- Set `Cache-Control: no-cache`, `Connection: keep-alive`, and `X-Accel-Buffering: no`.

Typical client sequence:

1. Open `GET /v1/events`.
2. `POST /v1/rpc` with `session/prompt`.
3. Read `session.event` notifications.
4. Wait for `session.status` with `"status":"idle"` or call `session/wait`.
5. Close the stream.

### `GET /v1/status`

Return non-secret state:

```json
{
  "ready": true,
  "dshVersion": "0.2.2-rc.3",
  "serverInfo": { "name": "deepseek-harness-sdk-runtime", "version": "0.0.1" },
  "pid": 123,
  "uptimeMs": 45678,
  "inflight": 1,
  "sseClients": 2,
  "lastExit": null,
  "config": { "provider": "deepseek-official", "model": "deepseek-v4-flash", "cwd": "/workspace" }
}
```

Never include credentials or prompt content.

### JSON-RPC ID handling

- The bridge keys pending requests by `typeof id + ":" + String(id)` to avoid `1` vs `"1"` collisions.
- Reject a client request whose ID is already in flight with HTTP `409` and error `-32600`.
- Preserve the original `id` value in the response.
- Do not reuse bridge-internal IDs for client requests. Bridge IDs use the prefix `bridge-`.

### Concurrency and limits

- At most `MAX_INFLIGHT` client requests waiting on DSH.
- Notifications do not count toward the limit.
- Enforce `MAX_BODY_BYTES`.
- Set socket timeouts to avoid slowloris.
- Do not buffer unbounded response bodies.

---

## Telemetry

### What "exposes telemetry via HTTP" means here

Prometheus pull metrics on the API port. No OTLP push in v1.

The bridge instruments its own HTTP/RPC boundary and process lifecycle. It can derive session-level counters/events from DSH notifications (`session.status`, `subagent.*`, `session.query.completed`). It does **not** scrape DSH internals. Token/cost metrics are available only if the notification payloads actually expose usage; do not promise them blindly.

### Metrics

Required metrics:

| Metric | Type | Labels |
|---|---|---|
| `dsh_bridge_http_requests_total` | counter | `method`, `route`, `status` |
| `dsh_bridge_http_request_duration_seconds` | histogram | `method`, `route` |
| `dsh_bridge_rpc_requests_total` | counter | `method`, `status` |
| `dsh_bridge_rpc_request_duration_seconds` | histogram | `method` |
| `dsh_bridge_rpc_inflight` | gauge | — |
| `dsh_bridge_sse_clients` | gauge | — |
| `dsh_bridge_events_total` | counter | `method` |
| `dsh_bridge_dsh_up` | gauge | — |
| `dsh_bridge_dsh_restarts_total` | counter | — |
| `dsh_bridge_process_resident_memory_bytes` | gauge | — |

Do **not** use session IDs, request IDs, or raw URL paths as metric labels: they are unbounded and can leak tenant identifiers. Use templated routes such as `/v1/rpc`, `/v1/events`, and `/v1/status`.

### Logs

- JSON lines to stdout/stderr.
- Include `ts`, `level`, `msg`, `request_id`, `rpc_id`, `method`, `session_id`, `duration_ms`, `status`.
- Never log API keys, authorization headers, prompt content, or tool output.
- Forward DSH stderr with a `[dsh]` prefix.

### DSH's own telemetry

- Set `DSH_TELEMETRY_MODE=DISABLED` by default.
- DSH's native product/session telemetry is separate from this bridge and may send data to DeepSeek. Enabling it is an explicit operator decision; review upstream documentation first.
- Do not conflate DSH's `serverInfo.version` (`0.0.1`, the wire protocol identity) with the DSH package version.

---

## Shell scripts

The scripts are thin wrappers over Docker; behavior is specified here rather than full code.

### `scripts/lib.sh`

- `load_eng` — strict parser described in [Configuration](#configuration).
- `require_cmd` — check `docker` and `docker buildx`.
- `die`, `warn`, `info`.
- `is_loopback` — validate `BIND_ADDRESS`.
- `runtime_env_file` — generate the filtered temp env file.
- `require_image` — check the image exists.

### `scripts/build.sh`

- Load and validate `.env`.
- Read the pinned DSH version from `package.json` and pass it as the `DSH_VERSION` build arg.
- Compose base image references from `NODE_IMAGE`/`RUNTIME_IMAGE` and their digests.
- Build with BuildKit, passing `IMAGE_VERSION` and `IMAGE_REVISION` alongside.
- Tag `${IMAGE_REPOSITORY}:${IMAGE_TAG}`.
- Default `IMAGE_TAG` to the pinned DSH version when empty.
- Fail if `package-lock.json` is missing or inconsistent.
- Add `--sbom=true --provenance=mode=max` for release builds.
- Verify the result with `docker run --rm --entrypoint /app/node_modules/.bin/dsh <image> --version`.
- Do not tag `latest` automatically.

### `scripts/run.sh`

- Load and validate `.env`.
- Build if the image is missing, unless `--no-build`.
- Create the DSH home volume if missing.
- Generate the filtered runtime env file.
- Run the container with the flags from [Runtime security](#runtime-security), mapping `HTTP_PORT` to container port `3080`, mounting the two volumes, and passing the filtered env file.
- Default: foreground plus `--rm`, so `Ctrl-C` stops and removes it.
- `-d`: detached with `--restart unless-stopped` **and without `--rm`** (`docker run` rejects combining them).
- Add `--memory`/`--cpus` limits appropriate for the host.
- Print the API base URL and a note that there is no authentication.
- Refuse a non-loopback `BIND_ADDRESS` unless `ALLOW_UNAUTHENTICATED_EXPOSURE=1`.
- If `WORKSPACE_HOST` is owned by a UID other than 1000, tell the operator to fix ownership or pass `--user`.

### `scripts/stop.sh`

- `docker stop "$CONTAINER_NAME"`; do not delete volumes.

### `scripts/smoke.sh`

Two layers:

1. **Fake-DSH integration test (always runs in CI).**
   - Mount the fixture read-only and point the bridge at it with `-v "$PWD/test:/test:ro" -e DSH_BIN=/test/fake-dsh.mjs`.
   - The fixture responds to `initialize`, `session/prompt`, `session/wait`, and `shutdown`, and emits `session.status` / `session.event`.
   - Assert:
     - `/readyz` becomes 200;
     - `POST /v1/rpc` initialize/prompt works;
     - SSE receives the expected notification;
     - `/metrics` contains the required metric names.
2. **Live smoke (opt-in, costs model credits).**
   - Require `RUN_LIVE_SMOKE=1` and a configured key.
   - Send a prompt such as "Reply with the single word OK".
   - Wait for idle, assert a non-empty assistant result, then stop.

`DSH_BIN` must be configurable so tests never need a real model.

### `scripts/update-dsh.sh`

```bash
scripts/update-dsh.sh next
scripts/update-dsh.sh latest
scripts/update-dsh.sh 0.2.2-rc.3
```

Steps:

1. Resolve the requested channel to an exact version with `npm view "@deepseek-ai/dsh@${channel}" version` in a disposable Node container.
2. Refuse to continue if the version is unchanged.
3. Update `package.json`'s exact `@deepseek-ai/dsh` dependency and `.env` `IMAGE_TAG`.
4. Regenerate `package-lock.json` in a disposable Node container: `npm install --package-lock-only --ignore-scripts`.
5. Run `scripts/build.sh` and `scripts/smoke.sh`.
6. Print the diff and the rollback tag. Do **not** auto-commit.
7. In CI, open a PR with the version, lockfile, and test result.

### `scripts/verify.sh`

Assert:

- `package.json`'s pinned DSH version == built image `dsh --version` == image label.
- `package-lock.json` exists and is consistent (`npm ci --dry-run` in a container).
- No `latest` tag is produced.

---

## Versioning and upgrades

- The DSH version is pinned exactly in `package.json`. `.env` `IMAGE_TAG` defaults to it and is the only tag knob.
- `scripts/update-dsh.sh` takes a channel (`next`, `latest`, `alpha`) or an exact version; default to `next` because DSH is a prerelease and `latest` can lag.
- Keep at least the previous image tag for rollback.
- Back up the `DSH_HOME` volume before an upgrade. DSH session storage can change between prereleases.
- After an upgrade:
  1. run the fake-DSH smoke test;
  2. run the live smoke test if credentials are available;
  3. verify `/v1/status` reports the new DSH version;
  4. check that the SDK protocol still exposes the methods you depend on.
- Add a scheduled CI job (daily or weekly) that runs `scripts/update-dsh.sh` in a branch and opens a PR when a new version exists.

---

## Security

### No authentication

This is a deliberate requirement and the largest risk:

- Anyone with network access can execute agent tools in the workspace.
- Anyone with network access can consume model credits.
- There is no per-user isolation inside one container.

Mitigations:

- Default `BIND_ADDRESS=127.0.0.1`.
- Refuse `0.0.0.0`/`::` unless `ALLOW_UNAUTHENTICATED_EXPOSURE=1`.
- Document that a reverse proxy with auth, mTLS, or a private network is mandatory for remote access.
- Apply CPU/memory/pids limits at the container runtime.
- Use a dedicated workspace volume, not a broad host mount.
- Consider gVisor/Kata/Firecracker if the workload is untrusted.
- The metrics endpoint is unauthenticated too. Expose `/metrics` only to trusted scrapers or a private monitoring network.

### Secrets

- `.env` contains model credentials. Mode `0600`, git-ignored, never baked into the image.
- `docker inspect` exposes environment variables to anyone with Docker access; restrict Docker access.
- Never log credentials or request headers.
- Rotate keys if `.env` is leaked.

### Supply chain

- Pin base images by digest.
- Commit `package-lock.json`; build with `npm ci`.
- Use an explicit lifecycle-script allowlist.
- Run `npm audit signatures` in CI. Registry signatures prove the tarball matches what npm signed; they do not prove publisher intent. Treat the DeepSeek npm publisher account as a trust anchor.
- Generate an SBOM and provenance; sign the image.
- Scan the image before publishing.
- Pin CI actions by SHA.
- Prefer vendoring the DSH tarball into your own artifact store if registry availability is a concern.

---

## Testing and CI

### Test layers

1. **Unit tests** — `.env` parser, JSON-RPC shape validation and error mapping, pending-ID collision handling, SSE framing.
2. **Integration tests with fake DSH** — deterministic; covers startup, auto-init, RPC, SSE, metrics, shutdown, and restart.
3. **Live smoke (optional)** — requires credentials; run manually or in a protected CI job.
4. **Container tests** — non-root UID, read-only root filesystem, `/readyz` behavior, `/metrics` presence, image label/version assertions.

### CI workflow

On pull request:

- `npm ci` / lockfile check.
- Unit + fake-DSH integration tests.
- `scripts/build.sh`.
- Trivy/Grype scan.
- Verify non-root/read-only flags in the run script.
- `actionlint`/shellcheck (recommended).

On tag/release:

- `docker buildx build --platform linux/amd64,linux/arm64`.
- `--sbom=true --provenance=mode=max`.
- cosign sign.
- Push to the registry.
- Keep the previous tag.

### Scheduled update workflow

- Run daily/weekly.
- Resolve the latest configured channel.
- If changed, run `scripts/update-dsh.sh`, build, fake smoke.
- Open a PR. Do not auto-merge.

---

## Acceptance criteria

The implementation is done when all of the following are true:

- [ ] `scripts/build.sh` builds a multi-stage image from a clean checkout without host Node.js.
- [ ] `scripts/run.sh` starts the container using only `.env`; no secrets are baked into the image.
- [ ] The API listens on `HTTP_PORT`; `/metrics` is served on the same port.
- [ ] `POST /v1/rpc` with `session/prompt` returns an enqueue receipt.
- [ ] `GET /v1/events` streams `session.event` and `session.status` notifications.
- [ ] `GET /readyz` returns 200 only after a successful auto-initialize.
- [ ] `GET /metrics` returns the required Prometheus metrics.
- [ ] `DSH_TELEMETRY_MODE=DISABLED` is the default.
- [ ] The container runs as non-root, with a read-only root, dropped capabilities, and no Docker socket.
- [ ] `scripts/update-dsh.sh next` updates `package.json`, `package-lock.json`, and `.env`, then builds and passes the fake smoke test.
- [ ] `dsh --version` and the image label match the pinned `package.json` version.
- [ ] No `latest` tag is published automatically.
- [ ] A live smoke test succeeds with a real model when explicitly enabled.
- [ ] `README.md` documents the no-auth risk, default loopback bind, rollback, and volume backup.

---

## Open questions

Resolved during implementation:

1. `dsh --profile sdk` is the SDK surface used. The wire protocol
   (`initialize`, `session/prompt`, `session/wait`, notifications) is exercised
   by the fake-DSH fixture in CI; a live `initialize` and `session/prompt`
   remain to be confirmed by the opt-in live smoke test.
2. Provider/model identifiers are `DSH_PROVIDER=deepseek-official` and
   `DSH_MODEL=deepseek-v4-flash`; the credential env var is
   `DEEPSEEK_API_KEY`.

Still open:

3. Do clients need server-to-client approvals or user questions?
4. Is POST + SSE acceptable, or must browser clients use WebSocket?
5. Should the workspace be a host bind mount or a named volume?
6. Which network/CIDR may reach the unauthenticated API, and who owns the reverse proxy or network policy?

---

## Reference points

Useful examples in the existing `deepseek-harness-docker` repository (do not copy wholesale): its `Dockerfile`, `compose.yaml`, `scripts/smoke.sh`, and `scripts/check-version-consistency.sh`.

Do **not** carry over the Web/desktop, Chromium, noVNC, Browser Use, market, Super Agent, or third-party browser plugin parts. They are unrelated to this service.
