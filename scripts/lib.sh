#!/usr/bin/env bash
# Shared helpers for the DSH API runtime scripts.

set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

die() {
  echo "error: $*" >&2
  exit 1
}

load_env() {
  [ -f .env ] || die "no .env (copy .env.example and fill it in)"
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a

  : "${IMAGE_REPOSITORY:=dsh-api-runtime}"
  : "${HTTP_PORT:=3080}"
  : "${WEB_PORT:=8080}"
  : "${BIND_ADDRESS:=127.0.0.1}"
  : "${DSH_HOME_VOLUME:=dsh-api-home}"
  : "${WORKSPACE:=/workspace}"
  : "${DSH_CWD:=/workspace}"
  : "${MEMORY_LIMIT:=2g}"
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
