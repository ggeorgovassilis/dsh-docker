#!/usr/bin/env bash
# Shared launcher for the pure and tool-enabled runtime profiles.

# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"
load_env

profile=${1:-core}
shift || true

case "$profile" in
  core)
    selected_image=$(image)
    selected_name=$CONTAINER_NAME
    ;;
  tools)
    selected_image=$(tools_image)
    selected_name=$TOOLS_CONTAINER_NAME
    ;;
  *)
    die "unknown profile: $profile (expected core or tools)"
    ;;
esac

case "$BIND_ADDRESS" in
  127.* | localhost | ::1) ;;
  *) [ "${ALLOW_UNAUTHENTICATED_EXPOSURE:-0}" = 1 ] \
       || die "BIND_ADDRESS=$BIND_ADDRESS exposes an unauthenticated API; set ALLOW_UNAUTHENTICATED_EXPOSURE=1 to allow it" ;;
esac

docker image inspect "$selected_image" >/dev/null 2>&1 || "$(dirname "$0")/build.sh"
docker volume inspect "$DSH_HOME_VOLUME" >/dev/null 2>&1 \
  || docker volume create "$DSH_HOME_VOLUME" >/dev/null

if [ "${1:-}" = "-d" ]; then
  mode=(--detach --restart unless-stopped)
else
  mode=(--rm)
fi

mounts=(
  --volume "$DSH_HOME_VOLUME:/home/node/.dsh"
  --volume "$WORKSPACE_HOST:$WORKSPACE"
)

# Mount your projects at the same absolute path inside the container, so a
# path DSH records (a workspace, a session cwd) is valid on the host too.
if [ -n "$PROJECTS_PATH" ]; then
  mounts+=(--volume "$PROJECTS_PATH:$PROJECTS_PATH")
fi

runtime_env=$(runtime_env_file)
cleanup_files=("$runtime_env")
extra_args=()

if [ "$profile" = tools ]; then
  # Tool configuration is an explicit opt-in by the tools wrapper. Keep the
  # legacy GH_TOKEN bridge until the dedicated tools credential store lands,
  # but do not copy unrelated host/tool settings from .env into the container.
  {
    printf 'DOCKER_CONFIG=%s\n' /home/node/.dsh/.docker
    printf 'GIT_CONFIG_GLOBAL=%s\n' /home/node/.dsh/.gitconfig
    for name in GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN; do
      if [ -n "${!name:-}" ]; then
        printf '%s=%s\n' "$name" "${!name}"
      fi
    done
  } >>"$runtime_env"

  if [ -n "$DOCKER_SOCKET" ] && [ -S "$DOCKER_SOCKET" ]; then
    docker_gid=$(stat -c '%g' "$DOCKER_SOCKET")
    mounts+=(--volume "$DOCKER_SOCKET:/var/run/docker.sock")
    extra_args+=(--group-add "$docker_gid")
  else
    warn "Docker socket not found at ${DOCKER_SOCKET:-<unset>}; continuing without Docker CLI access"
  fi
fi

cleanup() {
  rm -f "${cleanup_files[@]}"
}
trap cleanup EXIT

# Replace a container left behind by a previous run of the same profile.
docker rm --force "$selected_name" >/dev/null 2>&1 || true

docker run "${mode[@]}" --name "$selected_name" \
  --read-only --tmpfs '/tmp:rw,noexec,nosuid,nodev,size=256m' \
  --cap-drop ALL --security-opt 'no-new-privileges:true' \
  --pids-limit 512 --user 1000:1000 --stop-timeout 30 \
  --memory "$MEMORY_LIMIT" --cpus "$CPU_LIMIT" \
  --publish "${BIND_ADDRESS}:${HTTP_PORT}:3080" \
  --publish "${BIND_ADDRESS}:${WEB_PORT}:8080" \
  --env-file "$runtime_env" "${extra_args[@]}" "${mounts[@]}" \
  "$selected_image"

# 0.0.0.0 is not a browsable address; show one the host actually has.
host="$BIND_ADDRESS"
if [ "$host" = 0.0.0.0 ]; then
  host="$(hostname -I 2>/dev/null | awk '{print $1}')"
  host="${host:-127.0.0.1}"
fi

echo
echo "Profile: $profile ($selected_image)"
echo "API:     http://${host}:${HTTP_PORT}  (no authentication)"
echo "Web UI:  http://${host}:${WEB_PORT}   (launch token in 'docker logs $selected_name')"
if [ -n "$PROJECTS_PATH" ]; then
  echo "Projects: $PROJECTS_PATH (same path inside the container)"
fi
echo "Logs: docker logs $selected_name"
