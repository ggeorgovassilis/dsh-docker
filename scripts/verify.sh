#!/usr/bin/env bash
# Verify the base and tool-enabled image variants, tool-state isolation and launch invariants.

# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"
load_env

base_image=$(image)
tools_image=$(tools_image)
version=$(dsh_version)

for image_ref in "$base_image" "$tools_image"; do
  [ "$(docker run --rm --entrypoint /app/node_modules/.bin/dsh "$image_ref" --version)" = "$version" ] \
    || die "$image_ref does not run dsh $version"
  [ "$(docker image inspect --format '{{ index .Config.Labels "io.example.dsh.version" }}' "$image_ref")" = "$version" ] \
    || die "$image_ref label does not match dsh $version"
done

[ "$(docker image inspect --format '{{ index .Config.Labels "io.example.dsh.variant" }}' "$base_image")" = base ] \
  || die "base image has the wrong variant label"
[ "$(docker image inspect --format '{{ index .Config.Labels "io.example.dsh.variant" }}' "$tools_image")" = tools ] \
  || die "tools image has the wrong variant label"

grep -q -- '--read-only' scripts/run-container.sh || die "run-container.sh must use --read-only"
grep -q -- '--cap-drop ALL' scripts/run-container.sh || die "run-container.sh must drop capabilities"
grep -q -- ':/var/run/docker.sock' scripts/run-container.sh || die "the tools profile must support the Docker socket"
grep -q -- 'run-container.sh" tools' scripts/run.sh || die "run.sh must select the tools profile"
grep -q -- 'run-container.sh" base' scripts/run-base.sh || die "run-base.sh must select the base profile"
grep -q -- 'GH_CONFIG_DIR=/home/node/.tools/gh' scripts/run-container.sh \
  || die "the tools wrapper must set the tool-local gh config directory"
grep -q -- 'GIT_CONFIG_GLOBAL=/home/node/.tools/gitconfig' scripts/run-container.sh \
  || die "the tools wrapper must set the tool-local Git config"
grep -q -- 'DOCKER_CONFIG=/home/node/.tools/docker' scripts/run-container.sh \
  || die "the tools wrapper must set the tool-local Docker config"
! grep -q -- 'GH_TOKEN=' scripts/run-container.sh \
  || die "the long-running tools wrapper must not inject GH_TOKEN"

# The base image must not contain agent CLI tooling.
docker run --rm --entrypoint sh "$base_image" -c \
  '! command -v gh && ! command -v git && ! command -v docker && ! command -v rg && ! command -v ps' \
  >/dev/null || die "base image unexpectedly contains agent CLI tools"

# The tools image must contain the extension tools.
docker run --rm --entrypoint sh "$tools_image" -c \
  'gh --version && git --version && docker --version && rg --version && ps --version' \
  >/dev/null || die "tools image is missing one of gh, git, docker, rg or ps"

# pnpm remains part of the base DSH image for profile management.
docker run --rm --entrypoint sh "$base_image" -c 'pnpm --version' >/dev/null \
  || die "base image is missing pnpm"

# Tool state lives in a dedicated volume mount point owned by the runtime UID.
docker run --rm --entrypoint sh "$tools_image" -c \
  'test -d /home/node/.tools && test "$(stat -c %u /home/node/.tools)" = 1000' \
  >/dev/null || die "tools image does not provide a writable /home/node/.tools directory"

# The base wrapper's filtered environment must not leak tool configuration.
runtime_env=$(runtime_env_file)
trap 'rm -f "$runtime_env"' EXIT
docker run --rm --env-file "$runtime_env" --entrypoint sh "$base_image" -c \
  'test -z "${GH_TOKEN:-}" && test -z "${DOCKER_SOCKET:-}" && test -z "${GH_CONFIG_DIR:-}" && test -z "${GIT_CONFIG_GLOBAL:-}" && test -z "${DOCKER_CONFIG:-}"' \
  >/dev/null || die "base container received tool-specific environment variables"
rm -f "$runtime_env"
trap - EXIT

# One configuration file covers both profiles; it must not contain credentials.
! grep -qE '^(GH_TOKEN|GITHUB_TOKEN)=' .env.example || die ".env.example must not contain credentials"
grep -qE '^TOOLS_IMAGE_REPOSITORY=' .env.example || die ".env.example must configure the tools image"
grep -qE '^TOOLS_HOME_VOLUME=' .env.example || die ".env.example must configure the tools volume"
grep -qE '^DOCKER_SOCKET=' .env.example || die ".env.example must configure the Docker socket"
[ ! -e .env.tools.example ] || die ".env.tools.example should not exist; .env configures both profiles"
[ -x scripts/gh-auth.sh ] || die "scripts/gh-auth.sh must be executable"
[ -x scripts/run-base.sh ] || die "scripts/run-base.sh must be executable"

echo "verify: ok ($version; base + tools; tool state isolated)"
