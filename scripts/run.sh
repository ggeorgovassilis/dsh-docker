#!/usr/bin/env bash
# Backwards-compatible alias for the pure runtime.
# Use scripts/run-tools.sh for the tool-enabled image.
exec "$(dirname "$0")/run-core.sh" "$@"
