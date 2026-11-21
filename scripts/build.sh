#!/usr/bin/env bash
# Build the image. Needs Docker with buildx; no host Node.js.

# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"
load_env

version=$(dsh_version)
[ -f package-lock.json ] || die "package-lock.json is missing"

docker buildx build --load \
  --build-arg "DSH_VERSION=$version" \
  --build-arg "IMAGE_VERSION=${IMAGE_VERSION:-$version}" \
  --build-arg "IMAGE_REVISION=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" \
  --tag "$(image)" .

[ "$(docker run --rm --entrypoint /app/node_modules/.bin/dsh "$(image)" --version)" = "$version" ] \
  || die "image does not run dsh $version"

echo "built $(image) with dsh $version"
