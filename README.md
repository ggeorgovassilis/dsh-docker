# DSH in Docker

This project does one thing: it packages [DeepSeek Harness](https://www.npmjs.com/package/@deepseek-ai/dsh) (DSH) into a Docker container and exposes it as an HTTP API.

It does not add features, change DSH's behaviour, or provide any kind of interface beyond the API.

## Why

DSH is normally run directly on your machine. Running it inside a container instead:

- **Isolates** DSH and the files it works with from your host system.
- **Limits the damage** if DSH, or the code it runs, misbehaves. The container runs as an unprivileged user, with a read-only filesystem and no access to your host.
- **Keeps your setup clean** — no Node.js, no npm packages, and no dependencies installed on the host.

## What it is not

- There is **no web interface**. This is API-only.
- There is **no authentication** (by design — see [Security](#security)).

## Requirements

- A Linux host with Docker installed.
- A DeepSeek API key.

## Quick start

```bash
# 1. Get the code
git clone https://github.com/ggeorgovassilis/dsh-docker
cd dsh-docker

# 2. Configure it
cp .env.example .env
chmod 600 .env
$EDITOR .env        # set DEEPSEEK_API_KEY and WORKSPACE_HOST

# 3. Build the image
scripts/build.sh

# 4. Run it
scripts/run.sh -d
```

When it is running, the API is at `http://127.0.0.1:3080`.

## Configuration

Everything is set in the `.env` file. The only two settings you must provide are:

| Setting | What it is |
|---|---|
| `DEEPSEEK_API_KEY` | Your DeepSeek API key. |
| `WORKSPACE_HOST` | A folder on your host where DSH reads and writes files. Create it first, e.g. `mkdir -p /srv/dsh-workspace`. |

Everything else has a sensible default. The settings you are most likely to change:

| Setting | Default | What it is |
|---|---|---|
| `HTTP_PORT` | `3080` | The port the API listens on. |
| `BIND_ADDRESS` | `127.0.0.1` | Which host address the API is reachable on. Keep it on loopback unless you know what you are doing. |
| `DSH_MODEL` | `deepseek-v4-flash` | The model DSH uses. |
| `MEMORY_LIMIT` / `CPU_LIMIT` | `2g` / `2` | How much memory and CPU the container may use. |

## Using the API

The API accepts JSON-RPC requests. Send a prompt with `curl`:

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

This returns an acknowledgement immediately. The model's answer is delivered
afterwards, as a stream of events. Watch them with:

```bash
curl -N http://127.0.0.1:3080/v1/events
```

A few useful endpoints:

| Endpoint | What it is |
|---|---|
| `POST /v1/rpc` | Send a request to DSH. |
| `GET /v1/events` | Watch DSH's events (including answers) in real time. |
| `GET /v1/status` | See whether DSH is running and what model it uses. |
| `GET /healthz` | Is the container alive? |
| `GET /readyz` | Is DSH ready to take requests? |

## Managing the container

```bash
scripts/stop.sh        # stop it (your data is kept)
scripts/run.sh -d      # start it again
docker logs -f dsh     # read its logs
```

The container is always named `dsh`. (Docker itself stores names with a
leading slash, so `docker inspect -f '{{.Name}}'` shows `/dsh`; that is normal.)

## Updating DSH

```bash
scripts/update-dsh.sh next
```

This updates to the newest DSH version, rebuilds the image, and runs a basic
self-test. It does not commit anything; review the changes it prints before
committing them.

To roll back, keep the previous image around and re-run it with the previous
`IMAGE_TAG` in `.env`.

## Security

> **This API has no authentication.** Anyone who can reach it can run DSH
> (which can execute commands in the workspace) and spend your API credits.

The default `BIND_ADDRESS=127.0.0.1` keeps it reachable only from your own
machine. If you expose it beyond that, put it behind a firewall or an
authenticating proxy first.

## Where DSH keeps its data

Two folders matter:

- `WORKSPACE_HOST` — the folder DSH works in (mounted from your host).
- A Docker volume (`DSH_HOME_VOLUME`, default `dsh-api-home`) — DSH's own
  state, kept between restarts.

`scripts/stop.sh` never deletes either of them.

## License

MIT.
