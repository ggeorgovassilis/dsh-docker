#!/usr/bin/env bash
# Build both the base DSH image and the tool-enabled extension.
# Needs Docker with buildx; no host Node.js.

# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"
load_env

version=$(dsh_version)
base_image=$(image)
tools_image=$(tools_image)
revision=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
image_version=${IMAGE_VERSION:-$version}

[ -f package-lock.json ] || die "package-lock.json is missing"

docker buildx build --load \
  --build-arg "DSH_VERSION=$version" \
  --build-arg "IMAGE_VERSION=$image_version" \
  --build-arg "IMAGE_REVISION=$revision" \
  --tag "$base_image" .

# The tools image is derived from the base image, not an independent DSH build.
docker buildx build --load \
  --build-arg "BASE_IMAGE=$base_image" \
  --build-arg "IMAGE_VERSION=$image_version" \
  --build-arg "IMAGE_REVISION=$revision" \
  --tag "$tools_image" \
  -f Dockerfile.tools .

for built in "$base_image" "$tools_image"; do
  [ "$(docker run --rm --entrypoint /app/node_modules/.bin/dsh "$built" --version)" = "$version" ] \
    || die "$built does not run dsh $version"
done

echo "built $base_image with dsh $version (base)"
echo "built $tools_image with dsh $version (tools)"
