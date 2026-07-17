#!/usr/bin/env bash
# TEST-009
set -euo pipefail
export LC_ALL=C

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
[[ -x scripts/switch-origin.sh ]] || { printf 'switch-origin implementation is unavailable\n' >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

cat >"$tmp/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf 'docker %s\n' "$*" >>"$MOCK_COMMAND_LOG"
[[ "$1" == compose ]]
exit 0
MOCK

cat >"$tmp/bin/render-public" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$CPA_PUBLIC_ORIGIN" >"$MOCK_STATE_DIR/edge-origin"
[[ "$CPA_PUBLIC_ORIGIN" != litellm ]] || rm -f "$MOCK_STATE_DIR/fail-public"
MOCK

cat >"$tmp/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf 'curl %s\n' "$*" >>"$MOCK_COMMAND_LOG"
url="${*: -1}"
if [[ "$url" == https://public.test/* && -f "$MOCK_STATE_DIR/fail-public" ]]; then
  exit 22
fi
case "$url" in
  */models) printf '{"data":[{"id":"gpt-5.4-mini"}]}\n' ;;
  */responses) printf 'event: response.completed\ndata: {"type":"response.completed","response":{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"CPA_AUTH_READY"}]}]}}\n\n' ;;
  */healthz|*/health/liveliness) printf '{"status":"ok"}\n' ;;
  *) printf '{}\n' ;;
esac
MOCK
chmod +x "$tmp/bin/docker" "$tmp/bin/curl" "$tmp/bin/render-public"

run_case() {
  local name="$1" from="$2" target="$3" expected="$4" failure="${5:-false}"
  local case_dir="$tmp/$name"
  mkdir -p "$case_dir/state"
  printf '%s\n' "$from" >"$case_dir/state/edge-origin"
  printf '%s\n' "$from" >"$case_dir/active-origin"
  : >"$case_dir/commands.log"
  [[ "$failure" == true ]] && : >"$case_dir/state/fail-public"

  set +e
  PATH="$tmp/bin:$PATH" \
    MOCK_STATE_DIR="$case_dir/state" \
    MOCK_COMMAND_LOG="$case_dir/commands.log" \
    CPA_COMPOSE_FILE="$case_dir/cpa-compose.yaml" \
    STATE_FILE="$case_dir/active-origin" \
    LOCK_FILE="$case_dir/switch.lock" \
    RENDER_PUBLIC_CONFIG="$tmp/bin/render-public" \
    SWITCH_TRACE_FILE="$case_dir/trace.txt" \
    PUBLIC_BASE_URL=https://public.test/v1 \
    PUBLIC_API_KEY_FILE="$tmp/dummy-key" \
    CPA_LOCAL_BASE_URL=http://cpa.test/v1 \
    LITELLM_LOCAL_BASE_URL=http://litellm.test/v1 \
    PUBLIC_PROBE_ATTEMPTS=1 \
    bash scripts/switch-origin.sh "$target" >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e

  if [[ "$failure" == true ]]; then
    [[ "$rc" -ne 0 ]]
    [[ "$(<"$case_dir/active-origin")" == "$from" ]]
  else
    [[ "$rc" -eq 0 ]]
    [[ "$(<"$case_dir/active-origin")" == "$target" ]]
  fi
  diff -u "$expected" "$case_dir/trace.txt"
  [[ "$(<"$case_dir/state/edge-origin")" == "$([[ "$failure" == true ]] && printf '%s' "$from" || printf '%s' "$target")" ]]
}

printf 'unit-test-key\n' >"$tmp/dummy-key"
run_case cpa-success litellm cpa tests/fixtures/cutover/expected-cpa.txt
run_case litellm-success cpa litellm tests/fixtures/cutover/expected-litellm.txt
run_case cpa-rollback litellm cpa tests/fixtures/cutover/expected-rollback.txt true

mkdir -p artifacts/P05
printf 'TEST-009 status=pass cases=3 edge_rollbacks=1\n' >artifacts/P05/TEST-009-green.txt
printf 'cutover state machine: ok\n'
