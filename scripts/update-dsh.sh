#!/usr/bin/env bash
# Move the pinned DSH version, rebuild, and smoke-test.
# usage: scripts/update-dsh.sh [next|latest|alpha|<version>]

# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"
load_env

channel="${1:-next}"
current=$(dsh_version)
node=node:24-trixie

resolved=$(docker run --rm --entrypoint npm "$node" view "@deepseek-ai/dsh@$channel" version | tail -1 | tr -d '[:space:]')
[ -n "$resolved" ] || die "could not resolve @deepseek-ai/dsh@$channel"
[ "$resolved" != "$current" ] || die "already at dsh $current"

echo "updating dsh $current -> $resolved"
sed -i "s|\"@deepseek-ai/dsh\": *\"$current\"|\"@deepseek-ai/dsh\": \"$resolved\"|" package.json
sed -i "s|^IMAGE_TAG=.*|IMAGE_TAG=$resolved|" .env

docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -v "$PWD":/app -w /app "$node" \
  npm install --package-lock-only --ignore-scripts --no-audit --no-fund

scripts/build.sh
scripts/smoke.sh

echo
git --no-pager diff --stat
echo "rollback: ${IMAGE_REPOSITORY}:${current}"
