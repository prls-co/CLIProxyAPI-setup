#!/usr/bin/env bash
# TEST-010
set -euo pipefail
export LC_ALL=C

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
# shellcheck source=scripts/lib/public_probe.sh
source scripts/lib/public_probe.sh

: "${PUBLIC_BASE_URL:=https://cpa.prls.co/v1}"
: "${PUBLIC_API_KEY_FILE:=state/secrets/cpa-api-key}"
: "${MODEL:=gpt-5.4-mini}"
: "${CPA_VERSION:=v7.2.80}"
: "${ARTIFACT_DIR:=artifacts/P05/TEST-010/post-cutover}"
: "${CORRELATION_ID:=test010-$(date -u +%Y%m%dT%H%M%SZ)-$$}"

[[ -s "$PUBLIC_API_KEY_FILE" ]] || { printf 'public API key file is unavailable\n' >&2; exit 1; }
mkdir -p "$ARTIFACT_DIR"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
key="$(<"$PUBLIC_API_KEY_FILE")"
cpa_image="$(docker compose config --format json | jq -r '.services["cli-proxy-api"].image')"
openai_basic_probe "$PUBLIC_BASE_URL" "$PUBLIC_API_KEY_FILE" "$MODEL" "$tmp"
health_path="$OPENAI_PROBE_HEALTH_PATH"
jq -e --arg model "$MODEL" '.data | any(.id == $model)' "$tmp/models.json" >/dev/null
jq --arg model "$MODEL" '{object:(.object // "list"),model_present:(.data | any(.id == $model)),model_count:(.data | length)}' \
  "$tmp/models.json" >"$ARTIFACT_DIR/models.json"

run_response() {
  local name="$1" fixture="tests/fixtures/responses/$1.json"
  jq --arg model "$MODEL" '.model=$model' "$fixture" >"$tmp/$name.request.json"
  local metrics http_status first_byte_seconds total_seconds
  metrics="$(curl -sS -N --max-time 20 \
    -H "Authorization: Bearer $key" \
    -H 'Content-Type: application/json' \
    -H "X-Client-Request-Id: $CORRELATION_ID-$name" \
    --data-binary @"$tmp/$name.request.json" \
    -o "$tmp/$name.raw" \
    -w $'%{http_code}\t%{time_starttransfer}\t%{time_total}' \
    "$PUBLIC_BASE_URL/responses")"
  IFS=$'\t' read -r http_status first_byte_seconds total_seconds <<<"$metrics"
  [[ "$http_status" == 200 ]] || { printf 'unexpected public HTTP status for %s: %s\n' "$name" "$http_status" >&2; return 1; }
  local completed output_text streaming
  streaming="$(jq -r '.stream' "$tmp/$name.request.json")"
  if [[ "$streaming" == true ]]; then
    completed="$(sse_completed_event "$tmp/$name.raw")"
    output_text="$(sse_output_text <<<"$completed")"
  else
    completed="$(jq -c '{type:"response.completed",response:.}' "$tmp/$name.raw")"
    output_text="$(jq -r '[.output[]? | select(.type == "message") | .content[]? | select(.type == "output_text") | .text] | join("")' "$tmp/$name.raw")"
  fi
  [[ -n "$completed" ]] || { printf 'missing public completed event: %s\n' "$name" >&2; return 1; }
  sse_sanitize_event <<<"$completed" >"$ARTIFACT_DIR/$name.json"
  jq -e '.response.status == "completed" and .response.error == null' <<<"$completed" >/dev/null
  if [[ "$name" == basic ]]; then
    grep -q 'CPA_AUTH_READY' <<<"$output_text"
  else
    jq -e '.response.text.format.type == "json_schema" and .response.text.format.name == "cpa_schema_probe" and .response.text.format.strict == true' <<<"$completed" >/dev/null
    if [[ "$streaming" == true ]]; then
      grep -q '"type":"response.output_text.done"' "$tmp/$name.raw"
    fi
    jq -e 'type == "object" and keys == ["sentinel"] and .sentinel == "STRUCTURED_OUTPUT_ENFORCED"' <<<"$output_text" >/dev/null
  fi
  printf 'public case %s: ok http=%s first_byte=%ss total=%ss call_id=%s\n' \
    "$name" "$http_status" "$first_byte_seconds" "$total_seconds" "$CORRELATION_ID-$name"
}

sse_sanitize_event <<<"$OPENAI_PROBE_COMPLETED" >"$ARTIFACT_DIR/basic.json"
run_response strict-schema
run_response strict-schema-nonstreaming

jq -n \
  --arg correlation_id "$CORRELATION_ID" \
  --arg health_path "$health_path" \
  --arg model "$MODEL" \
  --arg cpa_version "$CPA_VERSION" \
  --arg cpa_image "$cpa_image" \
  '{test:"TEST-010",status:"pass",public_contract:{health_path:$health_path,bearer_auth:true,model:$model,basic_stream:true,strict_json_schema_streaming:true,strict_json_schema_nonstreaming:true},cpa_version:$cpa_version,cpa_image:$cpa_image,correlation_id:$correlation_id}' \
  >"$ARTIFACT_DIR/summary.json"

printf 'public CPA contract: ok\n'
