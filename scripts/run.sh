#!/usr/bin/env bash
# Run the default tool-enabled DSH runtime image.
# Use scripts/run-base.sh for the non-tools base image.
exec "$(dirname "$0")/run-container.sh" tools "$@"
