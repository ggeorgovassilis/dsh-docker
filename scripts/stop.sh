#!/usr/bin/env bash
# Stop the running container without deleting volumes.

set -Eeuo pipefail

# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

load_eng
require_cmd docker

docker stop --time 30 "${CONTAINER_NAME}" >/dev/null
info "stopped ${CONTAINER_NAME}"
