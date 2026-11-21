#!/usr/bin/env bash
# Start the API container. Use -d for detached.

# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"
load_env

case "$BIND_ADDRESS" in
  127.* | localhost | ::1) ;;
  *) [ "${ALLOW_UNAUTHENTICATED_EXPOSURE:-0}" = 1 ] \
       || die "BIND_ADDRESS=$BIND_ADDRESS exposes an unauthenticated API; set ALLOW_UNAUTHENTICATED_EXPOSURE=1 to allow it" ;;
esac

docker image inspect "$(image)" >/dev/null 2>&1 || "$(dirname "$0")/build.sh"
docker volume inspect "$DSH_HOME_VOLUME" >/dev/null 2>&1 \
  || docker volume create "$DSH_HOME_VOLUME" >/dev/null

if [ "${1:-}" = "-d" ]; then
  mode=(--detach --restart unless-stopped)
else
  mode=(--rm)
fi

[ -S "$DOCKER_SOCKET" ] || die "Docker socket not found: $DOCKER_SOCKET"
docker_gid=$(stat -c '%g' "$DOCKER_SOCKET")

mounts=(
  --volume "$DSH_HOME_VOLUME:/home/node/.dsh"
  --volume "$WORKSPACE_HOST:$WORKSPACE"
  --volume "$DOCKER_SOCKET:/var/run/docker.sock"
)

# Mount your projects at the same absolute path inside the container, so a
# path DSH records (a workspace, a session cwd) is valid on the host too.
if [ -n "$PROJECTS_PATH" ]; then
  mounts+=(--volume "$PROJECTS_PATH:$PROJECTS_PATH")
fi

# Replace a container left behind by a previous run.
docker rm --force dsh >/dev/null 2>&1 || true

docker run "${mode[@]}" --name dsh \
  --read-only --tmpfs '/tmp:rw,noexec,nosuid,nodev,size=256m' \
  --cap-drop ALL --security-opt 'no-new-privileges:true' \
  --pids-limit 512 --user 1000:1000 --group-add "$docker_gid" --stop-timeout 30 \
  --memory "$MEMORY_LIMIT" --cpus "$CPU_LIMIT" \
  --publish "${BIND_ADDRESS}:${HTTP_PORT}:3080" \
  --publish "${BIND_ADDRESS}:${WEB_PORT}:${WEB_PORT}" \
  --env-file .env \
  "${mounts[@]}" \
  "$(image)"

# 0.0.0.0 is not a browsable address; show one the host actually has.
host="$BIND_ADDRESS"
if [ "$host" = 0.0.0.0 ]; then
  host="$(hostname -I 2>/dev/null | awk '{print $1}')"
  host="${host:-127.0.0.1}"
fi

echo
echo "API:     http://${host}:${HTTP_PORT}  (no authentication)"
echo "Web UI:  http://${host}:${WEB_PORT}   (launch token in 'docker logs dsh')"
if [ -n "$PROJECTS_PATH" ]; then
  echo "Projects: $PROJECTS_PATH (same path inside the container)"
fi
echo "Logs: docker logs dsh"
