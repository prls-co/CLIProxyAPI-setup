#!/usr/bin/env bash
set -euo pipefail

sse_completed_event() {
  local stream_file="$1"
  awk '/^data: / {sub(/^data: /, ""); if ($0 != "[DONE]") print}' "$stream_file" \
    | jq -c 'select(.type == "response.completed")' \
    | tail -n 1
}

sse_output_text() {
  jq -r '[.response.output[]? | select(.type == "message") | .content[]? | select(.type == "output_text") | .text] | join("")'
}

sse_stream_output_text() {
  local stream_file="$1"
  awk '/^data: / {sub(/^data: /, ""); if ($0 != "[DONE]") print}' "$stream_file" \
    | jq -rs '[.[] | select(.type == "response.output_text.delta") | .delta] | join("")'
}

sse_sanitize_event() {
  jq 'walk(if type == "object" then del(.encrypted_content, .access_token, .refresh_token, .id_token) else . end)'
}
