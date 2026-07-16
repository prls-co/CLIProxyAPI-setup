#!/usr/bin/env bash
# TEST-007
set -euo pipefail
export LC_ALL=C

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"

: "${CPAMP_BASE_URL:=http://127.0.0.1:18317}"
: "${CPAMP_ADMIN_KEY_FILE:=state/secrets/cpamp-admin-key}"
: "${CPA_BASE_URL:=http://127.0.0.1:8317}"
: "${CPA_API_KEY_FILE:=state/secrets/cpa-api-key}"
: "${MODEL:=gpt-5.4-mini}"
: "${ARTIFACT_PATH:=artifacts/P04/TEST-007-green.json}"
: "${CORRELATION_ID:=test007-$(date -u +%Y%m%dT%H%M%SZ)-$$}"

[[ -s "$CPAMP_ADMIN_KEY_FILE" ]] || { printf 'CPAMP admin key file is unavailable\n' >&2; exit 1; }
[[ -s "$CPA_API_KEY_FILE" ]] || { printf 'CPA API key file is unavailable\n' >&2; exit 1; }

mkdir -p "$(dirname "$ARTIFACT_PATH")"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
admin_key="$(<"$CPAMP_ADMIN_KEY_FILE")"
api_key="$(<"$CPA_API_KEY_FILE")"

cpamp_get() {
  curl -fsS --max-time 10 -H "Authorization: Bearer $admin_key" "$CPAMP_BASE_URL$1"
}

curl -fsS --max-time 10 "$CPAMP_BASE_URL/health" | jq -e '.ok == true' >/dev/null
cpamp_get /status >"$tmp/before.json"

collector="$(jq -r '.collector.collector // ""' "$tmp/before.json")"
if [[ "$collector" != "running" ]]; then
  jq -n \
    --arg status "red" \
    --arg collector "$collector" \
    --arg correlation_id "$CORRELATION_ID" \
    '{test:"TEST-007",status:$status,collector:$collector,correlation_id:$correlation_id,reason:"collector is not running"}' \
    >"$ARTIFACT_PATH"
  printf 'CPAMP collector is not running: %s\n' "$collector" >&2
  exit 1
fi

baseline_events="$(jq -r '.events' "$tmp/before.json")"
baseline_inserted="$(jq -r '.collector.totalInserted' "$tmp/before.json")"
started_ms="$(( $(date +%s%N) / 1000000 ))"

jq --arg model "$MODEL" --arg tag "$CORRELATION_ID" \
  '.model=$model | .input="Reply with exactly CPA_USAGE_READY. The client correlation tag is carried only in the request header."' \
  tests/fixtures/responses/basic.json >"$tmp/request.json"

curl -fsS -N --max-time 20 \
  -H "Authorization: Bearer $api_key" \
  -H 'Content-Type: application/json' \
  -H "X-Client-Request-Id: $CORRELATION_ID" \
  --data-binary @"$tmp/request.json" \
  "$CPA_BASE_URL/v1/responses" >"$tmp/response.sse"
grep -q 'response.completed' "$tmp/response.sse"

deadline=$((SECONDS + 30))
while (( SECONDS < deadline )); do
  cpamp_get /status >"$tmp/after.json"
  if jq -e \
    --argjson events "$baseline_events" \
    --argjson inserted "$baseline_inserted" \
    '.events > $events and .collector.totalInserted > $inserted and .collector.lastConsumedAt > 0 and .collector.lastInsertedAt > 0 and (.collector.lastError // "") == ""' \
    "$tmp/after.json" >/dev/null; then
    break
  fi
  sleep 0.5
done

jq -e \
  --argjson events "$baseline_events" \
  --argjson inserted "$baseline_inserted" \
  '.events > $events and .collector.totalInserted > $inserted and .collector.lastConsumedAt > 0 and .collector.lastInsertedAt > 0 and (.collector.lastError // "") == ""' \
  "$tmp/after.json" >/dev/null

cpamp_get /v0/management/usage/export >"$tmp/export.ndjson"
jq -cs --arg model "$MODEL" --argjson started "$started_ms" \
  '[.[] | select(.model == $model and .timestamp_ms >= $started and (.request_id // "") != "")] | sort_by(.timestamp_ms) | last' \
  "$tmp/export.ndjson" >"$tmp/event.json"
jq -e 'type == "object" and (.request_id | length > 0) and .failed == false and .latency_ms >= 0 and .total_tokens > 0' "$tmp/event.json" >/dev/null

jq -n \
  --arg correlation_id "$CORRELATION_ID" \
  --arg request_id "$(jq -r '.request_id' "$tmp/event.json")" \
  --arg model "$(jq -r '.model' "$tmp/event.json")" \
  --argjson baseline_events "$baseline_events" \
  --argjson final_events "$(jq '.events' "$tmp/after.json")" \
  --argjson last_consumed_at "$(jq '.collector.lastConsumedAt' "$tmp/after.json")" \
  --argjson last_inserted_at "$(jq '.collector.lastInsertedAt' "$tmp/after.json")" \
  --argjson latency_ms "$(jq '.latency_ms' "$tmp/event.json")" \
  --argjson total_tokens "$(jq '.total_tokens' "$tmp/event.json")" \
  '{test:"TEST-007",status:"pass",correlation_id:$correlation_id,cpamp_request_id:$request_id,correlation_method:"serial event-count delta and timestamp window",model:$model,failed:false,baseline_events:$baseline_events,final_events:$final_events,last_consumed_at:$last_consumed_at,last_inserted_at:$last_inserted_at,latency_ms:$latency_ms,total_tokens:$total_tokens}' \
  >"$ARTIFACT_PATH"

printf 'CPAMP request collection: ok\n'
