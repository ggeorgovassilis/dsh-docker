#!/usr/bin/env bash
# Smoke-test both image variants with a fake DSH (free), then optionally with
# a real model when RUN_LIVE_SMOKE=1.

# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"
load_env

base_image=$(image)
tools_image=$(tools_image)
for image_ref in "$base_image" "$tools_image"; do
  docker image inspect "$image_ref" >/dev/null 2>&1 || die "image not found: $image_ref (run scripts/build.sh)"
done

logs=$(mktemp)
runtime_env=$(runtime_env_file)
trap 'docker rm --force dsh-smoke >/dev/null 2>&1; rm -f "$logs" "$runtime_env"' EXIT

start() {
  local image_ref=$1
  shift
  docker rm --force dsh-smoke >/dev/null 2>&1 || true
  docker run --detach --name dsh-smoke \
    --read-only --tmpfs '/tmp:rw,noexec,nosuid,nodev,size=256m' \
    --cap-drop ALL --user 1000:1000 --publish 127.0.0.1::3080 \
    "$@" "$image_ref" >/dev/null
  port=$(docker port dsh-smoke 3080/tcp | sed 's/.*://')
  for _ in $(seq 1 240); do
    curl -sf "http://127.0.0.1:$port/readyz" >/dev/null && return
    sleep 0.5
  done
  docker logs dsh-smoke >&2
  die "container never became ready"
}

prompt() {
  curl -sS -X POST "http://127.0.0.1:$port/v1/rpc" -H 'content-type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"session/prompt","params":{"sessionId":"'"$2"'","contentBlocks":[{"type":"text","text":"'"$1"'"}]}}'
}

fake_smoke() {
  local label=$1 image_ref=$2
  echo "smoke: fake DSH ($label)"
  start "$image_ref" \
    --env DSH_BIN=/test/fake-dsh.mjs --env DSH_PROVIDER=x --env DSH_MODEL=x \
    --mount "type=bind,source=$PWD/test,target=/test,readonly"

  curl -sS -N --max-time 10 "http://127.0.0.1:$port/v1/events" >"$logs" &
  sse=$!
  sleep 0.5
  prompt "hello" "fake-$$" | grep -q messageId || die "session/prompt failed ($label)"
  for _ in $(seq 1 40); do grep -q '"status":"idle"' "$logs" && break; sleep 0.25; done
  grep -q '"method":"session.event"' "$logs" || die "no session.event over SSE ($label)"
  grep -q '"status":"idle"' "$logs" || die "session never went idle ($label)"
  kill "$sse" 2>/dev/null || true
  wait "$sse" 2>/dev/null || true
  curl -sS "http://127.0.0.1:$port/metrics" | grep -q '^dsh_bridge_dsh_up' || die "no metrics ($label)"
  echo "smoke: ok ($label)"
}

fake_smoke base "$base_image"
fake_smoke tools "$tools_image"

[ "${RUN_LIVE_SMOKE:-0}" = 1 ] || { echo "smoke: skipping live model (RUN_LIVE_SMOKE=1 to enable)"; exit 0; }

echo "smoke: live model (costs credits)"
start "$base_image" --env-file "$runtime_env" \
  --volume "$WORKSPACE_HOST:$WORKSPACE" --volume "$DSH_HOME_VOLUME:/home/node/.dsh"
curl -sS -N --max-time 180 "http://127.0.0.1:$port/v1/events" >"$logs" &
sse=$!
sleep 0.5
prompt "Reply with the single word OK" "live-$$" | grep -q messageId || die "live prompt failed"
for _ in $(seq 1 360); do grep -q '"status":"idle"' "$logs" && break; sleep 0.5; done
grep -q '"status":"idle"' "$logs" || die "live model never went idle"
kill "$sse" 2>/dev/null || true
wait "$sse" 2>/dev/null || true
echo "smoke: live ok"
