#!/usr/bin/env bash
# Run the DSH API runtime container from .env values.

set -Eeuo pipefail

# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<'EOF'
usage: scripts/run.sh [-d|--detach] [--no-build]

  -d, --detach   run in the background with --restart unless-stopped
  --no-build     fail instead of building the image when it is missing
EOF
}

detach=0
no_build=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d | --detach) detach=1 ;;
    --no-build) no_build=1 ;;
    -h | --help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
  shift
done

load_eng
validate_config
require_cmd docker

image="$(image_name)"
if ! docker image inspect "${image}" >/dev/null 2>&1; then
  if [[ "${no_build}" == "1" ]]; then
    die "image not found: ${image}"
  fi
  "${REPO_ROOT}/scripts/build.sh"
fi

docker volume inspect "${DSH_HOME_VOLUME}" >/dev/null 2>&1 \
  || docker volume create "${DSH_HOME_VOLUME}" >/dev/null

if [[ "$(stat -c '%u' "${WORKSPACE_HOST}")" != "1000" ]]; then
  warn "${WORKSPACE_HOST} is not owned by UID 1000; the container runs as 1000:1000."
  warn "Fix with: sudo chown -R 1000:1000 ${WORKSPACE_HOST}"
  warn "Or start Docker with a matching --user (not supported by this script)."
fi

env_file="$(runtime_env_file)"
trap 'cleanup_file "${env_file}"' EXIT INT TERM

publish_host="${BIND_ADDRESS}"
if [[ "${publish_host}" == *:* ]]; then
  publish_host="[${publish_host}]"
fi

args=(
  run
  --name "${CONTAINER_NAME}"
  --read-only
  --tmpfs '/tmp:rw,noexec,nosuid,nodev,size=256m'
  --cap-drop ALL
  --security-opt 'no-new-privileges:true'
  --pids-limit 512
  --user 1000:1000
  # Keep this above STOP_BUDGET_MS (bridge default 25s).
  --stop-timeout 30
  --memory "${MEMORY_LIMIT}"
  --cpus "${CPU_LIMIT}"
  --publish "${publish_host}:${HTTP_PORT}:8080"
  --env HTTP_BIND=0.0.0.0
  --env-file "${env_file}"
  --volume "${DSH_HOME_VOLUME}:/home/node/.dsh"
  --volume "${WORKSPACE_HOST}:${WORKSPACE}"
)

if [[ "${detach}" == "1" ]]; then
  args+=(--detach --restart unless-stopped)
else
  args+=(--rm)
fi

args+=("${image}")

info "starting ${CONTAINER_NAME} from ${image}"
docker "${args[@]}"

display_host="${BIND_ADDRESS}"
if [[ "${display_host}" == "0.0.0.0" || "${display_host}" == "::" ]]; then
  display_host="127.0.0.1"
fi

info ""
info "API base URL: http://${display_host}:${HTTP_PORT}"
info "This service has NO authentication. Keep the bind address on loopback"
info "unless ALLOW_UNAUTHENTICATED_EXPOSURE=1 and a trusted network/proxy protects it."
info "Logs: docker logs ${CONTAINER_NAME}"
