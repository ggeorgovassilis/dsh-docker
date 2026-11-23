#!/usr/bin/env bash
# Shared helpers for the DSH API runtime scripts.

set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

die() {
  echo "error: $*" >&2
  exit 1
}

warn() {
  echo "warning: $*" >&2
}

load_env() {
  [ -f .env ] || die "no .env (copy .env.example and fill it in)"
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a

  : "${IMAGE_REPOSITORY:=dsh-api-runtime}"
  : "${TOOLS_IMAGE_REPOSITORY:=${IMAGE_REPOSITORY}-tools}"
  : "${CONTAINER_NAME:=dsh}"
  : "${TOOLS_CONTAINER_NAME:=dsh-tools}"
  : "${HTTP_PORT:=3080}"
  : "${WEB_PORT:=8080}"
  : "${BIND_ADDRESS:=127.0.0.1}"
  : "${DSH_HOME_VOLUME:=dsh-api-home}"
  : "${WORKSPACE:=/workspace}"
  : "${DSH_CWD:=/workspace}"
  : "${DOCKER_SOCKET:=/var/run/docker.sock}"
  : "${MEMORY_LIMIT:=12g}"
  : "${CPU_LIMIT:=2}"
  : "${PROJECTS_PATH:=}"

  : "${DEEPSEEK_API_KEY:?DEEPSEEK_API_KEY is required}"
  : "${WORKSPACE_HOST:?WORKSPACE_HOST is required}"
  [ "$DEEPSEEK_API_KEY" != replace-me ] || die "set DEEPSEEK_API_KEY in .env"
  [ -d "$WORKSPACE_HOST" ] || die "WORKSPACE_HOST does not exist: $WORKSPACE_HOST"

  if [ -n "$PROJECTS_PATH" ]; then
    case "$PROJECTS_PATH" in
      /*) ;;
      *) die "PROJECTS_PATH must be an absolute path: $PROJECTS_PATH" ;;
    esac
    [ -d "$PROJECTS_PATH" ] || die "PROJECTS_PATH does not exist: $PROJECTS_PATH"
  fi
}

dsh_version() {
  sed -n 's/.*"@deepseek-ai\/dsh": *"\([^"]*\)".*/\1/p' package.json
}

image() {
  echo "${IMAGE_REPOSITORY}:${IMAGE_TAG:-$(dsh_version)}"
}

tools_image() {
  echo "${TOOLS_IMAGE_REPOSITORY}:${TOOLS_IMAGE_TAG:-${IMAGE_TAG:-$(dsh_version)}}"
}

# Write the DSH-runtime environment to a temporary file and print its path.
# The caller is responsible for deleting it. Tool configuration and credentials
# are deliberately excluded so the pure image never inherits them.
runtime_env_file() {
  local file name
  file=$(mktemp)
  chmod 600 "$file"

  while IFS= read -r name; do
    case "$name" in
      DSH_*|LOG_LEVEL|INIT_TIMEOUT_MS|RPC_TIMEOUT_MS|MAX_INFLIGHT|MAX_BODY_BYTES|ENABLE_APPROVALS|ENABLE_USER_QUESTIONS|STOP_BUDGET_MS|ALLOW_UNAUTHENTICATED_EXPOSURE|WORKSPACE|*_API_KEY|*_BASE_URL|HTTP_PROXY|HTTPS_PROXY|NO_PROXY|ALL_PROXY)
        printf '%s=%s\n' "$name" "${!name}" >>"$file"
        ;;
    esac
  done < <(compgen -e)

  printf '%s\n' "$file"
}
