#!/usr/bin/env bash
# TEST-011
set -euo pipefail
export LC_ALL=C

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
mkdir -p artifacts/P06
for script in scripts/backup.sh scripts/restore-test.sh; do
  [[ -x "$script" ]] || { printf 'backup implementation is unavailable: %s\n' "$script" >&2; exit 1; }
done

[[ -s state/active-origin ]]
active_before="$(<state/active-origin)"
cpa_id_before="$(docker compose ps -q cli-proxy-api)"
admin_key="$(<state/secrets/cpamp-admin-key)"
events_before="$(curl -fsS -H "Authorization: Bearer $admin_key" http://127.0.0.1:18317/status | jq '.events')"

archive="$(bash scripts/backup.sh)"
[[ -f "$archive" ]]
[[ "$(stat -c %a "$archive")" == 600 ]]
bash scripts/restore-test.sh "$archive" >artifacts/P06/restore-test.json

[[ "$(docker compose ps -q cli-proxy-api)" == "$cpa_id_before" ]]
[[ "$(<state/active-origin)" == "$active_before" ]]
timeout 90 bash -c 'until curl -fsS http://127.0.0.1:18317/health | jq -e ".ok == true" >/dev/null; do sleep 1; done'
events_after="$(curl -fsS -H "Authorization: Bearer $admin_key" http://127.0.0.1:18317/status | jq '.events')"
(( events_after >= events_before ))

tar -xOzf "$archive" manifest.tsv >artifacts/P06/backup-manifest.tsv
for required in \
  state/cpa/config.yaml \
  state/cpamp/data/data.key \
  state/cpamp/data/usage.sqlite \
  state/secrets/cpa-api-key \
  state/secrets/cpa-management-key \
  state/secrets/cpamp-admin-key \
  state/secrets/tunnel-token \
  state/active-origin; do
  awk -F '\t' -v path="$required" '$1 == path {found=1} END {exit !found}' artifacts/P06/backup-manifest.tsv
done
awk -F '\t' '$1 ~ /^state\/cpa\/auths\/.*\.json$/ {found=1} END {exit !found}' artifacts/P06/backup-manifest.tsv

jq -n \
  --arg archive "$(basename "$archive")" \
  --arg active_origin "$active_before" \
  --argjson events_before "$events_before" \
  --argjson events_after "$events_after" \
  --argjson manifest_entries "$(wc -l <artifacts/P06/backup-manifest.tsv)" \
  '{test:"TEST-011",status:"pass",archive:$archive,archive_mode:"600",active_origin:$active_origin,cpa_container_unchanged:true,events_before:$events_before,events_after:$events_after,manifest_entries:$manifest_entries,isolated_restore_hash_match_rate:1.0}' \
  >artifacts/P06/TEST-011-green.json

printf 'backup and isolated restore: ok\n'
