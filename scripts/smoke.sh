#!/usr/bin/env bash
# Smoke test the built image.
#
# Layer 1 (always): deterministic fake-DSH integration test, no model calls.
# Layer 2 (opt-in): real model smoke, requires RUN_LIVE_SMOKE=1 and a key.

set -Eeuo pipefail

# shellcheck source=scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

load_eng
require_cmd docker
require_cmd curl

image="${1:-$(image_name)}"
require_image "${image}"

suffix="$$-${RANDOM}"
fake_container="dsh-api-smoke-fake-${suffix}"
fake_volume="dsh-api-smoke-home-${suffix}"
live_container="dsh-api-smoke-live-${suffix}"
live_volume="dsh-api-smoke-live-home-${suffix}"
sse_log="$(mktemp "${TMPDIR:-/tmp}/dsh-api-sse.XXXXXX")"
live_sse_log="$(mktemp "${TMPDIR:-/tmp}/dsh-api-live-sse.XXXXXX")"
env_file=''

cleanup() {
  docker rm --force "${fake_container}" >/dev/null 2>&1 || true
  docker volume rm "${fake_volume}" >/dev/null 2>&1 || true
  docker rm --force "${live_container}" >/dev/null 2>&1 || true
  docker volume rm "${live_volume}" >/dev/null 2>&1 || true
  cleanup_file "${sse_log}"
  cleanup_file "${live_sse_log}"
  if [[ -n "${env_file}" ]]; then
    cleanup_file "${env_file}"
  fi
  return 0
}
trap cleanup EXIT INT TERM

port_of() {
  local container="$1"
  docker port "${container}" 8080/tcp | head -n 1 | sed 's/.*://'
}

wait_ready() {
  local base="$1"
  local container="$2"
  local attempts="$3"
  local code=''
  local i
  for ((i = 1; i <= attempts; i++)); do
    code="$(curl -s -o /dev/null -w '%{http_code}' "${base}/readyz" 2>/dev/null || true)"
    [[ "${code}" == "200" ]] && return 0
    if [[ "$(docker inspect -f '{{.State.Running}}' -- "${container}" 2>/dev/null || printf false)" != "true" ]]; then
      docker logs --tail 50 "${container}" >&2 || true
      die "container ${container} exited before becoming ready"
    fi
    sleep 0.5
  done
  docker logs --tail 50 "${container}" >&2 || true
  die "/readyz did not return 200 (last status: ${code:-none})"
}

assert_metrics() {
  local base="$1"
  local metrics
  metrics="$(curl -sS "${base}/metrics")"
  local name
  for name in \
    dsh_bridge_http_requests_total \
    dsh_bridge_http_request_duration_seconds \
    dsh_bridge_rpc_requests_total \
    dsh_bridge_rpc_request_duration_seconds \
    dsh_bridge_rpc_inflight \
    dsh_bridge_sse_clients \
    dsh_bridge_events_total \
    dsh_bridge_dsh_up \
    dsh_bridge_dsh_restarts_total \
    dsh_bridge_process_resident_memory_bytes; do
    grep -q "^# HELP ${name} " <<<"${metrics}" || die "missing metric: ${name}"
  done
}

info "smoke: starting fake-DSH container from ${image}"
docker run --detach \
  --name "${fake_container}" \
  --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,nodev,size=64m \
  --cap-drop ALL \
  --security-opt no-new-privileges:true \
  --pids-limit 256 \
  --user 1000:1000 \
  --publish 127.0.0.1::8080 \
  --env HTTP_BIND=0.0.0.0 \
  --env DSH_BIN=/test/fake-dsh.mjs \
  --env DSH_PROVIDER=deepseek-official \
  --env DSH_MODEL=fake-model \
  --env DSH_CWD=/workspace \
  --env DSH_HOME=/home/node/.dsh \
  --env LOG_LEVEL=error \
  --mount "type=bind,source=${REPO_ROOT}/test,target=/test,readonly" \
  --volume "${fake_volume}:/home/node/.dsh" \
  "${image}" >/dev/null

fake_port="$(port_of "${fake_container}")"
base="http://127.0.0.1:${fake_port}"
wait_ready "${base}" "${fake_container}" 120
info "smoke: /readyz is 200"

status="$(curl -sS "${base}/v1/status")"
grep -q '"ready":true' <<<"${status}" || die "/v1/status does not report ready: ${status}"
grep -q '"name":"deepseek-harness-sdk-runtime"' <<<"${status}" || die "/v1/status is missing serverInfo"

curl -sS -N --max-time 10 "${base}/v1/events" >"${sse_log}" 2>/dev/null &
sse_pid=$!
sleep 0.5

rpc_response="$(curl -sS -X POST "${base}/v1/rpc" \
  -H 'content-type: application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"session/prompt","params":{"sessionId":"smoke","contentBlocks":[{"type":"text","text":"list the files"}]}}')"
grep -q '"messageId"' <<<"${rpc_response}" || die "session/prompt did not return a messageId: ${rpc_response}"

wait_deadline=$((SECONDS + 10))
while (( SECONDS < wait_deadline )); do
  grep -q '"status":"idle"' "${sse_log}" 2>/dev/null && break
  sleep 0.25
done

wait "${sse_pid}" 2>/dev/null || true
grep -q '"method":"session.event"' "${sse_log}" || die "SSE did not receive session.event"
grep -q '"method":"session.status"' "${sse_log}" || die "SSE did not receive session.status"
grep -q '"status":"idle"' "${sse_log}" || die "SSE did not receive an idle transition"
info "smoke: JSON-RPC prompt and SSE notifications work"

assert_metrics "${base}"
info "smoke: required Prometheus metrics are present"

docker stop --time 10 "${fake_container}" >/dev/null 2>&1 || true
info "smoke: fake-DSH layer passed"

if [[ "${RUN_LIVE_SMOKE:-0}" != "1" ]]; then
  info "smoke: skipping live model layer (set RUN_LIVE_SMOKE=1 to enable)"
  exit 0
fi

[[ -n "${DEEPSEEK_API_KEY:-}" && "${DEEPSEEK_API_KEY}" != "replace-me" ]] \
  || die "RUN_LIVE_SMOKE=1 requires DEEPSEEK_API_KEY"

env_file="$(runtime_env_file)"
info "smoke: starting live container (this consumes model credits)"
docker run --detach \
  --name "${live_container}" \
  --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,nodev,size=256m \
  --cap-drop ALL \
  --security-opt no-new-privileges:true \
  --pids-limit 512 \
  --user 1000:1000 \
  --publish 127.0.0.1::8080 \
  --env HTTP_BIND=0.0.0.0 \
  --env-file "${env_file}" \
  --volume "${live_volume}:/home/node/.dsh" \
  --volume "${WORKSPACE_HOST}:${WORKSPACE}" \
  "${image}" >/dev/null

live_port="$(port_of "${live_container}")"
live_base="http://127.0.0.1:${live_port}"
wait_ready "${live_base}" "${live_container}" 240

curl -sS -N --max-time 180 "${live_base}/v1/events" >"${live_sse_log}" 2>/dev/null &
live_sse_pid=$!
sleep 0.5

live_response="$(curl -sS -X POST "${live_base}/v1/rpc" \
  -H 'content-type: application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"session/prompt","params":{"sessionId":"live-smoke","contentBlocks":[{"type":"text","text":"Reply with the single word OK"}]}}')"
grep -q '"messageId"' <<<"${live_response}" || die "live session/prompt failed: ${live_response}"

deadline=$((SECONDS + 180))
while (( SECONDS < deadline )); do
  grep -q '"status":"idle"' "${live_sse_log}" 2>/dev/null && break
  sleep 0.5
done

kill "${live_sse_pid}" >/dev/null 2>&1 || true
wait "${live_sse_pid}" 2>/dev/null || true

grep -q '"status":"idle"' "${live_sse_log}" || die "live model did not return to idle"
grep -Eq '"text":"[^"]+"' "${live_sse_log}" || die "live model produced no assistant text"

docker stop --time 30 "${live_container}" >/dev/null 2>&1 || true
info "smoke: live model layer passed"
