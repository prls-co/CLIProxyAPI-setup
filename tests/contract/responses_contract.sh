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
: "${CASE_FILTER:=}"
: "${CORRELATION_ID:=}"
[[ -s "$CPA_API_KEY_FILE" ]] || { printf 'CPA API key file is unavailable\n' >&2; exit 1; }

mkdir -p artifacts/P03/TEST-006
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
api_key="$(<"$CPA_API_KEY_FILE")"

run_case() {
  local name="$1"
  local fixture="tests/fixtures/responses/$name.json"
  if [[ -n "$CASE_FILTER" && "$CASE_FILTER" != "$name" ]]; then
    return
  fi
  jq --arg model "$MODEL" '.model = $model' "$fixture" >"$tmp/$name.request.json"
  curl_args=(-fsS -N --max-time 20)
  if [[ -n "$CORRELATION_ID" ]]; then
    curl_args+=(-H "X-Client-Request-Id: $CORRELATION_ID")
  fi
  curl "${curl_args[@]}" \
    -H "Authorization: Bearer $api_key" \
    -H 'Content-Type: application/json' \
    --data-binary @"$tmp/$name.request.json" \
    "$CPA_BASE_URL/v1/responses" >"$tmp/$name.raw"
  completed="$(sse_completed_event "$tmp/$name.raw")"
  [[ -n "$completed" ]] || { printf 'missing completed event: %s\n' "$name" >&2; return 1; }
  jq -e '.response.status == "completed" and .response.error == null' <<<"$completed" >/dev/null
  sse_sanitize_event <<<"$completed" >"artifacts/P03/TEST-006/$name.json"

  case "$name" in
    basic)
      grep -q 'CPA_AUTH_READY' <<<"$(sse_output_text <<<"$completed")"
      ;;
    strict-schema)
      jq -e '.response.text.format.type == "json_schema" and .response.text.format.name == "cpa_schema_probe" and .response.text.format.strict == true' <<<"$completed" >/dev/null
      sse_output_text <<<"$completed" | jq -e '.sentinel == "STRUCTURED_OUTPUT_ENFORCED"' >/dev/null
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
  sha256sum "$tmp/$name.request.json" | awk -v name="$name" '{print name, $1}' >>artifacts/P03/TEST-006/request-hashes.txt
  printf 'case %s: ok\n' "$name"
}

: >artifacts/P03/TEST-006/request-hashes.txt
run_case basic
run_case strict-schema
run_case web-search
run_case web-search-schema
run_case client-tools
printf 'Responses contract: ok\n'
