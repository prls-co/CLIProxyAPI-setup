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
shift
file=""
while (($#)); do
  case "$1" in
    -f) file="$2"; shift 2 ;;
    --profile) shift 2 ;;
    ps)
      origin=litellm
      [[ "$file" == *cpa-compose* ]] && origin=cpa
      if [[ "$(<"$MOCK_STATE_DIR/$origin")" == running ]]; then
        printf '%s-connector\n' "$origin"
      fi
      exit 0
      ;;
    stop)
      origin=litellm
      [[ "$file" == *cpa-compose* ]] && origin=cpa
      printf 'stopped' >"$MOCK_STATE_DIR/$origin"
      exit 0
      ;;
    up)
      origin=litellm
      other=cpa
      [[ "$file" == *cpa-compose* ]] && { origin=cpa; other=litellm; }
      [[ "$(<"$MOCK_STATE_DIR/$other")" == stopped ]] || { printf 'connector overlap attempted\n' >&2; exit 9; }
      printf 'running' >"$MOCK_STATE_DIR/$origin"
      [[ "$origin" == litellm ]] && rm -f "$MOCK_STATE_DIR/fail-public"
      exit 0
      ;;
    *) shift ;;
  esac
done
exit 2
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
chmod +x "$tmp/bin/docker" "$tmp/bin/curl"

run_case() {
  local name="$1" from="$2" target="$3" expected="$4" failure="${5:-false}"
  local case_dir="$tmp/$name"
  mkdir -p "$case_dir/state"
  printf stopped >"$case_dir/state/cpa"
  printf stopped >"$case_dir/state/litellm"
  printf running >"$case_dir/state/$from"
  printf '%s\n' "$from" >"$case_dir/active-origin"
  : >"$case_dir/commands.log"
  [[ "$failure" == true ]] && : >"$case_dir/state/fail-public"

  set +e
  PATH="$tmp/bin:$PATH" \
    MOCK_STATE_DIR="$case_dir/state" \
    MOCK_COMMAND_LOG="$case_dir/commands.log" \
    CPA_COMPOSE_FILE="$case_dir/cpa-compose.yaml" \
    LITELLM_COMPOSE_FILE="$case_dir/litellm-compose.yaml" \
    STATE_FILE="$case_dir/active-origin" \
    LOCK_FILE="$case_dir/switch.lock" \
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
  [[ "$(<"$case_dir/state/$target")" == "$([[ "$failure" == true ]] && printf stopped || printf running)" ]]
  if [[ "$failure" == false ]]; then
    [[ "$(<"$case_dir/state/$from")" == stopped ]]
  fi
}

printf 'unit-test-key\n' >"$tmp/dummy-key"
run_case cpa-success litellm cpa tests/fixtures/cutover/expected-cpa.txt
run_case litellm-success cpa litellm tests/fixtures/cutover/expected-litellm.txt
run_case cpa-rollback litellm cpa tests/fixtures/cutover/expected-rollback.txt true

mkdir -p artifacts/P05
printf 'TEST-009 status=pass cases=3 connector_overlap_attempts=0\n' >artifacts/P05/TEST-009-green.txt
printf 'cutover state machine: ok\n'
