#!/usr/bin/env bash
# Verify both image variants and the launch-script security invariants.

# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"
load_env

core_image=$(image)
tools_image=$(tools_image)
version=$(dsh_version)

for image_ref in "$core_image" "$tools_image"; do
  [ "$(docker run --rm --entrypoint /app/node_modules/.bin/dsh "$image_ref" --version)" = "$version" ] \
    || die "$image_ref does not run dsh $version"
  [ "$(docker image inspect --format '{{ index .Config.Labels "io.example.dsh.version" }}' "$image_ref")" = "$version" ] \
    || die "$image_ref label does not match dsh $version"
done

[ "$(docker image inspect --format '{{ index .Config.Labels "io.example.dsh.variant" }}' "$core_image")" = core ] \
  || die "core image has the wrong variant label"
[ "$(docker image inspect --format '{{ index .Config.Labels "io.example.dsh.variant" }}' "$tools_image")" = tools ] \
  || die "tools image has the wrong variant label"

grep -q -- '--read-only' scripts/run-container.sh || die "run-container.sh must use --read-only"
grep -q -- '--cap-drop ALL' scripts/run-container.sh || die "run-container.sh must drop capabilities"
grep -q -- ':/var/run/docker.sock' scripts/run-container.sh || die "the tools profile must support the Docker socket"

# The pure image must not contain agent CLI tooling.
docker run --rm --entrypoint sh "$core_image" -c \
  '! command -v gh && ! command -v git && ! command -v docker && ! command -v rg && ! command -v ps' \
  >/dev/null || die "pure image unexpectedly contains agent CLI tools"

# The tools image must contain the extension tools.
docker run --rm --entrypoint sh "$tools_image" -c \
  'gh --version && git --version && docker --version && rg --version && ps --version' \
  >/dev/null || die "tools image is missing one of gh, git, docker, rg or ps"

# pnpm remains part of the pure DSH image for profile management.
docker run --rm --entrypoint sh "$core_image" -c 'pnpm --version' >/dev/null \
  || die "pure image is missing pnpm"

# The pure wrapper's filtered environment must not leak tool configuration.
runtime_env=$(runtime_env_file)
trap 'rm -f "$runtime_env"' EXIT
docker run --rm --env-file "$runtime_env" --entrypoint sh "$core_image" -c \
  'test -z "${GH_TOKEN:-}" && test -z "${DOCKER_SOCKET:-}" && test -z "${GIT_CONFIG_GLOBAL:-}"' \
  >/dev/null || die "pure container received tool-specific environment variables"
rm -f "$runtime_env"
trap - EXIT

echo "verify: ok ($version; core + tools)"
