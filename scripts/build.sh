#!/usr/bin/env bash
# Build both the pure DSH image and the tool-enabled extension.
# Needs Docker with buildx; no host Node.js.

# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"
load_env

version=$(dsh_version)
core_image=$(image)
tools_image=$(tools_image)
revision=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
image_version=${IMAGE_VERSION:-$version}

[ -f package-lock.json ] || die "package-lock.json is missing"

docker buildx build --load \
  --build-arg "DSH_VERSION=$version" \
  --build-arg "IMAGE_VERSION=$image_version" \
  --build-arg "IMAGE_REVISION=$revision" \
  --tag "$core_image" .

# The tools image is a derived image, not a second independent DSH build.
docker buildx build --load \
  --build-arg "CORE_IMAGE=$core_image" \
  --build-arg "IMAGE_VERSION=$image_version" \
  --build-arg "IMAGE_REVISION=$revision" \
  --tag "$tools_image" \
  -f Dockerfile.tools .

for built in "$core_image" "$tools_image"; do
  [ "$(docker run --rm --entrypoint /app/node_modules/.bin/dsh "$built" --version)" = "$version" ] \
    || die "$built does not run dsh $version"
done

echo "built $core_image with dsh $version (pure)"
echo "built $tools_image with dsh $version (tools)"
