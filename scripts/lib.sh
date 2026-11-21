#!/usr/bin/env bash
# shellcheck disable=SC2094 # .env is only read; values go to variables
# Shared helpers for the DSH API runtime scripts.
#
# The .env parser is intentionally strict: no `source`, no `eval`, no shell
# expansion, no command substitution. Values are literal.

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

warn() {
  printf 'warning: %s\n' "$*" >&2
}

info() {
  printf '%s\n' "$*"
}

require_cmd() {
  local cmd="$1"
  command -v "${cmd}" >/dev/null 2>&1 || die "required command not found: ${cmd}"
}

require_buildx() {
  require_cmd docker
  docker buildx version >/dev/null 2>&1 \
    || die "docker buildx is required (install the Docker Buildx plugin)"
}

is_loopback() {
  local address="$1"
  case "${address}" in
    localhost | ::1 | '[::1]') return 0 ;;
  esac
  [[ "${address}" =~ ^127(\.[0-9]{1,3}){3}$ ]]
}

_parse_eng_value() {
  local raw="$1"
  local file="$2"
  local lineno="$3"

  raw="${raw#"${raw%%[![:space:]]*}"}"
  raw="${raw%"${raw##*[![:space:]]}"}"

  if [[ "${raw}" == \"* || "${raw}" == \'* ]]; then
    local quote="${raw:0:1}"
    local rest="${raw:1}"
    local out=''
    local i=0
    while (( i < ${#rest} )); do
      local char="${rest:i:1}"
      if [[ "${char}" == "${quote}" ]]; then
        local tail="${rest:i+1}"
        tail="${tail#"${tail%%[![:space:]]*}"}"
        if [[ -n "${tail}" && "${tail}" != \#* ]]; then
          die "${file}:${lineno}: unexpected text after closing quote"
        fi
        printf '%s' "${out}"
        return 0
      fi
      out+="${char}"
      i=$((i + 1))
    done
    die "${file}:${lineno}: unterminated quoted value"
  fi

  if [[ "${raw}" == *' #'* ]]; then
    raw="${raw%% #*}"
    raw="${raw%"${raw##*[![:space:]]}"}"
  fi
  printf '%s' "${raw}"
}

_check_eng_permissions() {
  local file="$1"
  local mode
  mode="$(stat -c '%a' "${file}" 2>/dev/null || stat -f '%Lp' "${file}" 2>/dev/null || true)"
  [[ -n "${mode}" ]] || return 0
  local numeric=$((8#${mode}))
  if (( (numeric & 8#077) != 0 )); then
    if [[ "${ALLOW_INSECURE_ENG:-0}" != "1" ]]; then
      die "${file} is group/world accessible (mode ${mode}); run 'chmod 600 ${file}' or set ALLOW_INSECURE_ENG=1"
    fi
    warn "${file} is group/world accessible and ALLOW_INSECURE_ENG=1 is set"
  fi
}

# Parse .env into exported variables. Rejects duplicates, invalid keys, and
# any value that is not a literal.
load_eng() {
  local file="${ENG_FILE:-${REPO_ROOT}/.env}"
  [[ -f "${file}" && -r "${file}" ]] || die ".env not found or unreadable: ${file} (copy .env.example to .env)"
  _check_eng_permissions "${file}"

  declare -gA ENG=()
  local line key value lineno=0

  while IFS= read -r line || [[ -n "${line}" ]]; do
    lineno=$((lineno + 1))
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -z "${line}" ]] && continue
    [[ "${line}" == \#* ]] && continue
    [[ "${line}" == *=* ]] || die "${file}:${lineno}: expected KEY=VALUE"

    key="${line%%=*}"
    value="${line#*=}"
    key="${key%"${key##*[![:space:]]}"}"

    [[ "${key}" =~ ^[A-Z][A-Z0-9_]*$ ]] || die "${file}:${lineno}: invalid key '${key}'"
    [[ -n "${ENG[${key}]+set}" ]] && die "${file}:${lineno}: duplicate key '${key}'"

    value="$(_parse_eng_value "${value}" "${file}" "${lineno}")"
    ENG["${key}"]="${value}"
    export "${key}=${value}"
  done < "${file}"

  ENG_FILE="${file}"
  export ENG_FILE

  # Optional keys get empty defaults so `set -u` stays usable.
  : "${IMAGE_REPOSITORY:=dsh-api-runtime}"
  : "${IMAGE_TAG:=}"
  : "${IMAGE_VERSION:=}"
  : "${IMAGE_REVISION:=}"
  : "${NODE_IMAGE_DIGEST:=}"
  : "${RUNTIME_IMAGE_DIGEST:=}"
  : "${ALLOW_UNAUTHENTICATED_EXPOSURE:=0}"
  : "${DSH_REASONING_EFFORT:=}"
  : "${DSH_MAX_TOKENS:=}"
  : "${DSH_TELEMETRY_MODE:=DISABLED}"
  : "${LOG_LEVEL:=info}"
  : "${INIT_TIMEOUT_MS:=60000}"
  : "${RPC_TIMEOUT_MS:=300000}"
  : "${MAX_INFLIGHT:=16}"
  : "${MAX_BODY_BYTES:=8388608}"
  : "${ENABLE_APPROVALS:=0}"
  : "${ENABLE_USER_QUESTIONS:=0}"
  : "${STOP_BUDGET_MS:=25000}"
  : "${MEMORY_LIMIT:=2g}"
  : "${CPU_LIMIT:=2}"
  : "${DEEPSEEK_BASE_URL:=}"
  : "${RUN_LIVE_SMOKE:=0}"
}

validate_config() {
  local required=(CONTAINER_NAME BIND_ADDRESS HTTP_PORT NODE_IMAGE RUNTIME_IMAGE
    DSH_HOME_VOLUME WORKSPACE_HOST WORKSPACE DSH_CWD DSH_PROVIDER DSH_MODEL)
  local key
  for key in "${required[@]}"; do
    [[ -n "${!key:-}" ]] || die ".env: ${key} must not be empty"
  done

  [[ "${HTTP_PORT}" =~ ^[0-9]+$ ]] || die ".env: HTTP_PORT must be numeric"
  (( HTTP_PORT >= 1 && HTTP_PORT <= 65535 )) || die ".env: HTTP_PORT must be between 1 and 65535"

  if [[ -n "${IMAGE_TAG}" ]]; then
    [[ "${IMAGE_TAG}" != *'+'* ]] || die ".env: IMAGE_TAG must not contain build metadata ('+')"
    [[ "${IMAGE_TAG}" != */* ]] || die ".env: IMAGE_TAG must not contain '/'"
    [[ "${IMAGE_TAG}" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || die ".env: IMAGE_TAG is not a valid Docker tag"
  fi

  [[ "${NODE_IMAGE}" != *'@'* ]] || die ".env: put the digest in NODE_IMAGE_DIGEST, not inline in NODE_IMAGE"
  [[ "${RUNTIME_IMAGE}" != *'@'* ]] || die ".env: put the digest in RUNTIME_IMAGE_DIGEST, not inline in RUNTIME_IMAGE"

  [[ -z "${NODE_IMAGE_DIGEST}" || "${NODE_IMAGE_DIGEST}" =~ ^(sha256:)?[0-9a-f]{64}$ ]] \
    || die ".env: NODE_IMAGE_DIGEST must be a sha256 digest"
  [[ -z "${RUNTIME_IMAGE_DIGEST}" || "${RUNTIME_IMAGE_DIGEST}" =~ ^(sha256:)?[0-9a-f]{64}$ ]] \
    || die ".env: RUNTIME_IMAGE_DIGEST must be a sha256 digest"

  if ! is_loopback "${BIND_ADDRESS}"; then
    [[ "${ALLOW_UNAUTHENTICATED_EXPOSURE}" == "1" ]] \
      || die ".env: BIND_ADDRESS=${BIND_ADDRESS} exposes an unauthenticated API; set ALLOW_UNAUTHENTICATED_EXPOSURE=1 to allow it"
  fi

  [[ -n "${DSH_PROVIDER}" ]] || die ".env: DSH_PROVIDER must not be empty"
  [[ -n "${DSH_MODEL}" ]] || die ".env: DSH_MODEL must not be empty"
  [[ -n "${DSH_CWD}" ]] || die ".env: DSH_CWD must not be empty"

  [[ -n "${DEEPSEEK_API_KEY:-}" && "${DEEPSEEK_API_KEY}" != "replace-me" ]] \
    || die ".env: DEEPSEEK_API_KEY must hold a model credential (not empty, not 'replace-me')"

  [[ "${DSH_TELEMETRY_MODE}" == "DISABLED" ]] \
    || warn "DSH_TELEMETRY_MODE=${DSH_TELEMETRY_MODE}: DSH product telemetry is not disabled"

  [[ -d "${WORKSPACE_HOST}" ]] || die "WORKSPACE_HOST does not exist: ${WORKSPACE_HOST}"
  [[ "${WORKSPACE_HOST}" == /* ]] || die "WORKSPACE_HOST must be an absolute path"
}

pinned_dsh_version() {
  local version
  version="$(sed -n 's/.*"@deepseek-ai\/dsh": *"\([^"]*\)".*/\1/p' "${REPO_ROOT}/package.json" | head -n 1)"
  [[ -n "${version}" ]] || die "package.json does not pin @deepseek-ai/dsh"
  [[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] \
    || die "package.json pins an unexpected @deepseek-ai/dsh version: ${version}"
  printf '%s' "${version}"
}

image_tag() {
  local tag="${IMAGE_TAG:-$(pinned_dsh_version)}"
  printf '%s' "${tag}"
}

image_name() {
  printf '%s:%s' "${IMAGE_REPOSITORY}" "$(image_tag)"
}

with_digest() {
  local ref="$1"
  local digest="$2"
  if [[ -z "${digest}" ]]; then
    printf '%s' "${ref}"
    return
  fi
  [[ "${digest}" == sha256:* ]] || digest="sha256:${digest}"
  printf '%s@%s' "${ref}" "${digest}"
}

require_image() {
  local image="$1"
  docker image inspect "${image}" >/dev/null 2>&1 \
    || die "image not found: ${image} (run scripts/build.sh first)"
}

# Write the filtered runtime environment to a private temporary file.
# Prints only the path. Never prints or logs the contents.
runtime_env_file() {
  local file
  file="$(mktemp "${TMPDIR:-/tmp}/dsh-api-runtime-env.XXXXXX")"
  chmod 600 "${file}"
  : > "${file}"

  local key value
  for key in \
    DEEPSEEK_API_KEY DEEPSEEK_BASE_URL \
    DSH_PROVIDER DSH_MODEL DSH_REASONING_EFFORT DSH_MAX_TOKENS DSH_TELEMETRY_MODE \
    LOG_LEVEL INIT_TIMEOUT_MS RPC_TIMEOUT_MS MAX_INFLIGHT MAX_BODY_BYTES \
    ENABLE_APPROVALS ENABLE_USER_QUESTIONS STOP_BUDGET_MS WORKSPACE DSH_CWD; do
    value="${!key-}"
    [[ -n "${value}" ]] || continue
    [[ "${value}" != *$'\n'* ]] || die "environment value for ${key} contains a newline"
    printf '%s=%s\n' "${key}" "${value}" >> "${file}"
  done

  printf '%s' "${file}"
}

cleanup_file() {
  local file="$1"
  if [[ -n "${file}" && -f "${file}" ]]; then
    rm -f "${file}"
  fi
  return 0
}
