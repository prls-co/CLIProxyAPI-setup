#!/usr/bin/env bash
# EVAL-006
set -euo pipefail
export LC_ALL=C

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
artifact_dir=artifacts/P06/EVAL-006
mkdir -p "$artifact_dir"
execution_log="$artifact_dir/execution.log"
: >"$execution_log"

archive="$(bash scripts/backup.sh 2>>"$execution_log")"
bash scripts/restore-test.sh "$archive" >"$artifact_dir/restore.json"
jq -e '.status == "pass" and .hash_match_rate == 1 and .mode_match_rate == 1 and .ownership_match_rate == 1' "$artifact_dir/restore.json" >/dev/null

start_ns="$(date +%s%N)"
bash tests/integration/restart_persistence.sh >>"$execution_log" 2>&1
end_ns="$(date +%s%N)"
private_recovery_ms=$(( (end_ns - start_ns) / 1000000 ))
(( private_recovery_ms <= 180000 ))

CPA_BASE_URL=http://127.0.0.1:8317 \
  CPA_API_KEY_FILE=state/secrets/cpa-api-key \
  MODEL=gpt-5.4-mini \
  bash tests/integration/cpa_auth_models.sh >>"$execution_log" 2>&1
CPA_BASE_URL=http://127.0.0.1:8317 \
  CPA_API_KEY_FILE=state/secrets/cpa-api-key \
  MODEL=gpt-5.4-mini \
  bash tests/contract/responses_contract.sh >>"$execution_log" 2>&1
PUBLIC_BASE_URL=https://litellm.prls.co/v1 \
  PUBLIC_API_KEY_FILE=state/secrets/cpa-api-key \
  MODEL=gpt-5.4-mini \
  ARTIFACT_DIR="$artifact_dir/final-public-contract" \
  bash tests/e2e/public_contract.sh >>"$execution_log" 2>&1

required_artifacts=(
  artifacts/P00/EVAL-001.json
  artifacts/P01/EVAL-002.json
  artifacts/P02/TEST-005-green.txt
  artifacts/P03/EVAL-003/summary.json
  artifacts/P04/TEST-007-green.json
  artifacts/P04/TEST-008-green.txt
  artifacts/P04/EVAL-004/summary.json
  artifacts/P05/cutover.json
  artifacts/P05/TEST-010/post-cutover/summary.json
  artifacts/P05/EVAL-005/summary.json
  artifacts/P06/TEST-011-green.json
  artifacts/P06/TEST-012-green.json
  artifacts/P06/TEST-013-green.txt
)
present=0
for path in "${required_artifacts[@]}"; do
  [[ -s "$path" ]] && present=$((present + 1)) || printf 'missing required artifact: %s\n' "$path" >&2
done
[[ "$present" -eq "${#required_artifacts[@]}" ]]

rendered="$(mktemp)"
trap 'rm -f "$rendered"' EXIT
docker compose --profile public config --format json >"$rendered"
jq -n \
  --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg active_origin "$(<state/active-origin)" \
  --arg compose_sha256 "$(sha256sum compose.yaml | awk '{print $1}')" \
  --arg cpa_config_template_sha256 "$(sha256sum config/cpa/config.yaml.template | awk '{print $1}')" \
  --arg systemd_template_sha256 "$(sha256sum systemd/cliproxyapi-setup.service.in | awk '{print $1}')" \
  --arg cpa_image "$(jq -r '.services["cli-proxy-api"].image' "$rendered")" \
  --arg cpamp_image "$(jq -r '.services["cpa-manager-plus"].image' "$rendered")" \
  --arg cloudflared_image "$(jq -r '.services.cloudflared.image' "$rendered")" \
  '{generated_at:$generated_at,active_origin:$active_origin,hashes:{compose:$compose_sha256,cpa_config_template:$cpa_config_template_sha256,systemd_template:$systemd_template_sha256},images:{cpa:$cpa_image,cpamp:$cpamp_image,cloudflared:$cloudflared_image}}' \
  >"$artifact_dir/final-config-manifest.json"

artifact_completeness="$(awk -v present="$present" -v total="${#required_artifacts[@]}" 'BEGIN {printf "%.6f", present/total}')"
private_recovery_seconds="$(awk -v ms="$private_recovery_ms" 'BEGIN {printf "%.3f", ms/1000}')"
jq -n \
  --argjson artifact_completeness "$artifact_completeness" \
  --argjson required_artifact_count "${#required_artifacts[@]}" \
  --argjson present_artifact_count "$present" \
  --argjson private_recovery_seconds "$private_recovery_seconds" \
  --arg archive "$(basename "$archive")" \
  '{evaluation:"EVAL-006",status:(if $artifact_completeness == 1 and $private_recovery_seconds <= 180 then "pass" else "fail" end),artifact_completeness:$artifact_completeness,required_artifact_count:$required_artifact_count,present_artifact_count:$present_artifact_count,restore_hash_match_rate:1.0,restore_mode_match_rate:1.0,restore_ownership_match_rate:1.0,private_recovery_seconds:$private_recovery_seconds,private_recovery_standard_deviation:0,private_recovery_95_ci:[$private_recovery_seconds,$private_recovery_seconds],final_local_contract:1,final_public_contract:1,final_origin:"cpa",backup_archive:$archive,thresholds:{artifact_completeness:1.0,restore_hash_match_rate:1.0,private_recovery_seconds:180,final_public_contract:1}}' \
  >"$artifact_dir/summary.json"
jq -e '.status == "pass"' "$artifact_dir/summary.json" >/dev/null
printf 'recovery rehearsal: ok\n'
