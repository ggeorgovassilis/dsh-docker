# DSH in Docker

This project packages [DeepSeek Harness](https://www.npmjs.com/package/@deepseek-ai/dsh) (DSH) into a Docker container and exposes its two official interfaces:

- **The JSON-RPC API** — for scripts and other programs.
- **The web UI** — DSH's built-in browser interface (and clients like JaboDSH).

It runs the official `@deepseek-ai/dsh` package unchanged; it does not add features or modify DSH's behaviour.

## Why

DSH is normally run directly on your machine. Running it inside a container instead:

- **Isolates** DSH and the files it works with from your host system.
- **Limits the damage** if DSH, or the code it runs, misbehaves. The container runs as an unprivileged user, with a read-only filesystem and no access to your host — except the Docker socket, which is mounted on purpose (see [Docker access](#docker-access)).
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

When it is running (reachable from other machines too, because
`BIND_ADDRESS` defaults to `0.0.0.0`):

- API: `http://<this-host>:3080`
- Web UI: `http://<this-host>:8080` (see [Using the web UI](#using-the-web-ui))

## Configuration

Everything is set in the `.env` file. The whole file is handed to the container
(`docker run --env-file`), so every variable in it becomes an environment
variable inside the container and in the commands the agent runs. The only two
settings you must provide are:

| Setting | What it is |
|---|---|
| `DEEPSEEK_API_KEY` | Your DeepSeek API key. |
| `WORKSPACE_HOST` | A folder on your host where DSH reads and writes files. Create it first, e.g. `mkdir -p /srv/dsh-workspace`. |

Everything else has a sensible default. The settings you are most likely to change:

| Setting | Default | What it is |
|---|---|---|
| `HTTP_PORT` | `3080` | The port the JSON-RPC API is reachable on. |
| `WEB_PORT` | `8080` | The port the web UI is reachable on. |
| `BIND_ADDRESS` | `0.0.0.0` | Which host address the container is reachable on. `0.0.0.0` publishes on every interface; use `127.0.0.1` to keep it local. |
| `DSH_MODEL` | `deepseek-v4-flash` | The model DSH uses. |
| `MEMORY_LIMIT` / `CPU_LIMIT` | `12g` / `2` | How much memory and CPU the container may use. Running a session costs about 700 MB before any work; raise `MEMORY_LIMIT` if it gets killed (see [Troubleshooting](#troubleshooting)). |
| `PROJECTS_PATH` | empty | A folder of projects to mount at the same absolute path inside the container. See [Working on your own projects](#working-on-your-own-projects). |
| `DOCKER_SOCKET` | `/var/run/docker.sock` | The host Docker socket mounted into the container. See [Docker access](#docker-access). |

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

## Installed tools

The image ships the usual development and delivery tooling, so the agent does
not have to install anything on the host:

| Tool | What it is |
|---|---|
| `node`, `npm`, `npx` | Node.js 24 runtime and package manager (the base image DSH runs on). |
| `pnpm` | Fast package manager, pinned in the [Dockerfile](Dockerfile) via `PNPM_VERSION`. |
| `git` | Version control, with `openssh-client` for SSH remotes. |
| `gh` | GitHub's official CLI. |
| `docker` | Docker CLI, with the `buildx` plugin. Talks to the host daemon (see [Docker access](#docker-access)). |
| `rg`, `ps`, `tini` | ripgrep for searching, `ps` for process inspection, `tini` as PID 1. |

Check them from the host:

```bash
docker exec dsh sh -c 'node --version; pnpm --version; git --version; gh --version | head -1; docker --version'
```

Every tool keeps its config, cache and state in the writable DSH home volume
(`/home/node/.dsh`): `DOCKER_CONFIG`, `XDG_CONFIG_HOME`, `XDG_DATA_HOME`,
`XDG_CACHE_HOME`, `PNPM_HOME` (and the pnpm store) and `GIT_CONFIG_GLOBAL`. That
makes them work despite the read-only root filesystem, and their settings
survive restarts.

### Docker access

The host Docker socket is mounted at `/var/run/docker.sock`, so DSH runs
`docker` commands against your host's daemon:

```bash
docker ps
docker build -t my-app .
```

`scripts/run.sh` adds the socket's group to the container user, so commands work
as UID 1000 without running as root. Point `DOCKER_SOCKET` at another path if
your daemon listens elsewhere (for example a rootless socket).

> **Warning:** access to the Docker socket is equivalent to root access on the
> host. Code running in this container can start privileged containers and
> mount host directories. Only give the socket to containers you trust, and see
> [Security](#security).

### GitHub and git credentials

`gh` and `git` are installed but not authenticated. Either log in inside the
container:

```bash
docker exec -it dsh gh auth login
docker exec -it dsh gh auth setup-git   # lets git push use the gh token
```

or set `GH_TOKEN` in `.env` (it is passed to the container like every other
`.env` setting). Either way the credentials are written under `/home/node/.dsh`
(the DSH home volume), so they survive restarts.

Confirm that the token reached the container without printing it:

```bash
docker exec dsh sh -c 'test -n "$GH_TOKEN" && echo "GH_TOKEN is set"'
docker exec dsh gh auth status
```

### Installing more tools

There is no `curl`, `wget`, `python3` or `jq` in the image, and the root
filesystem is read-only, so `apt-get install` does not work at runtime. Add
packages to the [Dockerfile](Dockerfile) and rebuild with `scripts/build.sh`.

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
surface (file browsing, terminal, approvals).

`BIND_ADDRESS=0.0.0.0` publishes both on every host interface, so any machine
that can reach this host can use them. If that is not what you want, set
`BIND_ADDRESS=127.0.0.1` in `.env`; otherwise put the host behind a firewall
or an authenticating reverse proxy.

The mounted Docker socket also weakens the container boundary: anything that
can make DSH run commands can control the host Docker daemon, which is
effectively root on the host. If you do not need Docker inside the container,
remove the socket mount from `scripts/run.sh`.

## Troubleshooting

**A process was killed and the logs stop abruptly.** A `SIGKILL` with no stack
trace or error is almost always the kernel OOM killer: the container went over
`MEMORY_LIMIT`. The supervisor now says so explicitly:

```json
{"level":"error","msg":"supervised process killed by the out-of-memory killer","name":"dsh-web","signal":"SIGKILL","oomKilled":true,"memory":{"maxBytes":12884901888,"peakBytes":12884901880,"oomKills":1},"hint":"raise MEMORY_LIMIT in .env and run scripts/run.sh -d"}
```

An idle container uses around 700 MB (`docker stats dsh`); a busy session can
use much more. Raise `MEMORY_LIMIT` in `.env` and restart with
`scripts/run.sh -d`.

To confirm it was the container's own limit rather than host-wide memory
pressure, check the kernel log on the host:

```bash
journalctl -k | grep -i 'memory cgroup out of memory'
```

The cgroup usage shown inside the container is the same data the kernel used:

```bash
docker exec dsh sh -c 'cat /sys/fs/cgroup/memory.peak /sys/fs/cgroup/memory.events'
```

**The container exits as soon as a session starts.** Look for `signal:
SIGTERM` from `supervised process exited`: something stopped the process, for
example `docker stop` or a crash on startup. The first error line names the
process.

**The web UI token changed.** The token is regenerated on every start; read the
current one with `docker logs dsh | grep 'dsh web:'`.

## Where DSH keeps its data

Two folders matter:

- `WORKSPACE_HOST` — the folder DSH works in (mounted from your host).
- A Docker volume (`DSH_HOME_VOLUME`, default `dsh-api-home`) — DSH's own
  state, kept between restarts. The web UI and the API share it.

`scripts/stop.sh` removes the container; it never deletes your workspace
folder or the DSH home volume.

## License

MIT.
