#!/usr/bin/env bash
# Store GitHub CLI credentials in the tool-local volume and configure Git to
# use the resulting gh credential helper.
#
# The token is read from stdin (or prompted for) and is never passed as a
# command-line argument or container environment variable.
#
# Usage:
#   scripts/gh-auth.sh
#   printf '%s\n' "$TOKEN" | scripts/gh-auth.sh --stdin
#   scripts/gh-auth.sh --hostname github.example.com

# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"
load_env

hostname=github.com
stdin_mode=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --stdin)
      stdin_mode=1
      shift
      ;;
    --hostname)
      [ -n "${2:-}" ] || die "--hostname requires a value"
      hostname=$2
      shift 2
      ;;
    -h | --help)
      sed -n '2,13p' "$0"
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

tools_image=$(tools_image)
docker image inspect "$tools_image" >/dev/null 2>&1 || "$(dirname "$0")/build.sh"
ensure_tools_volume "$tools_image"

token=
trap 'unset token' EXIT

if [ "$stdin_mode" = 1 ]; then
  IFS= read -r token || [ -n "$token" ] || die "no token on stdin"
else
  read -rsp "GitHub token for ${hostname}: " token
  echo
fi
[ -n "$token" ] || die "empty token"

common_args=(
  --rm
  --read-only
  --tmpfs '/tmp:rw,noexec,nosuid,nodev,size=64m'
  --cap-drop ALL
  --security-opt 'no-new-privileges:true'
  --user 1000:1000
  --env HOME=/home/node
  --env "GH_CONFIG_DIR=/home/node/.tools/gh"
  --env "GIT_CONFIG_GLOBAL=/home/node/.tools/gitconfig"
  --env GH_PROMPT_DISABLED=1
  --env GH_NO_UPDATE_NOTIFIER=1
  --env NO_COLOR=1
  --volume "$TOOLS_HOME_VOLUME:/home/node/.tools"
  --entrypoint /usr/bin/gh
  "$tools_image"
)

if ! printf '%s\n' "$token" | docker run -i "${common_args[@]}" \
      auth login --hostname "$hostname" --with-token; then
  die "gh auth login failed; use a token with the scopes gh requires (for example repo and read:org)"
fi

docker run "${common_args[@]}" auth setup-git --hostname "$hostname" >/dev/null

login=$(docker run "${common_args[@]}" api user --jq .login)
printf 'GitHub credentials stored in %s for %s as %s\n' \
  "$TOOLS_HOME_VOLUME" "$hostname" "$login"
