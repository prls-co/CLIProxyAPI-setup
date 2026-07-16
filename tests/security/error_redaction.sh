#!/usr/bin/env bash
# TEST-008
set -euo pipefail
export LC_ALL=C
umask 077

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"

: "${CPA_BASE_URL:=http://127.0.0.1:8317}"
: "${CPAMP_BASE_URL:=http://127.0.0.1:18317}"
: "${ARTIFACT_PATH:=artifacts/P04/TEST-008-green.txt}"

mkdir -p "$(dirname "$ARTIFACT_PATH")"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

rendered="$tmp/compose.json"
docker compose --profile public config --format json >"$rendered"
for service in cli-proxy-api cpa-manager-plus cloudflared; do
  jq -e --arg service "$service" \
    '.services[$service].logging.driver == "local" and .services[$service].logging.options["max-size"] == "10m" and .services[$service].logging.options["max-file"] == "3"' \
    "$rendered" >/dev/null || {
      printf 'bounded logging is not configured for %s\n' "$service" >&2
      exit 1
    }
done
grep -Eq '^debug: false$' config/cpa/config.yaml.template
grep -Eq '^logs-max-total-size-mb: [1-9][0-9]*$' config/cpa/config.yaml.template
grep -Eq '^error-logs-max-files: [1-9][0-9]*$' config/cpa/config.yaml.template

invalid="invalid_test008_$(openssl rand -hex 24)"
since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

cpa_status="$(curl -sS --max-time 15 -o "$tmp/cpa-response.json" -w '%{http_code}' \
  -H "Authorization: Bearer $invalid" "$CPA_BASE_URL/v1/models")"
cpamp_status="$(curl -sS --max-time 15 -o "$tmp/cpamp-response.json" -w '%{http_code}' \
  -H "Authorization: Bearer $invalid" "$CPAMP_BASE_URL/status")"

[[ "$cpa_status" =~ ^(401|403)$ ]]
[[ "$cpamp_status" =~ ^(401|403)$ ]]
jq -e '.error != null' "$tmp/cpa-response.json" >/dev/null
jq -e '.error != null' "$tmp/cpamp-response.json" >/dev/null

docker compose logs --no-color --since "$since" cli-proxy-api cpa-manager-plus >"$tmp/logs.txt" 2>&1
cat "$tmp/cpa-response.json" "$tmp/cpamp-response.json" "$tmp/logs.txt" >"$tmp/inspection.txt"

secret_files=(
  state/secrets/cpa-api-key
  state/secrets/cpa-management-key
  state/secrets/cpamp-admin-key
  state/secrets/tunnel-token
)
for secret_file in "${secret_files[@]}"; do
  [[ -s "$secret_file" ]] || continue
  secret="$(<"$secret_file")"
  if grep -Fq -- "$secret" "$tmp/inspection.txt"; then
    printf 'credential disclosure detected for %s\n' "$secret_file" >&2
    exit 1
  fi
done
if grep -Fq -- "$invalid" "$tmp/inspection.txt"; then
  printf 'invalid bearer value was reflected in response or logs\n' >&2
  exit 1
fi

{
  printf 'TEST-008 status=pass\n'
  printf 'cpa_http_status=%s\n' "$cpa_status"
  printf 'cpamp_http_status=%s\n' "$cpamp_status"
  printf 'invalid_credential_sha256=%s\n' "$(printf '%s' "$invalid" | sha256sum | awk '{print $1}')"
  printf 'inspected_output_sha256=%s\n' "$(sha256sum "$tmp/inspection.txt" | awk '{print $1}')"
  printf 'known_secret_files_checked=%s\n' "${#secret_files[@]}"
  printf 'raw_logs_retained=false\n'
} >"$ARTIFACT_PATH"

printf 'error and credential redaction: ok\n'
