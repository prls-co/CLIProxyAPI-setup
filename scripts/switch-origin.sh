#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
umask 077

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/public_probe.sh
source "$root/scripts/lib/public_probe.sh"
: "${CPA_COMPOSE_FILE:=$root/compose.yaml}"
: "${STATE_FILE:=$root/state/active-origin}"
: "${LOCK_FILE:=$root/state/switch-origin.lock}"
: "${RENDER_PUBLIC_CONFIG:=$root/scripts/render-public-config.py}"
: "${SWITCH_TRACE_FILE:=}"
: "${PUBLIC_BASE_URL:=https://cpa.prls.co/v1}"
: "${PUBLIC_API_KEY_FILE:=$root/state/secrets/cpa-api-key}"
: "${CPA_LOCAL_BASE_URL:=http://127.0.0.1:8317/v1}"
: "${LITELLM_LOCAL_BASE_URL:=http://127.0.0.1:4000/v1}"
: "${MODEL:=gpt-5.4-mini}"
: "${PUBLIC_PROBE_ATTEMPTS:=10}"
: "${PUBLIC_PROBE_RETRY_DELAY_SECONDS:=2}"

target="${1:-}"
case "$target" in
  cpa|litellm) ;;
  *) printf 'usage: %s {cpa|litellm}\n' "$0" >&2; exit 2 ;;
esac
[[ -s "$PUBLIC_API_KEY_FILE" ]] || { printf 'public API key file is unavailable\n' >&2; exit 1; }
[[ -s "$STATE_FILE" ]] || { printf 'active-origin marker is unavailable\n' >&2; exit 1; }
previous="$(<"$STATE_FILE")"
case "$previous" in cpa|litellm) ;; *) printf 'invalid active-origin marker\n' >&2; exit 1 ;; esac
mkdir -p "$(dirname "$LOCK_FILE")"

trace() {
  [[ -z "$SWITCH_TRACE_FILE" ]] || printf '%s\n' "$1" >>"$SWITCH_TRACE_FILE"
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

render_edge() {
  local origin="$1"
  trace "render:$origin"
  CPA_PUBLIC_ORIGIN="$origin" "$RENDER_PUBLIC_CONFIG" >/dev/null
  trace "recreate-edge:$origin"
  docker compose -f "$CPA_COMPOSE_FILE" up -d --no-deps --force-recreate cpamp-public >/dev/null
}

write_state() {
  local origin="$1" tmp
  tmp="$(mktemp "${STATE_FILE}.tmp.XXXXXX")"
  printf '%s\n' "$origin" >"$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$STATE_FILE"
  trace "state-write:$origin"
}

restore_previous() {
  trace "restore:$previous"
  render_edge "$previous" || { printf 'rollback could not restore the %s edge\n' "$previous" >&2; return 1; }
  trace "rollback-public-probe:$previous"
  probe_public || { printf 'rollback public probe failed for %s\n' "$previous" >&2; return 1; }
  trace "rollback-complete:$previous"
}

exec 9>"$LOCK_FILE"
flock -n 9 || { printf 'another origin switch is in progress\n' >&2; exit 1; }
trace lock-acquired

trace "preflight:$target"
probe_base "$(local_base "$target")" || { printf 'local preflight failed for %s\n' "$target" >&2; exit 1; }

if [[ "$previous" == "$target" ]]; then
  trace "public-probe:$target"
  probe_public || { printf 'public probe failed for active origin %s\n' "$target" >&2; exit 1; }
  printf 'origin already active and healthy: %s\n' "$target"
  exit 0
fi

if ! render_edge "$target"; then
  restore_previous || true
  printf 'origin switch failed while rendering %s; restored %s\n' "$target" "$previous" >&2
  exit 1
fi

trace "public-probe:$target"
if ! probe_public; then
  trace "public-probe-failed:$target"
  restore_previous || true
  printf 'origin switch public probe failed for %s; restored %s\n' "$target" "$previous" >&2
  exit 1
fi

write_state "$target"
printf 'active origin for cpa.prls.co: %s\n' "$target"
