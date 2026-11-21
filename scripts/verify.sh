#!/usr/bin/env bash
# Check the image matches the pinned DSH version.

# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"
load_env

image=$(image)
version=$(dsh_version)
[ "$(docker run --rm --entrypoint /app/node_modules/.bin/dsh "$image" --version)" = "$version" ] \
  || die "image does not run dsh $version"
[ "$(docker image inspect --format '{{ index .Config.Labels "io.example.dsh.version" }}' "$image")" = "$version" ] \
  || die "image label does not match dsh $version"
grep -q -- '--read-only' scripts/run.sh || die "run.sh must use --read-only"
grep -q -- '--cap-drop ALL' scripts/run.sh || die "run.sh must drop capabilities"
echo "verify: ok ($version)"
