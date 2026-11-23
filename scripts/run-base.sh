#!/usr/bin/env bash
# Run the base DSH runtime image without agent CLI tools.
exec "$(dirname "$0")/run-container.sh" base "$@"
