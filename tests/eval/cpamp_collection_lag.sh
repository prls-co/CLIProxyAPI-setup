#!/usr/bin/env bash
# EVAL-004
set -euo pipefail
export LC_ALL=C

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"

: "${CPAMP_BASE_URL:=http://127.0.0.1:18317}"
: "${CPAMP_ADMIN_KEY_FILE:=state/secrets/cpamp-admin-key}"
: "${CPA_BASE_URL:=http://127.0.0.1:8317}"
: "${CPA_API_KEY_FILE:=state/secrets/cpa-api-key}"
: "${MODEL:=gpt-5.4-mini}"

[[ -s "$CPAMP_ADMIN_KEY_FILE" ]] || { printf 'CPAMP admin key file is unavailable\n' >&2; exit 1; }
[[ -s "$CPA_API_KEY_FILE" ]] || { printf 'CPA API key file is unavailable\n' >&2; exit 1; }

artifact_dir=artifacts/P04/EVAL-004
mkdir -p "$artifact_dir"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
admin_key="$(<"$CPAMP_ADMIN_KEY_FILE")"
api_key="$(<"$CPA_API_KEY_FILE")"
samples="$tmp/samples.ndjson"
: >"$samples"

cpamp_get() {
  curl -fsS --max-time 15 -H "Authorization: Bearer $admin_key" "$CPAMP_BASE_URL$1"
}

cpamp_get /status | jq -e '.collector.collector == "running" and (.collector.lastError // "") == ""' >/dev/null

for seed in 6101 6102 6103 6104 6105; do
  correlation_id="eval004-$seed-$(date -u +%Y%m%dT%H%M%SZ)"
  cpamp_get /status >"$tmp/status-before.json"
  baseline_events="$(jq '.events' "$tmp/status-before.json")"
  started_ms="$(( $(date +%s%N) / 1000000 ))"
  jq --arg model "$MODEL" '.model=$model' tests/fixtures/responses/basic.json >"$tmp/request.json"

  curl -fsS -N --max-time 20 \
    -H "Authorization: Bearer $api_key" \
    -H 'Content-Type: application/json' \
    -H "X-Client-Request-Id: $correlation_id" \
    --data-binary @"$tmp/request.json" \
    "$CPA_BASE_URL/v1/responses" >"$tmp/response-$seed.sse"
  grep -q 'response.completed' "$tmp/response-$seed.sse"

  deadline=$((SECONDS + 30))
  found=false
  while (( SECONDS < deadline )); do
    cpamp_get /status >"$tmp/status-after.json"
    if jq -e --argjson baseline "$baseline_events" --argjson started "$started_ms" \
      '.events > $baseline and .collector.lastInsertedAt >= $started and (.collector.lastError // "") == ""' \
      "$tmp/status-after.json" >/dev/null; then
      cpamp_get /v0/management/usage/export >"$tmp/export.ndjson"
      jq -cs --arg model "$MODEL" --argjson started "$started_ms" \
        '[.[] | select(.model == $model and .timestamp_ms >= $started and (.request_id // "") != "")] | sort_by(.timestamp_ms) | last' \
        "$tmp/export.ndjson" >"$tmp/event.json"
      if jq -e 'type == "object" and .failed == false and .created_at_ms > 0 and .timestamp_ms > 0 and .latency_ms >= 0 and .total_tokens > 0' "$tmp/event.json" >/dev/null; then
        found=true
        break
      fi
    fi
    sleep 0.5
  done
  [[ "$found" == true ]] || { printf 'usage event missing for seed %s\n' "$seed" >&2; exit 1; }

  collection_lag_ms="$(jq '([.created_at_ms - (.timestamp_ms + .latency_ms), 0] | max)' "$tmp/event.json")"
  jq -nc \
    --argjson seed "$seed" \
    --arg correlation_id "$correlation_id" \
    --arg request_id "$(jq -r '.request_id' "$tmp/event.json")" \
    --argjson timestamp_ms "$(jq '.timestamp_ms' "$tmp/event.json")" \
    --argjson latency_ms "$(jq '.latency_ms' "$tmp/event.json")" \
    --argjson created_at_ms "$(jq '.created_at_ms' "$tmp/event.json")" \
    --argjson collection_lag_ms "$collection_lag_ms" \
    '{seed:$seed,correlation_id:$correlation_id,cpamp_request_id:$request_id,correlation_method:"serial event-count delta and timestamp window",timestamp_ms:$timestamp_ms,request_latency_ms:$latency_ms,created_at_ms:$created_at_ms,collection_lag_ms:$collection_lag_ms}' \
    >>"$samples"
  printf 'sample %s: collected in %sms\n' "$seed" "$collection_lag_ms"
done

python3 - "$samples" "$artifact_dir/summary.json" <<'PY'
import json
import math
import random
import statistics
import sys

samples = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
lags = [sample["collection_lag_ms"] / 1000 for sample in samples]
ordered = sorted(lags)
p50 = ordered[math.ceil(0.50 * len(ordered)) - 1]
p95 = ordered[math.ceil(0.95 * len(ordered)) - 1]
rng = random.Random(6101)
means = sorted(statistics.mean(rng.choices(lags, k=len(lags))) for _ in range(10000))
summary = {
    "evaluation": "EVAL-004",
    "status": "pass" if len(samples) == 5 and p95 <= 10 else "fail",
    "sample_count": len(samples),
    "collected_count": len(samples),
    "usage_event_completeness": len(samples) / 5,
    "insertion_lag_seconds": {
        "mean": statistics.mean(lags),
        "standard_deviation": statistics.pstdev(lags),
        "p50": p50,
        "p95": p95,
        "bootstrap_mean_95_ci": [means[249], means[9749]],
    },
    "thresholds": {"usage_event_completeness": 1.0, "insertion_lag_p95_seconds": 10},
    "lag_definition": "max(0, CPAMP created_at_ms - (CPA request timestamp_ms + request latency_ms))",
    "samples": samples,
}
with open(sys.argv[2], "w", encoding="utf-8") as handle:
    json.dump(summary, handle, indent=2)
    handle.write("\n")
if summary["status"] != "pass":
    raise SystemExit(1)
PY

printf 'CPAMP collection evaluation: ok\n'
