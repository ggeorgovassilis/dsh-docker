#!/usr/bin/env bash
# Tests for scripts/lib.sh: defaults, required keys, image naming, the filtered
# DSH-runtime environment and one-file profile configuration.

# shellcheck disable=SC2016 # test snippets are intentionally literal

set -Eeuo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
pass=0 fail=0

ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $1" >&2; }

# Run a snippet against a throwaway copy of the repo layout.
run() {
  local marker="$1" snippet="$2"
  mkdir -p "$tmp/scripts" "$tmp/workspace"
  cp "$repo/scripts/lib.sh" "$repo/package.json" "$tmp/"
  mv "$tmp/lib.sh" "$tmp/scripts/lib.sh"
  printf 'WORKSPACE_HOST=%s/workspace\nDEEPSEEK_API_KEY=sk-test\n' "$tmp" >"$tmp/.env"
  [ -n "$marker" ] && printf '%s\n' "$marker" >>"$tmp/.env"
  (cd "$tmp" && env -i PATH="$PATH" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" bash --noprofile --norc -c "source scripts/lib.sh; $snippet")
}

expect() {
  local name="$1" marker="$2" snippet="$3"
  if run "$marker" "$snippet" >/dev/null 2>&1; then ok; else bad "$name"; fi
}

expect_fails() {
  local name="$1" marker="$2" snippet="$3"
  if run "$marker" "$snippet" >/dev/null 2>&1; then bad "$name (expected failure)"; else ok; fi
}

expect "applies defaults" "" \
  'load_env
   [ "$HTTP_PORT" = 3080 ] && [ "$BIND_ADDRESS" = 127.0.0.1 ]'

expect "defaults the base and tools container names" "" \
  'load_env
   [ "$CONTAINER_NAME" = dsh ]
   [ "$BASE_CONTAINER_NAME" = dsh-base ]'

expect "tags the base image with the pinned dsh version" "IMAGE_TAG=" \
  'load_env; [ "$(image)" = "dsh-api-runtime:$(dsh_version)" ]'

expect "tags the tools image with the pinned dsh version" "IMAGE_TAG=" \
  'load_env; [ "$(tools_image)" = "dsh-api-runtime-tools:$(dsh_version)" ]'

expect "honours an explicit IMAGE_TAG for both images" "IMAGE_TAG=dev" \
  'load_env; [ "$(image)" = dsh-api-runtime:dev ] && [ "$(tools_image)" = dsh-api-runtime-tools:dev ]'

expect "strips a trailing comment" "IMAGE_TAG=x1  # note" \
  'load_env; [ "$(image)" = dsh-api-runtime:x1 ]'

expect "defaults tools state" "" \
  'load_env
   [ "$TOOLS_HOME_VOLUME" = dsh-tools-home ]
   [ "$DOCKER_SOCKET" = /var/run/docker.sock ]'

expect "loads tool settings from the same .env" \
  "$(printf 'TOOLS_IMAGE_REPOSITORY=custom-tools\nCONTAINER_NAME=custom-name\nTOOLS_HOME_VOLUME=custom-tools-volume\nDOCKER_SOCKET=/tmp/docker.sock')" \
  'load_env
   [ "$TOOLS_IMAGE_REPOSITORY" = custom-tools ]
   [ "$CONTAINER_NAME" = custom-name ]
   [ "$TOOLS_HOME_VOLUME" = custom-tools-volume ]
   [ "$DOCKER_SOCKET" = /tmp/docker.sock ]'

expect_fails "requires a credential" "DEEPSEEK_API_KEY=" 'load_env'
expect_fails "rejects the placeholder credential" "DEEPSEEK_API_KEY=replace-me" 'load_env'
expect_fails "requires an existing workspace" "WORKSPACE_HOST=/nope/nope" 'load_env'

expect "leaves PROJECTS_PATH empty by default" "" \
  'load_env; [ -z "$PROJECTS_PATH" ]'

expect "defaults the memory limit" "" \
  'load_env; [ "$MEMORY_LIMIT" = 12g ]'

expect "accepts an existing absolute PROJECTS_PATH" "PROJECTS_PATH=$tmp" \
  'load_env; [ "$PROJECTS_PATH" = "$PWD" ] || [ -d "$PROJECTS_PATH" ]'

expect_fails "rejects a relative PROJECTS_PATH" "PROJECTS_PATH=relative/dir" 'load_env'
expect_fails "rejects a missing PROJECTS_PATH" "PROJECTS_PATH=/nope/nope" 'load_env'

expect "filters tool environment out of the base runtime env" \
  "$(printf 'GH_TOKEN=secret\nGITHUB_TOKEN=secret\nDOCKER_SOCKET=/var/run/docker.sock\nDOCKER_CONFIG=/tmp/docker\nGIT_CONFIG_GLOBAL=/tmp/gitconfig\nGH_CONFIG_DIR=/tmp/gh')" \
  'load_env
   f=$(runtime_env_file)
   grep -q "^DEEPSEEK_API_KEY=sk-test$" "$f"
   ! grep -qE "^(GH_TOKEN|GITHUB_TOKEN|DOCKER_SOCKET|DOCKER_CONFIG|GIT_CONFIG_GLOBAL|GH_CONFIG_DIR)=" "$f"
   rc=$?
   rm -f "$f"
   exit $rc'

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
