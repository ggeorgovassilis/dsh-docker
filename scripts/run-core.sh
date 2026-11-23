#!/usr/bin/env bash
# Run the pure DSH runtime image.
exec "$(dirname "$0")/run-container.sh" core "$@"
