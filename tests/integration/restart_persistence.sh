#!/usr/bin/env bash
# TEST-012
set -euo pipefail
export LC_ALL=C

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
mkdir -p artifacts/P06
[[ -x scripts/restart-private.sh ]] || { printf 'private restart implementation is unavailable\n' >&2; exit 1; }

auth_manifest() {
  find state/cpa/auths -maxdepth 1 -type f -name '*.json' -printf '%f\t%m\t' -exec sha256sum {} \; | sort | sha256sum | awk '{print $1}'
}

admin_key="$(<state/secrets/cpamp-admin-key)"
active_before="$(<state/active-origin)"
auth_before="$(auth_manifest)"
events_before="$(curl -fsS -H "Authorization: Bearer $admin_key" http://127.0.0.1:18317/status | jq '.events')"
connector_before="$(docker compose --profile public ps --status running -q cloudflared)"
[[ -n "$connector_before" ]]

bash scripts/restart-private.sh

active_after="$(<state/active-origin)"
auth_after="$(auth_manifest)"
events_after_restart="$(curl -fsS -H "Authorization: Bearer $admin_key" http://127.0.0.1:18317/status | jq '.events')"
connector_after="$(docker compose --profile public ps --status running -q cloudflared)"

[[ "$active_after" == "$active_before" ]]
[[ "$auth_after" == "$auth_before" ]]
[[ "$connector_after" == "$connector_before" ]]
(( events_after_restart >= events_before ))

CPAMP_BASE_URL=http://127.0.0.1:18317 \
  CPAMP_ADMIN_KEY_FILE=state/secrets/cpamp-admin-key \
  CPA_BASE_URL=http://127.0.0.1:8317 \
  CPA_API_KEY_FILE=state/secrets/cpa-api-key \
  ARTIFACT_PATH=artifacts/P06/TEST-012-post-restart-collection.json \
  CORRELATION_ID="test012-$(date -u +%Y%m%dT%H%M%SZ)-$$" \
  bash tests/integration/cpamp_collection.sh

events_final="$(curl -fsS -H "Authorization: Bearer $admin_key" http://127.0.0.1:18317/status | jq '.events')"
(( events_final > events_after_restart ))

jq -n \
  --arg active_origin "$active_after" \
  --arg auth_manifest_sha256 "$auth_after" \
  --arg connector_id "$connector_after" \
  --argjson events_before "$events_before" \
  --argjson events_after_restart "$events_after_restart" \
  --argjson events_final "$events_final" \
  '{test:"TEST-012",status:"pass",active_origin:$active_origin,auth_manifest_sha256:$auth_manifest_sha256,public_connector_unchanged:true,connector_id:$connector_id,events_before:$events_before,events_after_restart:$events_after_restart,events_final:$events_final,post_restart_collection:true}' \
  >artifacts/P06/TEST-012-green.json

printf 'service restart persistence: ok\n'
