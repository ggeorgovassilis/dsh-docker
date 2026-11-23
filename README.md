# DSH in Docker

This project packages [DeepSeek Harness](https://www.npmjs.com/package/@deepseek-ai/dsh) (DSH) into a Docker container and exposes its two official interfaces:

- **The JSON-RPC API** — for scripts and other programs.
- **The web UI** — DSH's built-in browser interface (and clients like JaboDSH).

It runs the official `@deepseek-ai/dsh` package unchanged; it does not add features or modify DSH's behaviour.

## Two image profiles

The project builds two images from the same pinned DSH version:

| Profile | Image | What it contains |
|---|---|---|
| Pure DSH | `dsh-api-runtime:<version>` | DSH, the HTTP bridge, Node.js, `pnpm` and only the runtime dependencies DSH needs. |
| Tool-enabled | `dsh-api-runtime-tools:<version>` | The pure image plus `git`, `gh`, `openssh-client`, Docker CLI/buildx, `ripgrep` and `procps`. |

The tool-enabled image extends the pure image; it does not rebuild DSH. Use the
pure wrapper when DSH should be the only thing in the container, and the tools
wrapper when the agent needs those extra CLI tools.

## Requirements

- A Linux host with Docker installed.
- A DeepSeek API key.

## Quick start: pure DSH

```bash
# 1. Get the code
git clone https://github.com/ggeorgovassilis/dsh-docker
cd dsh-docker

# 2. Configure it
cp .env.example .env
chmod 600 .env
$EDITOR .env        # set DEEPSEEK_API_KEY and WORKSPACE_HOST

# 3. Build both images
scripts/build.sh

# 4. Run the pure DSH container
scripts/run-core.sh -d
```

When it is running (reachable from other machines too, because
`BIND_ADDRESS` defaults to `0.0.0.0`):

- API: `http://<this-host>:3080`
- Web UI: `http://<this-host>:8080` (see [Using the web UI](#using-the-web-ui))

`scripts/run.sh` is kept as a backwards-compatible alias for
`scripts/run-core.sh`.

## Quick start: tool-enabled DSH

```bash
scripts/run-tools.sh -d
```

This starts the same DSH runtime in `dsh-api-runtime-tools`, mounts the host
Docker socket when available, and enables the extra CLI tools. It uses the
container name `dsh-tools` by default.

Both profiles use the same DSH home volume, so sessions and DSH configuration
are preserved when switching profiles.

## Configuration

Configuration is read from `.env`. The pure wrapper does **not** pass the whole
file to Docker: it generates a temporary DSH-only environment file and excludes
tool-specific variables such as `GH_TOKEN`, `DOCKER_SOCKET` and
`GIT_CONFIG_GLOBAL`. The tools wrapper opts into the additional tool settings.

The only two settings you must provide are:

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
| `CONTAINER_NAME` | `dsh` | Container name used by the pure wrapper. |
| `TOOLS_CONTAINER_NAME` | `dsh-tools` | Container name used by the tools wrapper. |
| `DOCKER_SOCKET` | `/var/run/docker.sock` | Docker socket mounted only by the tools wrapper. See [Docker access](#docker-access). |

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
  `--user` value in `scripts/run-container.sh`).
- The mount is read/write: that is what lets DSH edit your code.

## Installed tools

### Pure image

The pure image contains only the DSH runtime:

| Tool | What it is |
|---|---|
| `node`, `npm`, `npx` | Node.js 24 runtime and package manager (the base image DSH runs on). |
| `pnpm` | Package manager used by `dsh plugin` for profile management. |
| `tini` | PID 1 init process for clean signal handling. |

It deliberately does not contain `git`, `gh`, `docker`, `rg` or `ps`.

### Tool-enabled image

The tool-enabled image adds the usual development and delivery tooling:

| Tool | What it is |
|---|---|
| `git`, `openssh-client` | Version control and SSH remotes. |
| `gh` | GitHub's official CLI. |
| `docker` | Docker CLI, with the `buildx` plugin. Talks to the host daemon (see [Docker access](#docker-access)). |
| `rg`, `ps` | ripgrep for searching and `ps` for process inspection. |

Check them from the host:

```bash
docker exec dsh-tools sh -c 'node --version; pnpm --version; git --version; gh --version | head -1; docker --version'
```

Tool configuration currently lives in the writable DSH home volume
(`/home/node/.dsh`). Tool-specific state will be moved to a dedicated tools
volume in a follow-up change.

### Docker access

The host Docker socket is mounted by the tools wrapper, so DSH can run
`docker` commands against your host's daemon:

```bash
docker ps
docker build -t my-app .
```

The wrapper adds the socket's group to the container user, so commands work as
UID 1000. Point `DOCKER_SOCKET` at another path if your daemon listens
elsewhere (for example a rootless socket). If the socket is absent, the tools
wrapper continues without Docker access and prints a warning.

> **Warning:** access to the Docker socket is equivalent to root access on the
> host. Code running in this container can start privileged containers and
> mount host directories. Only give the socket to containers you trust, and see
> [Security](#security).

### GitHub and git credentials

`gh` and `git` are available only in the tool-enabled image. Both are
unauthenticated by default. Log in inside the tools container:

```bash
docker exec -it dsh-tools gh auth login
docker exec -it dsh-tools gh auth setup-git   # lets git push use the gh token
```

Alternatively, `GH_TOKEN` in `.env` is passed only to the tools container. That
variable is not available to model shell commands because DSH intentionally
scrubs credential-shaped environment variables; prefer `gh auth login`, which
persists credentials in the DSH home volume.

Confirm authentication with:

```bash
docker exec dsh-tools gh auth status
```

Do not print the token.

### Installing more tools

There is no `curl`, `wget`, `python3` or `jq` in the image, and the root
filesystem is read-only, so `apt-get install` does not work at runtime. Add
packages to [Dockerfile.tools](Dockerfile.tools) and rebuild with
`scripts/build.sh`.

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

For the tools container, use `docker logs dsh-tools`. Then open the web UI with
that token:

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

## Managing the containers

```bash
scripts/stop.sh core       # stop and remove the pure container
scripts/stop.sh tools      # stop and remove the tools container
scripts/stop.sh all        # stop and remove both
scripts/run-core.sh -d     # start the pure container again
scripts/run-tools.sh -d    # start the tools container again
docker logs -f dsh         # pure container logs
docker logs -f dsh-tools   # tools container logs
```

`scripts/stop.sh` with no argument stops the pure container. Volumes are kept.

## Updating DSH

```bash
scripts/update-dsh.sh next
```

This updates to the newest DSH version, rebuilds both images, and runs a basic
self-test. It does not commit anything; review the changes it prints before
committing them.

To roll back, keep the previous images around and re-run the appropriate
wrapper with the previous `IMAGE_TAG` in `.env`.

## Security

> **The JSON-RPC API has no authentication.** Anyone who can reach it can run
> DSH (which can execute commands in the workspace) and spend your API credits.

The web UI is protected by its launch token, but it is still a full management
surface (file browsing, terminal, approvals).

`BIND_ADDRESS=0.0.0.0` publishes both on every host interface, so any machine
that can reach this host can use them. If that is not what you want, set
`BIND_ADDRESS=127.0.0.1` in `.env`; otherwise put the host behind a firewall
or an authenticating reverse proxy.

The pure image does not mount the Docker socket and contains no agent CLI
tools. The tools image weakens the container boundary: anything that can make
DSH run commands can control the host Docker daemon, which is effectively root
on the host. If you do not need Docker inside the container, use the pure
profile or leave `DOCKER_SOCKET` unset/nonexistent.

## Troubleshooting

**A process was killed and the logs stop abruptly.** A `SIGKILL` with no stack
trace or error is almost always the kernel OOM killer: the container went over
`MEMORY_LIMIT`. The supervisor now says so explicitly:

```json
{"level":"error","msg":"supervised process killed by the out-of-memory killer","name":"dsh-web","signal":"SIGKILL","oomKilled":true,"memory":{"maxBytes":12884901888,"peakBytes":12884901880,"oomKills":1},"hint":"raise MEMORY_LIMIT in .env and run scripts/run-core.sh -d"}
```

An idle container uses around 700 MB (`docker stats dsh`); a busy session can
use much more. Raise `MEMORY_LIMIT` in `.env` and restart with
`scripts/run-core.sh -d` or `scripts/run-tools.sh -d`.

To confirm it was the container's own limit rather than host-wide memory
pressure, check the kernel log on the host:

```bash
journalctl -k | grep -i 'memory cgroup out of memory'
```

The cgroup usage shown inside the container is the same data the kernel used:

```bash
docker exec dsh sh -c 'cat /sys/fs/cgroup/memory.peak /sys/fs/cgroup/memory.events'
```

Use `docker exec dsh-tools` for the tools container.

**The container exits as soon as a session starts.** Look for `signal:
SIGTERM` from `supervised process exited`: something stopped the process, for
example `docker stop` or a crash on startup. The first error line names the
process.

**The web UI token changed.** The token is regenerated on every start; read the
current one with `docker logs dsh | grep 'dsh web:'` or
`docker logs dsh-tools | grep 'dsh web:'`.

## Where DSH keeps its data

Two folders matter:

- `WORKSPACE_HOST` — the folder DSH works in (mounted from your host).
- A Docker volume (`DSH_HOME_VOLUME`, default `dsh-api-home`) — DSH's own
  state, kept between restarts. The web UI and the API share it.

`scripts/stop.sh` removes containers; it never deletes your workspace folder or
the DSH home volume.

## License

MIT.
