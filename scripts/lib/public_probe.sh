#!/usr/bin/env bash
set -euo pipefail

probe_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
probe_root="$(cd "$probe_lib_dir/../.." && pwd)"
# shellcheck source=scripts/lib/sse.sh
source "$probe_lib_dir/sse.sh"

# Sets OPENAI_PROBE_HEALTH_PATH and OPENAI_PROBE_COMPLETED on success. All raw
# material stays in the caller-provided temporary directory.
openai_basic_probe() {
  local base="$1" key_file="$2" model="$3" work_dir="$4"
  local key origin path output_text
  [[ -s "$key_file" ]] || return 1
  mkdir -p "$work_dir"
  key="$(<"$key_file")"
  origin="${base%/v1}"
  OPENAI_PROBE_HEALTH_PATH=""

  for path in /healthz /health/liveliness; do
    if curl -fsS --max-time 20 -H "Authorization: Bearer $key" "$origin$path" >/dev/null 2>&1; then
      OPENAI_PROBE_HEALTH_PATH="$path"
      break
    fi
  done
  [[ -n "$OPENAI_PROBE_HEALTH_PATH" ]] || return 1

  curl -fsS --max-time 20 \
    -H "Authorization: Bearer $key" \
    "$base/models" >"$work_dir/models.json" || return 1
  jq -e --arg model "$model" '.data | any(.id == $model)' "$work_dir/models.json" >/dev/null || return 1

  jq --arg model "$model" '.model=$model' "$probe_root/tests/fixtures/responses/basic.json" >"$work_dir/basic.request.json"
  curl -fsS -N --max-time 20 \
    -H "Authorization: Bearer $key" \
    -H 'Content-Type: application/json' \
    --data-binary @"$work_dir/basic.request.json" \
    "$base/responses" >"$work_dir/basic.raw" || return 1
  OPENAI_PROBE_COMPLETED="$(sse_completed_event "$work_dir/basic.raw")"
  [[ -n "$OPENAI_PROBE_COMPLETED" ]] || return 1
  jq -e '.response.status == "completed" and .response.error == null' <<<"$OPENAI_PROBE_COMPLETED" >/dev/null || return 1
  output_text="$(sse_output_text <<<"$OPENAI_PROBE_COMPLETED")"
  [[ -n "$output_text" ]] || output_text="$(sse_stream_output_text "$work_dir/basic.raw")"
  grep -q 'CPA_AUTH_READY' <<<"$output_text"
}
