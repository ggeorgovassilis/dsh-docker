#!/usr/bin/env bash
# Update the pinned DSH version, regenerate the lockfile, build, and smoke test.
#
# usage: scripts/update-dsh.sh [next|latest|alpha|<exact version>]
#
# Does not commit. Prints the diff and the rollback tag.

set -Eeuo pipefail

# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

load_eng
require_buildx
require_cmd git

channel="${1:-next}"
current="$(pinned_dsh_version)"
node_ref="$(with_digest "${NODE_IMAGE}" "${NODE_IMAGE_DIGEST}")"

info "resolving @deepseek-ai/dsh@${channel} in a disposable container"
resolved="$(
  docker run --rm --entrypoint npm "${node_ref}" \
    view "@deepseek-ai/dsh@${channel}" version 2>/dev/null | tail -n 1 | tr -d '[:space:]'
)"

[[ "${resolved}" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] \
  || die "could not resolve '@deepseek-ai/dsh@${channel}' to an exact version (got '${resolved}')"

if [[ "${resolved}" == "${current}" ]]; then
  die "already at @deepseek-ai/dsh ${current}; nothing to do"
fi

info "updating @deepseek-ai/dsh ${current} -> ${resolved}"

sed -i "s|\"@deepseek-ai/dsh\": *\"${current}\"|\"@deepseek-ai/dsh\": \"${resolved}\"|" \
  "${REPO_ROOT}/package.json"
grep -q "\"@deepseek-ai/dsh\": \"${resolved}\"" "${REPO_ROOT}/package.json" \
  || die "failed to update package.json"

if grep -q '^IMAGE_TAG=' "${ENG_FILE}"; then
  sed -i "s|^IMAGE_TAG=.*|IMAGE_TAG=${resolved}|" "${ENG_FILE}"
else
  printf '\nIMAGE_TAG=%s\n' "${resolved}" >>"${ENG_FILE}"
fi

# .env.example normally leaves IMAGE_TAG empty (the default follows the pin),
# but keep an operator-hardcoded value in sync if one is present.
if grep -Eq '^IMAGE_TAG=.+' "${REPO_ROOT}/.env.example"; then
  sed -i "s|^IMAGE_TAG=.*|IMAGE_TAG=${resolved}|" "${REPO_ROOT}/.env.example"
fi

info "regenerating package-lock.json in a disposable container"
docker run --rm \
  --user "$(id -u):$(id -g)" \
  --env HOME=/tmp \
  --env npm_config_cache=/tmp/.npm \
  --volume "${REPO_ROOT}:/app" \
  --workdir /app \
  "${node_ref}" \
  npm install --package-lock-only --ignore-scripts --no-audit --no-fund

"${REPO_ROOT}/scripts/build.sh"
"${REPO_ROOT}/scripts/smoke.sh"

info ""
info "diff:"
git -C "${REPO_ROOT}" --no-pager diff --stat -- package.json package-lock.json .env.example || true
info ""
info "rollback tag: ${IMAGE_REPOSITORY}:${current}"
info "Review the diff, run the live smoke test if credentials allow, then commit."
