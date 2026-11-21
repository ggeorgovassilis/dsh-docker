#!/usr/bin/env bash
# Verify version consistency and build hygiene.

set -Eeuo pipefail

# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

load_eng
require_cmd docker

image="${1:-$(image_name)}"
require_image "${image}"

pinned="$(pinned_dsh_version)"
image_version="$(docker run --rm --entrypoint /app/node_modules/.bin/dsh "${image}" --version)"
label_version="$(docker image inspect --format '{{ index .Config.Labels "io.example.dsh.version" }}' "${image}")"

[[ "${image_version}" == "${pinned}" ]] \
  || die "image dsh version ${image_version} != package.json ${pinned}"
[[ "${label_version}" == "${pinned}" ]] \
  || die "image label ${label_version:-missing} != package.json ${pinned}"

tag="$(image_tag)"
[[ "${tag}" != "latest" ]] || die "refusing to verify a floating latest tag"
info "verify: dsh ${pinned} matches the binary and image label"

[[ -f "${REPO_ROOT}/package-lock.json" ]] || die "package-lock.json is missing"

node_ref="$(with_digest "${NODE_IMAGE}" "${NODE_IMAGE_DIGEST}")"
docker run --rm \
  --user "$(id -u):$(id -g)" \
  --env HOME=/tmp \
  --env npm_config_cache=/tmp/.npm \
  --volume "${REPO_ROOT}:/src:ro" \
  --workdir /src \
  "${node_ref}" \
  npm ci --dry-run --ignore-scripts --no-audit --no-fund >/dev/null
info "verify: package-lock.json is consistent"

grep -q -- '--read-only' "${REPO_ROOT}/scripts/run.sh" || die "run.sh does not set --read-only"
grep -q -- '--cap-drop ALL' "${REPO_ROOT}/scripts/run.sh" || die "run.sh does not drop capabilities"
grep -q -- 'no-new-privileges' "${REPO_ROOT}/scripts/run.sh" || die "run.sh does not set no-new-privileges"
grep -q -- '--user 1000:1000' "${REPO_ROOT}/scripts/run.sh" || die "run.sh does not run as a non-root user"
if grep -q 'docker.sock' "${REPO_ROOT}/scripts/run.sh"; then
  die "run.sh must not mount the Docker socket"
fi
info "verify: runtime hardening flags are present"

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "${REPO_ROOT}"/scripts/*.sh
  info "verify: shellcheck passed"
else
  warn "shellcheck not installed; skipping shell lint"
fi

if command -v actionlint >/dev/null 2>&1; then
  actionlint
  info "verify: actionlint passed"
else
  warn "actionlint not installed; skipping workflow lint"
fi

info "verify: ok"
