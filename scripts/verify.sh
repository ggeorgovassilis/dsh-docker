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
grep -q -- ':/var/run/docker.sock' scripts/run.sh || die "run.sh must mount the Docker socket"
docker run --rm --entrypoint sh "$image" -c 'docker --version && gh --version && git --version && pnpm --version' >/dev/null \
  || die "image is missing docker, gh, git or pnpm"

# .env is passed to the container with --env-file, so its variables must reach
# the container environment (and the commands the agent runs).
if [ -n "${GH_TOKEN:-}" ]; then
  docker run --rm --env-file .env --entrypoint sh "$image" -c 'test -n "$GH_TOKEN"' \
    || die "GH_TOKEN from .env is not visible in the container"
fi
echo "verify: ok ($version)"
