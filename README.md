# DSH in Docker

This project packages [DeepSeek Harness](https://www.npmjs.com/package/@deepseek-ai/dsh) (DSH) into a Docker container and exposes its two official interfaces:

- **The JSON-RPC API** — for scripts and other programs.
- **The web UI** — DSH's built-in browser interface (and clients like JaboDSH).

It runs the official `@deepseek-ai/dsh` package unchanged; it does not add features or modify DSH's behaviour.

## Two image profiles

The project builds two images from the same pinned DSH version:

| Profile | Image | What it contains |
|---|---|---|
| Tools (default) | `dsh-api-runtime-tools:<version>` | The base image plus `git`, `gh`, `openssh-client`, Docker CLI/buildx, `ripgrep` and `procps`. |
| Base / non-tools | `dsh-api-runtime:<version>` | DSH, the HTTP bridge, Node.js, `pnpm` and only the runtime dependencies DSH needs. |

The tools image extends the base image; it does not rebuild DSH. The default
`scripts/run.sh` launches the tools image. `scripts/run-base.sh` is the
explicit non-tools setup.

Both profiles share one `.env` file containing core DSH settings and
tool-profile settings. Do not create separate configuration files.

## Requirements

- A Linux host with Docker installed.
- A DeepSeek API key.

## Quick start: default tools profile

```bash
# 1. Get the code
git clone https://github.com/ggeorgovassilis/dsh-docker
cd dsh-docker

# 2. Configure both profiles in one file
cp .env.example .env
chmod 600 .env
$EDITOR .env        # set DEEPSEEK_API_KEY and WORKSPACE_HOST

# 3. Build both images
scripts/build.sh

# 4. Run the default tool-enabled container
scripts/run.sh -d

# 5. Store GitHub credentials in the tool-local volume
scripts/gh-auth.sh
```

When it is running:

- API: `http://<this-host>:3080/`
- Web UI: `http://<this-host>:8080/` (see [Using the web UI](#using-the-web-ui))

## Quick start: base profile

```bash
scripts/run-base.sh -d
```

The base container is named `dsh-base` by default. The tools container is named
`dsh`. Both profiles use the same `.env` and the same DSH home volume.

## Configuration

One `.env` file configures both profiles. The wrappers generate a filtered
runtime environment file, so the base container never receives tool
configuration or credentials.

The only two settings you must provide are:

| Setting | What it is |
|---|---|
| `DEEPSEEK_API_KEY` | Your DeepSeek API key. |
| `WORKSPACE_HOST` | A folder on your host where DSH reads and writes files. Create it first, e.g. `mkdir -p /srv/dsh-workspace`. |

Common core settings (present in both configuration files):

| Setting | Default | What it is |
|---|---|---|
| `HTTP_PORT` | `3080` | The host port the JSON-RPC API is reachable on. |
| `WEB_PORT` | `8080` | The host port the web UI is reachable on. |
| `BIND_ADDRESS` | `0.0.0.0` | Which host address the container is reachable on. `0.0.0.0` publishes on every interface; use `127.0.0.1` to keep it local. |
| `DSH_MODEL` | `deepseek-v4-flash` | The model DSH uses. |
| `MEMORY_LIMIT` / `CPU_LIMIT` | `12g` / `2` | How much memory and CPU the container may use. Running a session costs about 700 MB before any work; raise `MEMORY_LIMIT` if it gets killed (see [Troubleshooting](#troubleshooting)). |
| `PROJECTS_PATH` | empty | A folder of projects to mount at the same absolute path inside the container. See [Working on your own projects](#working-on-your-own-projects). |
| `CONTAINER_NAME` | `dsh` | Container name used by the default tools wrapper. |
| `BASE_CONTAINER_NAME` | `dsh-base` | Container name used by the base wrapper. |
| `DSH_HOME_VOLUME` | `dsh-api-home` | DSH's private state volume. |
| `TOOLS_IMAGE_REPOSITORY` | `dsh-api-runtime-tools` | Tool-enabled image repository. |
| `TOOLS_HOME_VOLUME` | `dsh-tools-home` | Dedicated volume for tool config and credentials. |
| `DOCKER_SOCKET` | `/var/run/docker.sock` | Docker socket mounted only by the tools wrapper. See [Docker access](#docker-access). |

`.env` contains no tool credentials. GitHub credentials are stored with
`scripts/gh-auth.sh` in the tool-local volume. Do not add `GH_TOKEN` to
`.env`.

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

### Base image

The base image contains only the DSH runtime:

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
docker exec dsh sh -c 'node --version; pnpm --version; git --version; gh --version | head -1; docker --version'
```

Tool configuration lives in a dedicated `dsh-tools-home` volume mounted at
`/home/node/.tools`. The tools wrapper sets:

- `GH_CONFIG_DIR=/home/node/.tools/gh`
- `GIT_CONFIG_GLOBAL=/home/node/.tools/gitconfig`
- `DOCKER_CONFIG=/home/node/.tools/docker`

These are non-secret paths. The long-running tools container does not receive
`GH_TOKEN` or any other tool credential through its environment.

### Docker access

The host Docker socket is mounted by the tools wrapper, so DSH can run
`docker` commands against your host's daemon:

```bash
docker ps
docker build -t my-app .
```

The wrapper adds the socket's group to the container user, so commands work as
UID 1000. Set `DOCKER_SOCKET` in `.env` if your daemon listens elsewhere
(for example a rootless socket). If the socket is absent, the tools wrapper
continues without Docker access and prints a warning.

> **Warning:** access to the Docker socket is equivalent to root access on the
> host. Code running in this container can start privileged containers and
> mount host directories. Only give the socket to containers you trust, and see
> [Security](#security).

### GitHub and git credentials

`gh` and `git` are available only in the tool-enabled image. Authenticate them
with the tool-local helper:

```bash
# Interactive prompt. The token is not echoed and is passed over stdin.
scripts/gh-auth.sh

# Non-interactive equivalent. The token never appears in argv or container env.
printf '%s\n' "$TOKEN" | scripts/gh-auth.sh --stdin
```

The helper:

- stores the credential in `dsh-tools-home:/home/node/.tools/gh/hosts.yml`;
- runs `gh auth setup-git`, writing Git's credential helper to
  `/home/node/.tools/gitconfig`;
- verifies the login from the tools container.

To rotate the token, re-run `scripts/gh-auth.sh`. The tools container does not
need to be recreated.

Verify the same environment a model shell receives:

```bash
docker exec dsh env -u GH_TOKEN gh auth status
docker exec dsh env -u GH_TOKEN gh api user --jq .login
```

No `GH_TOKEN` is needed in `.env` or in the container environment. Do not
print or pass the token as a command-line argument.

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

For the base container, use `docker logs dsh-base`. Then open the web UI with
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
scripts/stop.sh            # stop/remove the default tools container
scripts/stop.sh base       # stop/remove the base container
scripts/stop.sh all        # stop/remove both
scripts/run.sh -d          # start the default tools container
scripts/run-base.sh -d     # start the base container
docker logs -f dsh         # tools container logs
docker logs -f dsh-base    # base container logs
```

`scripts/stop.sh` with no argument stops the tools container. Volumes are kept.

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

The base image does not mount the Docker socket, has no tool volume and
contains no agent CLI tools. The tools image weakens the container boundary:
anything that can make DSH run commands can control the host Docker daemon,
which is effectively root on the host. If you do not need Docker inside the
container, use `scripts/run-base.sh` or leave `DOCKER_SOCKET`
unset/nonexistent in `.env`.

GitHub credentials are stored in the tool volume, separate from DSH state and
from the container environment. The volume is writable by UID 1000 and should
be backed up or removed according to your normal secret-handling policy.

## Troubleshooting

**A process was killed and the logs stop abruptly.** A `SIGKILL` with no stack
trace or error is almost always the kernel OOM killer: the container went over
`MEMORY_LIMIT`. The supervisor now says so explicitly:

```json
{"level":"error","msg":"supervised process killed by the out-of-memory killer","name":"dsh-web","signal":"SIGKILL","oomKilled":true,"memory":{"maxBytes":12884901888,"peakBytes":12884901880,"oomKills":1},"hint":"raise MEMORY_LIMIT in .env and run scripts/run.sh -d or scripts/run-base.sh -d"}
```

An idle container uses around 700 MB (`docker stats dsh`); a busy session can
use much more. Raise `MEMORY_LIMIT` in `.env` and restart with
`scripts/run.sh -d` or `scripts/run-base.sh -d`.

To confirm it was the container's own limit rather than host-wide memory
pressure, check the kernel log on the host:

```bash
journalctl -k | grep -i 'memory cgroup out of memory'
```

The cgroup usage shown inside the container is the same data the kernel used:

```bash
docker exec dsh sh -c 'cat /sys/fs/cgroup/memory.peak /sys/fs/cgroup/memory.events'
```

Use `docker exec dsh` for the tools container and `docker exec dsh-base` for the base container.

**The container exits as soon as a session starts.** Look for `signal:
SIGTERM` from `supervised process exited`: something stopped the process, for
example `docker stop` or a crash on startup. The first error line names the
process.

**The web UI token changed.** The token is regenerated on every start; read the
current one with `docker logs dsh | grep 'dsh web:'` for the tools
container or `docker logs dsh-base | grep 'dsh web:'` for the base container.

## Where DSH and tools keep their data

Three locations matter:

- `WORKSPACE_HOST` — the folder DSH works in (mounted from your host).
- `DSH_HOME_VOLUME` (default `dsh-api-home`) — DSH's own state, kept between
  restarts. The web UI and the API share it.
- `TOOLS_HOME_VOLUME` (default `dsh-tools-home`) — tool configuration and
  GitHub credentials, mounted only by the tools wrapper.

`scripts/stop.sh` removes containers; it never deletes your workspace folder,
the DSH home volume or the tools volume.

To migrate from the old `GH_TOKEN` workflow, run `scripts/gh-auth.sh`, then
remove `GH_TOKEN` from `.env`. The old DSH-home tool files can be removed
after verifying that the tool-local login works.

## License

MIT.
