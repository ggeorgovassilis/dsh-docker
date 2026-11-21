#!/usr/bin/env bash
# Build the DSH API runtime image. Requires Docker and BuildKit only; no host
# Node.js or npm is used.

set -Eeuo pipefail

# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

load_eng
validate_config
require_buildx
require_cmd git

[[ -f "${REPO_ROOT}/package-lock.json" ]] \
  || die "package-lock.json is missing; regenerate it in a container and commit it"
# `npm ci` inside the Dockerfile fails when package.json and the lockfile disagree.

dsh_version="$(pinned_dsh_version)"
tag="$(image_tag)"
image="${IMAGE_REPOSITORY}:${tag}"

if [[ "${tag}" == "latest" ]]; then
  warn "IMAGE_TAG=latest is not recommended; release builds should use the pinned DSH version"
fi

node_ref="$(with_digest "${NODE_IMAGE}" "${NODE_IMAGE_DIGEST}")"
runtime_ref="$(with_digest "${RUNTIME_IMAGE}" "${RUNTIME_IMAGE_DIGEST}")"
revision="${IMAGE_REVISION:-$(git -C "${REPO_ROOT}" rev-parse --short=12 HEAD 2>/dev/null || printf 'unknown')}"
version="${IMAGE_VERSION:-${dsh_version}}"

args=(
  buildx build
  --load
  --file "${REPO_ROOT}/Dockerfile"
  --build-arg "NODE_IMAGE=${node_ref}"
  --build-arg "RUNTIME_IMAGE=${runtime_ref}"
  --build-arg "DSH_VERSION=${dsh_version}"
  --build-arg "IMAGE_VERSION=${version}"
  --build-arg "IMAGE_REVISION=${revision}"
  --tag "${image}"
  "${REPO_ROOT}"
)

if [[ "${RELEASE_BUILD:-0}" == "1" ]]; then
  args+=(--sbom=true --provenance=mode=max)
fi

info "building ${image} (dsh ${dsh_version})"
docker "${args[@]}"

actual_version="$(docker run --rm --entrypoint /app/node_modules/.bin/dsh "${image}" --version)"
if [[ "${actual_version}" != "${dsh_version}" ]]; then
  die "image reports dsh ${actual_version}, expected ${dsh_version}"
fi

info "built ${image} with dsh ${actual_version}"
