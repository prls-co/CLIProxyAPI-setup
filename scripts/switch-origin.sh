#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
umask 077

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/public_probe.sh
source "$root/scripts/lib/public_probe.sh"
: "${CPA_COMPOSE_FILE:=$root/compose.yaml}"
: "${LITELLM_COMPOSE_FILE:=/home/kirill/p/litellm-chatgpt/compose.yaml}"
: "${STATE_FILE:=$root/state/active-origin}"
: "${LOCK_FILE:=$root/state/switch-origin.lock}"
: "${SWITCH_TRACE_FILE:=}"
: "${PUBLIC_BASE_URL:=https://litellm.prls.co/v1}"
: "${PUBLIC_API_KEY_FILE:=$root/state/secrets/cpa-api-key}"
: "${CPA_LOCAL_BASE_URL:=http://127.0.0.1:8317/v1}"
: "${LITELLM_LOCAL_BASE_URL:=http://127.0.0.1:4000/v1}"
: "${MODEL:=gpt-5.4-mini}"
: "${CONNECTOR_WAIT_SECONDS:=30}"
: "${PUBLIC_PROBE_ATTEMPTS:=10}"
: "${PUBLIC_PROBE_RETRY_DELAY_SECONDS:=2}"

target="${1:-}"
case "$target" in
  cpa|litellm) ;;
  *) printf 'usage: %s {cpa|litellm}\n' "$0" >&2; exit 2 ;;
esac
[[ -s "$PUBLIC_API_KEY_FILE" ]] || { printf 'public API key file is unavailable\n' >&2; exit 1; }
mkdir -p "$(dirname "$STATE_FILE")" "$(dirname "$LOCK_FILE")"

trace() {
  [[ -z "$SWITCH_TRACE_FILE" ]] || printf '%s\n' "$1" >>"$SWITCH_TRACE_FILE"
}

exec 9>"$LOCK_FILE"
flock -n 9 || { printf 'another origin switch is in progress\n' >&2; exit 1; }
trace lock-acquired

compose() {
  local origin="$1"
  shift
  if [[ "$origin" == cpa ]]; then
    docker compose -f "$CPA_COMPOSE_FILE" --profile public "$@"
  else
    docker compose -f "$LITELLM_COMPOSE_FILE" "$@"
  fi
}

connector_running() {
  local origin="$1" id
  id="$(compose "$origin" ps --status running -q cloudflared)"
  [[ -n "$id" ]]
}

wait_connector_state() {
  local origin="$1" expected="$2" deadline=$((SECONDS + CONNECTOR_WAIT_SECONDS))
  while (( SECONDS <= deadline )); do
    if connector_running "$origin"; then
      [[ "$expected" == running ]] && return 0
    else
      [[ "$expected" == stopped ]] && return 0
    fi
    sleep 1
  done
  return 1
}

start_connector() {
  local origin="$1"
  compose "$origin" up -d cloudflared >/dev/null
}

stop_connector() {
  local origin="$1"
  compose "$origin" stop cloudflared >/dev/null
}

local_base() {
  [[ "$1" == cpa ]] && printf '%s\n' "$CPA_LOCAL_BASE_URL" || printf '%s\n' "$LITELLM_LOCAL_BASE_URL"
}

probe_base() {
  local base="$1" tmp
  tmp="$(mktemp -d)"
  if ! openai_basic_probe "$base" "$PUBLIC_API_KEY_FILE" "$MODEL" "$tmp"; then
    rm -rf "$tmp"
    return 1
  fi
  rm -rf "$tmp"
}

probe_public() {
  local attempt
  for ((attempt = 1; attempt <= PUBLIC_PROBE_ATTEMPTS; attempt++)); do
    if probe_base "$PUBLIC_BASE_URL"; then
      return 0
    fi
    (( attempt == PUBLIC_PROBE_ATTEMPTS )) || sleep "$PUBLIC_PROBE_RETRY_DELAY_SECONDS"
  done
  return 1
}

write_state() {
  local origin="$1" tmp
  tmp="$(mktemp "${STATE_FILE}.tmp.XXXXXX")"
  printf '%s\n' "$origin" >"$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$STATE_FILE"
  trace "state-write:$origin"
}

if [[ -s "$STATE_FILE" ]]; then
  previous="$(<"$STATE_FILE")"
  case "$previous" in cpa|litellm) ;; *) printf 'invalid active-origin marker\n' >&2; exit 1 ;; esac
else
  cpa_running=0
  litellm_running=0
  connector_running cpa && cpa_running=1
  connector_running litellm && litellm_running=1
  if (( cpa_running + litellm_running != 1 )); then
    printf 'cannot infer a unique active connector\n' >&2
    exit 1
  fi
  (( cpa_running == 1 )) && previous=cpa || previous=litellm
fi

other=litellm
[[ "$target" == litellm ]] && other=cpa

trace "preflight:$target"
probe_base "$(local_base "$target")" || { printf 'local preflight failed for %s\n' "$target" >&2; exit 1; }

if [[ "$previous" == "$target" ]] && connector_running "$target" && ! connector_running "$other"; then
  trace "public-probe:$target"
  probe_public || { printf 'public probe failed for active origin %s\n' "$target" >&2; exit 1; }
  write_state "$target"
  printf 'origin already active and healthy: %s\n' "$target"
  exit 0
fi

restore_previous() {
  local failure="$1"
  trace "stop:$target"
  stop_connector "$target" || true
  wait_connector_state "$target" stopped || { printf 'rollback could not stop %s\n' "$target" >&2; return 1; }
  trace "confirmed-stopped:$target"
  trace "restore:$previous"
  start_connector "$previous" || { printf 'rollback could not start %s\n' "$previous" >&2; return 1; }
  wait_connector_state "$previous" running || { printf 'rollback did not observe %s running\n' "$previous" >&2; return 1; }
  trace "confirmed-running:$previous"
  trace "rollback-public-probe:$previous"
  probe_public || { printf 'rollback public probe failed for %s\n' "$previous" >&2; return 1; }
  write_state "$previous"
  trace "rollback-complete:$previous"
  printf 'origin switch failed (%s); restored %s\n' "$failure" "$previous" >&2
  return 0
}

trace "stop:$other"
if ! stop_connector "$other"; then
  printf 'failed to stop prior connector %s\n' "$other" >&2
  exit 1
fi
if ! wait_connector_state "$other" stopped; then
  printf 'prior connector did not stop: %s\n' "$other" >&2
  exit 1
fi
trace "confirmed-stopped:$other"

trace "start:$target"
if ! start_connector "$target"; then
  restore_previous start-failed || true
  exit 1
fi
if ! wait_connector_state "$target" running; then
  restore_previous start-timeout || true
  exit 1
fi
trace "confirmed-running:$target"
if connector_running "$other"; then
  restore_previous connector-overlap || true
  exit 1
fi
trace "confirmed-exclusive:$target"

trace "public-probe:$target"
if ! probe_public; then
  trace "public-probe-failed:$target"
  restore_previous public-probe-failed || true
  exit 1
fi

write_state "$target"
printf 'active origin: %s\n' "$target"
