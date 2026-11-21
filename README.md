# DSH in Docker

This project packages [DeepSeek Harness](https://www.npmjs.com/package/@deepseek-ai/dsh) (DSH) into a Docker container and exposes its two official interfaces:

- **The JSON-RPC API** — for scripts and other programs.
- **The web UI** — DSH's built-in browser interface (and clients like JaboDSH).

It runs the official `@deepseek-ai/dsh` package unchanged; it does not add features or modify DSH's behaviour.

## Why

DSH is normally run directly on your machine. Running it inside a container instead:

- **Isolates** DSH and the files it works with from your host system.
- **Limits the damage** if DSH, or the code it runs, misbehaves. The container runs as an unprivileged user, with a read-only filesystem and no access to your host.
- **Keeps your setup clean** — no Node.js, no npm packages, and no dependencies installed on the host.

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

When it is running:

- API: `http://127.0.0.1:3080`
- Web UI: `http://127.0.0.1:8080` (see [Using the web UI](#using-the-web-ui))

## Configuration

Everything is set in the `.env` file. The only two settings you must provide are:

| Setting | What it is |
|---|---|
| `DEEPSEEK_API_KEY` | Your DeepSeek API key. |
| `WORKSPACE_HOST` | A folder on your host where DSH reads and writes files. Create it first, e.g. `mkdir -p /srv/dsh-workspace`. |

Everything else has a sensible default. The settings you are most likely to change:

| Setting | Default | What it is |
|---|---|---|
| `HTTP_PORT` | `3080` | The port the JSON-RPC API is reachable on. |
| `WEB_PORT` | `8080` | The port the web UI is reachable on. |
| `BIND_ADDRESS` | `127.0.0.1` | Which host address the container is reachable on. Keep it on loopback unless you know what you are doing. |
| `DSH_MODEL` | `deepseek-v4-flash` | The model DSH uses. |
| `MEMORY_LIMIT` / `CPU_LIMIT` | `2g` / `2` | How much memory and CPU the container may use. |
| `PROJECTS_PATH` | empty | A folder of projects to mount at the same absolute path inside the container. See [Working on your own projects](#working-on-your-own-projects). |

## Working on your own projects

DSH's web UI organises work into **workspaces**, and every workspace is a
folder. One DSH container can host as many workspaces as you like, so you do
not need one container per project.

Point `PROJECTS_PATH` at the folder that contains your projects:

```dotenv
PROJECTS_PATH=/home/you/workspace
```

The folder is mounted into the container at **the same absolute path**. That
matters: a workspace DSH records as `/home/you/workspace/my-app` is also
`/home/you/workspace/my-app` on your host, so the same paths work in both
places, including in clients that send host paths to DSH.

Then create a workspace in the web UI (or open one) at any folder under that
path, for example `/home/you/workspace/my-app`. `DSH_CWD` only sets the
default directory for new sessions; it does not limit which workspaces you
can use.

Notes:

- Leave `PROJECTS_PATH` empty to skip the extra mount.
- The container runs as UID 1000. If your files belong to another user, the
  agent cannot write to them; use a folder owned by UID 1000 (or change the
  `--user` value in `scripts/run.sh`).
- The mount is read/write: that is what lets DSH edit your code.

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

## Using the web UI

The web UI is protected by a launch token. Find it in the logs:

```bash
docker logs dsh | grep 'dsh web:'
# dsh web: http://127.0.0.1:8081/?token=abc123…
```

Then open the web UI with that token:

```
http://127.0.0.1:8080/?token=abc123…
```

(The address shown in the logs is DSH's internal loopback address; use your
own `WEB_PORT` instead.) The token changes every time the container starts.

### Connecting JaboDSH (VS Code)

JaboDSH is a VS Code client for DSH. To connect it:

1. In JaboDSH, set the connection mode to `custom` and the server URL to
   `http://127.0.0.1:8080` (or your `WEB_PORT`).
2. Run **Authorize External Connection** and paste the launch token from the
   `dsh web:` log line.

## Managing the container

```bash
scripts/stop.sh        # stop and remove it (your data is kept)
scripts/run.sh -d      # start it again
docker logs -f dsh     # read its logs
```

The container is always named `dsh`.

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

> **The JSON-RPC API has no authentication.** Anyone who can reach it can run
> DSH (which can execute commands in the workspace) and spend your API credits.

The web UI is protected by its launch token, but it is still a full management
surface (file browsing, terminal, approvals). The default `BIND_ADDRESS=127.0.0.1`
keeps both reachable only from your own machine. If you expose them beyond that,
put them behind a firewall or an authenticating proxy first.

## Where DSH keeps its data

Two folders matter:

- `WORKSPACE_HOST` — the folder DSH works in (mounted from your host).
- A Docker volume (`DSH_HOME_VOLUME`, default `dsh-api-home`) — DSH's own
  state, kept between restarts. The web UI and the API share it.

`scripts/stop.sh` removes the container; it never deletes your workspace
folder or the DSH home volume.

## License

MIT.
