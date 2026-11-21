#!/usr/bin/env bash
# Tests for scripts/lib.sh: defaults, required keys, and image naming.
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
  (cd "$tmp" && bash -c "source scripts/lib.sh; $snippet")
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

expect "tags with the pinned dsh version" "IMAGE_TAG=" \
  'load_env; [ "$(image)" = "dsh-api-runtime:$(dsh_version)" ]'

expect "honours an explicit IMAGE_TAG" "IMAGE_TAG=dev" \
  'load_env; [ "$(image)" = dsh-api-runtime:dev ]'

expect "strips a trailing comment" "IMAGE_TAG=x1  # note" \
  'load_env; [ "$(image)" = dsh-api-runtime:x1 ]'

expect_fails "requires a credential" "DEEPSEEK_API_KEY=" 'load_env'
expect_fails "rejects the placeholder credential" "DEEPSEEK_API_KEY=replace-me" 'load_env'
expect_fails "requires an existing workspace" "WORKSPACE_HOST=/nope/nope" 'load_env'

expect "leaves PROJECTS_PATH empty by default" "" \
  'load_env; [ -z "$PROJECTS_PATH" ]'

expect "accepts an existing absolute PROJECTS_PATH" "PROJECTS_PATH=$tmp" \
  'load_env; [ "$PROJECTS_PATH" = "$PWD" ] || [ -d "$PROJECTS_PATH" ]'

expect_fails "rejects a relative PROJECTS_PATH" "PROJECTS_PATH=relative/dir" 'load_env'
expect_fails "rejects a missing PROJECTS_PATH" "PROJECTS_PATH=/nope/nope" 'load_env'

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
