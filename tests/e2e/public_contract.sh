#!/usr/bin/env bash
# TEST-010
set -euo pipefail
export LC_ALL=C

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
# shellcheck source=scripts/lib/public_probe.sh
source scripts/lib/public_probe.sh

: "${PUBLIC_BASE_URL:=https://litellm.prls.co/v1}"
: "${PUBLIC_API_KEY_FILE:=state/secrets/cpa-api-key}"
: "${MODEL:=gpt-5.4-mini}"
: "${ARTIFACT_DIR:=artifacts/P05/TEST-010/post-cutover}"
: "${CORRELATION_ID:=test010-$(date -u +%Y%m%dT%H%M%SZ)-$$}"

[[ -s "$PUBLIC_API_KEY_FILE" ]] || { printf 'public API key file is unavailable\n' >&2; exit 1; }
mkdir -p "$ARTIFACT_DIR"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
key="$(<"$PUBLIC_API_KEY_FILE")"
openai_basic_probe "$PUBLIC_BASE_URL" "$PUBLIC_API_KEY_FILE" "$MODEL" "$tmp"
health_path="$OPENAI_PROBE_HEALTH_PATH"
jq -e --arg model "$MODEL" '.data | any(.id == $model)' "$tmp/models.json" >/dev/null
jq --arg model "$MODEL" '{object:(.object // "list"),model_present:(.data | any(.id == $model)),model_count:(.data | length)}' \
  "$tmp/models.json" >"$ARTIFACT_DIR/models.json"

run_response() {
  local name="$1" fixture="tests/fixtures/responses/$1.json"
  jq --arg model "$MODEL" '.model=$model' "$fixture" >"$tmp/$name.request.json"
  curl -fsS -N --max-time 20 \
    -H "Authorization: Bearer $key" \
    -H 'Content-Type: application/json' \
    -H "X-Client-Request-Id: $CORRELATION_ID-$name" \
    --data-binary @"$tmp/$name.request.json" \
    "$PUBLIC_BASE_URL/responses" >"$tmp/$name.raw"
  local completed
  completed="$(sse_completed_event "$tmp/$name.raw")"
  [[ -n "$completed" ]] || { printf 'missing public completed event: %s\n' "$name" >&2; return 1; }
  sse_sanitize_event <<<"$completed" >"$ARTIFACT_DIR/$name.json"
  jq -e '.response.status == "completed" and .response.error == null' <<<"$completed" >/dev/null
  local output_text
  output_text="$(sse_output_text <<<"$completed")"
  [[ -n "$output_text" ]] || output_text="$(sse_stream_output_text "$tmp/$name.raw")"
  if [[ "$name" == basic ]]; then
    grep -q 'CPA_AUTH_READY' <<<"$output_text"
  else
    jq -e '.response.text.format.type == "json_schema" and .response.text.format.name == "cpa_schema_probe" and .response.text.format.strict == true' <<<"$completed" >/dev/null
    jq -e '.sentinel == "STRUCTURED_OUTPUT_ENFORCED"' <<<"$output_text" >/dev/null
  fi
}

sse_sanitize_event <<<"$OPENAI_PROBE_COMPLETED" >"$ARTIFACT_DIR/basic.json"
run_response strict-schema

jq -n \
  --arg correlation_id "$CORRELATION_ID" \
  --arg health_path "$health_path" \
  --arg model "$MODEL" \
  '{test:"TEST-010",status:"pass",public_contract:{health_path:$health_path,bearer_auth:true,model:$model,basic_stream:true,strict_json_schema:true},correlation_id:$correlation_id}' \
  >"$ARTIFACT_DIR/summary.json"

printf 'public CPA contract: ok\n'
