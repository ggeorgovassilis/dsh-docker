#!/usr/bin/env bash
# Stop and remove a runtime container. Volumes are kept.
#
# Usage: scripts/stop.sh [core|tools|all|<container-name>]
# Default: core.

set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi
: "${CONTAINER_NAME:=dsh}"
: "${TOOLS_CONTAINER_NAME:=dsh-tools}"

case "${1:-core}" in
  core) names=("$CONTAINER_NAME") ;;
  tools) names=("$TOOLS_CONTAINER_NAME") ;;
  all) names=("$CONTAINER_NAME" "$TOOLS_CONTAINER_NAME") ;;
  -h | --help)
    echo "usage: $0 [core|tools|all|<container-name>]"
    exit 0
    ;;
  *) names=("$1") ;;
esac

for name in "${names[@]}"; do
  docker rm --force "$name" >/dev/null 2>&1 || true
done
