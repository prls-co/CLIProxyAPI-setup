#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
umask 077

# Switch the canonical Cloudflare Tunnel replica to this machine.
# This script intentionally never probes the public CPA hostname.

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

# shellcheck source=scripts/lib/common.sh
source scripts/lib/common.sh
load_local_env

: "${CLOUDFLARE_API_TOKEN:?CLOUDFLARE_API_TOKEN is required in .env.local}"
: "${CLOUDFLARE_ZONE_NAME:=prls.co}"
: "${CPA_TUNNEL_NAME:=shaman-cpa}"
: "${CPA_PUBLIC_HOSTNAME:=cpa.prls.co}"
: "${CPA_SWITCH_TIMEOUT_SECONDS:=180}"

for command_name in docker curl jq python3 flock; do
  command -v "$command_name" >/dev/null || {
    printf 'required command is unavailable: %s\n' "$command_name" >&2
    exit 1
  }
done

mkdir -p state
exec 9>state/service-operation.lock
flock -w 30 9 || {
  printf 'another service operation is already in progress\n' >&2
  exit 1
}

temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/cliproxyapi-switch.XXXXXX")"
cleanup() {
  rm -rf -- "$temporary_directory"
}
trap cleanup EXIT

wait_for_http() {
  local label="$1" url="$2" deadline
  deadline=$((SECONDS + CPA_SWITCH_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    if curl --max-time 5 -fsS -o /dev/null "$url"; then
      printf '%s: ready\n' "$label"
      return 0
    fi
    sleep 1
  done
  printf '%s did not become ready: %s\n' "$label" "$url" >&2
  return 1
}

wait_for_json_health() {
  local label="$1" url="$2" deadline response
  deadline=$((SECONDS + CPA_SWITCH_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    if response="$(curl --max-time 5 -fsS "$url" 2>/dev/null)" \
      && jq -e '.ok == true' <<<"$response" >/dev/null 2>&1; then
      printf '%s: ready\n' "$label"
      return 0
    fi
    sleep 1
  done
  printf '%s did not become ready: %s\n' "$label" "$url" >&2
  return 1
}

wait_for_connector_container() {
  local deadline connector_id
  deadline=$((SECONDS + CPA_SWITCH_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    connector_id="$(docker compose --profile public ps --status running -q cloudflared 2>/dev/null || true)"
    if [[ -n "$connector_id" ]]; then
      printf 'cloudflared container: running\n'
      return 0
    fi
    sleep 1
  done
  printf 'cloudflared container did not become running\n' >&2
  docker compose --profile public ps cloudflared >&2 || true
  return 1
}

printf 'preparing local CPA origin\n'
bash scripts/init-state.sh
python3 scripts/render-cpa-config.py
python3 scripts/render-public-config.py
docker compose up -d cli-proxy-api cpa-manager-plus
wait_for_http 'CPA' http://127.0.0.1:8317/healthz
wait_for_json_health 'CPA Manager Plus' http://127.0.0.1:18317/health
docker compose up -d --force-recreate cpamp-public
wait_for_json_health 'CPA public edge' http://127.0.0.1:18417/health

printf 'reconciling Cloudflare tunnel and DNS\n'
bash scripts/configure-cloudflare.sh

context_path=state/cloudflare/context.json
[[ -s "$context_path" ]] || {
  printf 'Cloudflare context was not generated: %s\n' "$context_path" >&2
  exit 1
}
account_id="$(jq -er '.account_id' "$context_path")"
tunnel_id="$(jq -er '.tunnel_id' "$context_path")"
public_hostname="$(jq -er '.public_hostname' "$context_path")"
[[ "$public_hostname" == "$CPA_PUBLIC_HOSTNAME" ]] || {
  printf 'Cloudflare context hostname does not match configured hostname\n' >&2
  exit 1
}

api=https://api.cloudflare.com/client/v4
cf_get() {
  curl --max-time 30 -fsS \
    -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
    "$api/$1"
}

cf_delete() {
  curl --max-time 30 -fsS -X DELETE \
    -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
    "$api/$1"
}

require_cloudflare_success() {
  local operation="$1" response="$2"
  if ! jq -e '.success == true' <<<"$response" >/dev/null; then
    printf 'Cloudflare operation failed: %s\n' "$operation" >&2
    jq -r '.errors[]? | "error " + (.code|tostring) + ": " + .message' <<<"$response" >&2
    return 1
  fi
}

connection_ids() {
  local response
  response="$(cf_get "accounts/$account_id/cfd_tunnel/$tunnel_id/connections")"
  require_cloudflare_success 'list tunnel connections' "$response"
  jq -r '
    .result[]?
    | if ((.conns // []) | length) > 0
      then .conns[]?.client_id // empty
      else .id // empty
      end
  ' <<<"$response" | awk 'NF' | sort -u
}

before_connections="$temporary_directory/before-connections.txt"
connection_ids >"$before_connections"
before_count="$(wc -l <"$before_connections")"
printf 'pre-existing tunnel connectors: %s\n' "$before_count"

printf 'starting this machine as the tunnel replica\n'
docker compose --profile public up -d --force-recreate cloudflared-token-init
docker compose --profile public up -d --force-recreate cloudflared
wait_for_connector_container

new_connections="$temporary_directory/new-connections.txt"
deadline=$((SECONDS + CPA_SWITCH_TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  connection_ids >"$temporary_directory/all-connections.txt"
  comm -13 "$before_connections" "$temporary_directory/all-connections.txt" >"$new_connections"
  if [[ -s "$new_connections" ]]; then
    break
  fi
  sleep 2
done
[[ -s "$new_connections" ]] || {
  printf 'local cloudflared is running, but Cloudflare did not report a new connector\n' >&2
  exit 1
}

removed_count=0
while IFS= read -r client_id; do
  [[ -n "$client_id" ]] || continue
  [[ "$client_id" =~ ^[0-9a-fA-F-]{36}$ ]] || {
    printf 'Cloudflare returned an invalid connector id\n' >&2
    exit 1
  }
  response="$(cf_delete "accounts/$account_id/cfd_tunnel/$tunnel_id/connections?client_id=$client_id")"
  require_cloudflare_success "remove previous connector" "$response"
  removed_count=$((removed_count + 1))
done <"$before_connections"

printf 'removed previous tunnel connectors: %s\n' "$removed_count"
printf 'active machine switch complete for %s\n' "$public_hostname"
printf 'stop any old machine running this tunnel; a live old connector can reconnect after cleanup\n'
