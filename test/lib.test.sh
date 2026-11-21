#!/usr/bin/env bash
# shellcheck disable=SC2016 # snippets are intentionally single-quoted
# Tests for the strict .env parser and validation helpers in scripts/lib.sh.
# Runs without Docker: only bash, coreutils, and mktemp are required.

set -Eeuo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TESTS_DIR}/.." && pwd)"
LIB="${REPO_ROOT}/scripts/lib.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/dsh-api-lib-test.XXXXXX")"
pass=0
fail=0

cleanup() { rm -rf "${tmp}"; }
trap cleanup EXIT INT TERM

ok() {
  pass=$((pass + 1))
}

bad() {
  fail=$((fail + 1))
  printf 'FAIL: %s\n' "$1" >&2
}

expect_ok() {
  local description="$1"
  shift
  if "$@" >/dev/null 2>&1; then ok; else bad "${description}"; fi
}

expect_fail() {
  local description="$1"
  shift
  if "$@" >/dev/null 2>&1; then bad "${description} (expected failure)"; else ok; fi
}

# Run a snippet in a clean bash process with lib.sh sourced.
with_lib() {
  local env_file="$1"
  local snippet="$2"
  ENG_FILE="${env_file}" bash -Eeuo pipefail -c "source '${LIB}'; ${snippet}"
}

write_env() {
  local file="$1"
  cat >"${file}"
}

mkdir -p "${tmp}/workspace"

cat >"${tmp}/good.env" <<'EOF'
# comment
FOO=bar

QUOTED="hello world"
SINGLE='single quoted'
COMMENT=value # trailing comment
HASH=abc#def
EQ=a=b=c
EOF
chmod 600 "${tmp}/good.env"

expect_ok "parses literal values, quotes, comments, and embedded equals" \
  with_lib "${tmp}/good.env" '
    load_eng
    [[ "${FOO}" == "bar" ]]
    [[ "${QUOTED}" == "hello world" ]]
    [[ "${SINGLE}" == "single quoted" ]]
    [[ "${COMMENT}" == "value" ]]
    [[ "${HASH}" == "abc#def" ]]
    [[ "${EQ}" == "a=b=c" ]]'

cat >"${tmp}/duplicate.env" <<'EOF'
FOO=1
FOO=2
EOF
chmod 600 "${tmp}/duplicate.env"
expect_fail "rejects duplicate keys" with_lib "${tmp}/duplicate.env" 'load_eng'

cat >"${tmp}/badkey.env" <<'EOF'
lowercase=1
EOF
chmod 600 "${tmp}/badkey.env"
expect_fail "rejects invalid keys" with_lib "${tmp}/badkey.env" 'load_eng'

cat >"${tmp}/unterminated.env" <<'EOF'
FOO="open
EOF
chmod 600 "${tmp}/unterminated.env"
expect_fail "rejects unterminated quotes" with_lib "${tmp}/unterminated.env" 'load_eng'

cat >"${tmp}/trailing.env" <<'EOF'
FOO="value" junk
EOF
chmod 600 "${tmp}/trailing.env"
expect_fail "rejects text after a closing quote" with_lib "${tmp}/trailing.env" 'load_eng'

cat >"${tmp}/insecure.env" <<'EOF'
FOO=bar
EOF
chmod 644 "${tmp}/insecure.env"
expect_fail "rejects group/world-readable .env" with_lib "${tmp}/insecure.env" 'load_eng'
expect_ok "allows insecure permissions with ALLOW_INSECURE_ENG=1" \
  env ALLOW_INSECURE_ENG=1 ENG_FILE="${tmp}/insecure.env" \
  bash -Eeuo pipefail -c "source '${LIB}'; load_eng; [[ \"\${FOO}\" == bar ]]"

cat >"${tmp}/loopback.env" <<'EOF'
FOO=1
EOF
chmod 600 "${tmp}/loopback.env"
expect_ok "recognises loopback addresses" with_lib "${tmp}/loopback.env" '
  is_loopback 127.0.0.1
  is_loopback 127.9.9.9
  is_loopback ::1
  is_loopback localhost
  ! is_loopback 0.0.0.0
  ! is_loopback 192.168.1.2'

expect_ok "appends digests exactly once" with_lib "${tmp}/loopback.env" '
  [[ "$(with_digest node:24-trixie "")" == "node:24-trixie" ]]
  [[ "$(with_digest node:24-trixie "sha256:abc")" == "node:24-trixie@sha256:abc" ]]
  [[ "$(with_digest node:24-trixie "abc")" == "node:24-trixie@sha256:abc" ]]'

make_valid_env() {
  cat >"${tmp}/valid.env" <<EOF
CONTAINER_NAME=dsh-api-test
BIND_ADDRESS=127.0.0.1
HTTP_PORT=8080
NODE_IMAGE=node:24-trixie
RUNTIME_IMAGE=node:24-trixie-slim
DSH_HOME_VOLUME=dsh-api-test-home
WORKSPACE_HOST=${tmp}/workspace
WORKSPACE=/workspace
DSH_CWD=/workspace
DSH_PROVIDER=deepseek-official
DSH_MODEL=deepseek-v4-flash
DEEPSEEK_API_KEY=sk-test
EOF
  chmod 600 "${tmp}/valid.env"
}
make_valid_env

expect_ok "accepts a valid configuration" \
  with_lib "${tmp}/valid.env" 'load_eng; validate_config'

expect_fail "rejects a non-loopback bind without opt-in" with_lib "${tmp}/valid.env" '
  load_eng; BIND_ADDRESS=0.0.0.0; validate_config'

expect_ok "accepts a non-loopback bind with opt-in" with_lib "${tmp}/valid.env" '
  load_eng; BIND_ADDRESS=0.0.0.0; ALLOW_UNAUTHENTICATED_EXPOSURE=1; validate_config'

expect_fail "rejects build metadata in IMAGE_TAG" with_lib "${tmp}/valid.env" '
  load_eng; IMAGE_TAG=1.0.0+build; validate_config'

expect_fail "rejects an inline digest in NODE_IMAGE" with_lib "${tmp}/valid.env" '
  load_eng; NODE_IMAGE="node:24-trixie@sha256:abc"; validate_config'

expect_fail "rejects a placeholder credential" with_lib "${tmp}/valid.env" '
  load_eng; DEEPSEEK_API_KEY=replace-me; validate_config'

expect_ok "creates a private filtered runtime env file" \
  with_lib "${tmp}/valid.env" '
    load_eng
    file="$(runtime_env_file)"
    [[ "$(stat -c "%a" "${file}")" == "600" ]]
    grep -q "^DEEPSEEK_API_KEY=sk-test$" "${file}"
    grep -q "^DSH_PROVIDER=deepseek-official$" "${file}"
    ! grep -q "^CONTAINER_NAME=" "${file}"
    ! grep -q "^BIND_ADDRESS=" "${file}"
    rm -f "${file}"'

expect_ok "pins an exact DSH version" with_lib "${tmp}/valid.env" '
  version="$(pinned_dsh_version)"
  [[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]'

expect_ok "defaults IMAGE_TAG to the pinned version and honours an explicit tag" \
  with_lib "${tmp}/valid.env" '
    unset IMAGE_TAG
    load_eng
    [[ -z "${IMAGE_TAG}" ]]
    [[ "$(image_tag)" == "$(pinned_dsh_version)" ]]
    IMAGE_TAG=dev
    [[ "$(image_tag)" == "dev" ]]'

printf '\n%d passed, %d failed\n' "${pass}" "${fail}"
(( fail == 0 ))
