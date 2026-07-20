#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
umask 077

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
lock_file="$root/state/service-operation.lock"
mkdir -p state
exec 9>"$lock_file"
flock -n 9 || { printf 'another service operation is already in progress\n' >&2; exit 1; }

connector_before="$(docker compose --profile public ps --status running -q cloudflared)"
docker compose up -d --no-deps --force-recreate cli-proxy-api
timeout 120 bash -c 'until curl -fsS http://127.0.0.1:8317/healthz >/dev/null; do sleep 1; done'

docker compose up -d --no-deps --force-recreate cpa-manager-plus
timeout 120 bash -c 'until curl -fsS http://127.0.0.1:18317/health | jq -e ".ok == true" >/dev/null; do sleep 1; done'
admin_key="$(<state/secrets/cpamp-admin-key)"
timeout 120 bash -c 'until curl -fsS -H "Authorization: Bearer '"$admin_key"'" http://127.0.0.1:18317/status | jq -e ".collector.collector == \"running\" and (.collector.lastError // \"\") == \"\"" >/dev/null; do sleep 1; done'

python3 scripts/render-public-config.py
docker compose up -d --no-deps --force-recreate cpamp-public
timeout 120 bash -c 'until curl -fsS http://127.0.0.1:18417/health | jq -e ".ok == true" >/dev/null; do sleep 1; done'

connector_after="$(docker compose --profile public ps --status running -q cloudflared)"
[[ "$connector_after" == "$connector_before" ]] || { printf 'public connector changed during private restart\n' >&2; exit 1; }
printf 'private services restarted\n'
