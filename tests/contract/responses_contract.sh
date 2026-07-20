#!/usr/bin/env bash
# TEST-006
set -euo pipefail
export LC_ALL=C

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
# shellcheck source=scripts/lib/sse.sh
source scripts/lib/sse.sh

: "${CPA_BASE_URL:=http://127.0.0.1:8317}"
: "${CPA_API_KEY_FILE:=state/secrets/cpa-api-key}"
: "${MODEL:=gpt-5.4-mini}"
: "${CPA_VERSION:=v7.2.80}"
: "${CASE_FILTER:=}"
: "${CORRELATION_ID:=test006-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
[[ -s "$CPA_API_KEY_FILE" ]] || { printf 'CPA API key file is unavailable\n' >&2; exit 1; }

mkdir -p artifacts/P03/TEST-006
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
api_key="$(<"$CPA_API_KEY_FILE")"
cpa_image="$(docker compose config --format json | jq -r '.services["cli-proxy-api"].image')"
if [[ -z "$CASE_FILTER" ]]; then
  metadata_path=artifacts/P03/TEST-006/metadata.ndjson
  request_hashes_path=artifacts/P03/TEST-006/request-hashes.txt
else
  metadata_path="$tmp/metadata.ndjson"
  request_hashes_path="$tmp/request-hashes.txt"
fi
: >"$metadata_path"
: >"$request_hashes_path"

run_case() {
  local name="$1"
  local fixture="tests/fixtures/responses/$name.json"
  if [[ -n "$CASE_FILTER" && "$CASE_FILTER" != "$name" ]]; then
    return
  fi
  jq --arg model "$MODEL" '.model = $model' "$fixture" >"$tmp/$name.request.json"
  local call_id="$CORRELATION_ID-$name"
  local metrics http_status first_byte_seconds total_seconds
  metrics="$(curl -sS -N --max-time 20 \
    -H "Authorization: Bearer $api_key" \
    -H 'Content-Type: application/json' \
    -H "X-Client-Request-Id: $call_id" \
    --data-binary @"$tmp/$name.request.json" \
    -o "$tmp/$name.raw" \
    -w $'%{http_code}\t%{time_starttransfer}\t%{time_total}' \
    "$CPA_BASE_URL/v1/responses")"
  IFS=$'\t' read -r http_status first_byte_seconds total_seconds <<<"$metrics"
  [[ "$http_status" == 200 ]] || { printf 'unexpected HTTP status for %s: %s\n' "$name" "$http_status" >&2; return 1; }

  local completed output_text streaming
  streaming="$(jq -r '.stream' "$tmp/$name.request.json")"
  if [[ "$streaming" == true ]]; then
    completed="$(sse_completed_event "$tmp/$name.raw")"
    output_text="$(sse_output_text <<<"$completed")"
  else
    completed="$(jq -c '{type:"response.completed",response:.}' "$tmp/$name.raw")"
    output_text="$(jq -r '[.output[]? | select(.type == "message") | .content[]? | select(.type == "output_text") | .text] | join("")' "$tmp/$name.raw")"
  fi
  [[ -n "$completed" ]] || { printf 'missing completed event: %s\n' "$name" >&2; return 1; }
  jq -e '.response.status == "completed" and .response.error == null' <<<"$completed" >/dev/null
  sse_sanitize_event <<<"$completed" >"artifacts/P03/TEST-006/$name.json"

  case "$name" in
    basic)
      grep -q 'CPA_AUTH_READY' <<<"$(sse_output_text <<<"$completed")"
      ;;
    strict-schema)
      jq -e '.response.text.format.type == "json_schema" and .response.text.format.name == "cpa_schema_probe" and .response.text.format.strict == true' <<<"$completed" >/dev/null
      grep -q '"type":"response.output_text.done"' "$tmp/$name.raw"
      jq -e 'type == "object" and keys == ["sentinel"] and .sentinel == "STRUCTURED_OUTPUT_ENFORCED"' <<<"$output_text" >/dev/null
      ;;
    strict-schema-nonstreaming)
      jq -e '.response.text.format.type == "json_schema" and .response.text.format.name == "cpa_schema_probe" and .response.text.format.strict == true' <<<"$completed" >/dev/null
      jq -e 'type == "object" and keys == ["sentinel"] and .sentinel == "STRUCTURED_OUTPUT_ENFORCED"' <<<"$output_text" >/dev/null
      ;;
    translation-filtering)
      jq -e '.response.text.format.type == "json_schema" and .response.text.format.name == "cpa_translation_probe" and .response.text.format.strict == true and .response.max_output_tokens == null' <<<"$completed" >/dev/null
      grep -q '"type":"response.output_text.done"' "$tmp/$name.raw"
      jq -e 'type == "object" and keys == ["sentinel"] and .sentinel == "TEXT_PRESERVED_UNSUPPORTED_FIELD_REMOVED"' <<<"$output_text" >/dev/null
      ;;
    web-search)
      grep -q 'response.web_search_call.completed' "$tmp/$name.raw"
      jq -e '.response.tools | any(.type == "web_search")' <<<"$completed" >/dev/null
      ;;
    web-search-schema)
      grep -q 'response.web_search_call.completed' "$tmp/$name.raw"
      jq -e '.response.text.format.type == "json_schema" and (.response.tools | any(.type == "web_search"))' <<<"$completed" >/dev/null
      sse_output_text <<<"$completed" | jq -e '.domain | type == "string" and length > 0' >/dev/null
      ;;
    client-tools)
      jq -e '.response.tools | length == 0' <<<"$completed" >/dev/null
      grep -q 'NO_EXTRA_TOOLS' <<<"$(sse_output_text <<<"$completed")"
      ;;
  esac
  local response_model
  response_model="$(jq -r '.response.model' <<<"$completed")"
  jq -nc \
    --arg case "$name" \
    --arg call_id "$call_id" \
    --arg model "$response_model" \
    --arg cpa_version "$CPA_VERSION" \
    --arg cpa_image "$cpa_image" \
    --argjson http_status "$http_status" \
    --argjson first_byte_seconds "$first_byte_seconds" \
    --argjson total_seconds "$total_seconds" \
    '{case:$case,call_id:$call_id,http_status:$http_status,model:$model,cpa_version:$cpa_version,cpa_image:$cpa_image,first_byte_seconds:$first_byte_seconds,total_seconds:$total_seconds}' \
    >>"$metadata_path"
  sha256sum "$tmp/$name.request.json" | awk -v name="$name" '{print name, $1}' >>"$request_hashes_path"
  printf 'case %s: ok http=%s first_byte=%ss total=%ss model=%s cpa=%s call_id=%s\n' \
    "$name" "$http_status" "$first_byte_seconds" "$total_seconds" "$response_model" "$CPA_VERSION" "$call_id"
}

run_case basic
run_case strict-schema
run_case strict-schema-nonstreaming
run_case translation-filtering
run_case web-search
run_case web-search-schema
run_case client-tools
printf 'Responses contract: ok\n'
