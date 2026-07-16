#!/usr/bin/env bash
# TEST-005
set -euo pipefail
export LC_ALL=C

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"

: "${CPA_BASE_URL:=http://127.0.0.1:8317}"
: "${CPA_API_KEY_FILE:=state/secrets/cpa-api-key}"
: "${MODEL:=gpt-5.4-mini}"
[[ -s "$CPA_API_KEY_FILE" ]] || { printf 'CPA API key file is unavailable\n' >&2; exit 1; }

docker compose up -d cli-proxy-api >/dev/null

ready=0
for _ in $(seq 1 60); do
  if curl -fsS --max-time 2 "$CPA_BASE_URL/healthz" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done
[[ "$ready" -eq 1 ]] || { printf 'CPA did not become healthy\n' >&2; exit 1; }

api_key="$(<"$CPA_API_KEY_FILE")"
models="$(mktemp)"
stream="$(mktemp)"
trap 'rm -f "$models" "$stream"' EXIT

curl -fsS --max-time 20 \
  -H "Authorization: Bearer $api_key" \
  "$CPA_BASE_URL/v1/models" >"$models"
if ! jq -e --arg model "$MODEL" '.data | any(.id == $model)' "$models" >/dev/null; then
  printf 'required model is absent from CPA catalog: %s\n' "$MODEL" >&2
  exit 1
fi

auth_count=0
while IFS= read -r auth_file; do
  mode="$(stat -c '%a' "$auth_file")"
  [[ "$mode" == 600 ]] || { printf 'Codex OAuth auth file mode is %s, expected 600\n' "$mode" >&2; exit 1; }
  owner_uid="$(stat -c '%u' "$auth_file")"
  [[ "$owner_uid" == "$(id -u)" ]] || { printf 'Codex OAuth auth file is not owned by the operator uid\n' >&2; exit 1; }
  jq -e '.type == "codex" and (.access_token | type == "string" and length > 0) and (.refresh_token | type == "string" and length > 0)' "$auth_file" >/dev/null
  auth_count=$((auth_count + 1))
done < <(find state/cpa/auths -maxdepth 1 -type f -name '*.json' | sort)
[[ "$auth_count" -gt 0 ]] || { printf 'no usable Codex OAuth auth file\n' >&2; exit 1; }

curl -fsS -N --max-time 20 \
  -H "Authorization: Bearer $api_key" \
  -H 'Content-Type: application/json' \
  --data-binary @tests/fixtures/responses/basic.json \
  "$CPA_BASE_URL/v1/responses" >"$stream"

grep -q 'response.completed' "$stream"
grep -q 'CPA_AUTH_READY' "$stream"

printf 'CPA auth and model readiness: ok\n'
