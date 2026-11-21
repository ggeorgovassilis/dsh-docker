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

# Replace a container left behind by a previous run.
docker rm --force dsh >/dev/null 2>&1 || true

docker run "${mode[@]}" --name dsh \
  --read-only --tmpfs '/tmp:rw,noexec,nosuid,nodev,size=256m' \
  --cap-drop ALL --security-opt 'no-new-privileges:true' \
  --pids-limit 512 --user 1000:1000 --stop-timeout 30 \
  --memory "$MEMORY_LIMIT" --cpus "$CPU_LIMIT" \
  --publish "${BIND_ADDRESS}:${HTTP_PORT}:3080" \
  --env-file .env \
  --volume "$DSH_HOME_VOLUME:/home/node/.dsh" \
  --volume "$WORKSPACE_HOST:$WORKSPACE" \
  "$(image)"

echo
echo "API: http://${BIND_ADDRESS}:${HTTP_PORT}  (no authentication)"
echo "Logs: docker logs dsh"
