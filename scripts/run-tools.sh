#!/usr/bin/env bash
# Run the DSH runtime extended with agent CLI tools.
exec "$(dirname "$0")/run-container.sh" tools "$@"
