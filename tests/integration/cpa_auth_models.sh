#!/usr/bin/env bash
# TEST-005
set -euo pipefail
export LC_ALL=C

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
# shellcheck source=scripts/lib/common.sh
source scripts/lib/common.sh
load_env

: "${CPA_LOCAL_BASE_URL:=http://127.0.0.1:8317}"
: "${MODEL:=gpt-5.4-mini}"
: "${CPA_API_KEY:?CPA_API_KEY is required in .env}"

docker compose up -d cli-proxy-api >/dev/null

ready=0
for _ in $(seq 1 60); do
  if curl -fsS --max-time 2 "$CPA_LOCAL_BASE_URL/healthz" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done
[[ "$ready" -eq 1 ]] || { printf 'CPA did not become healthy\n' >&2; exit 1; }

api_key="$CPA_API_KEY"
models="$(mktemp)"
stream="$(mktemp)"
trap 'rm -f "$models" "$stream"' EXIT

curl -fsS --max-time 20 \
  -H "Authorization: Bearer $api_key" \
  "$CPA_LOCAL_BASE_URL/v1/models" >"$models"
if ! jq -e --arg model "$MODEL" '.data | any(.id == $model)' "$models" >/dev/null; then
  printf 'required model is absent from CPA catalog: %s\n' "$MODEL" >&2
  exit 1
fi
if ! jq -e '.data | any(.id == "claude-sonnet-5")' "$models" >/dev/null; then
  printf 'required Claude subscription model is absent from CPA catalog\n' >&2
  exit 1
fi

codex_auth_count=0
claude_auth_count=0
while IFS= read -r auth_file; do
  mode="$(stat -c '%a' "$auth_file")"
  [[ "$mode" == 600 ]] || { printf 'OAuth auth file mode is %s, expected 600\n' "$mode" >&2; exit 1; }
  owner_uid="$(stat -c '%u' "$auth_file")"
  [[ "$owner_uid" == "$(id -u)" ]] || { printf 'OAuth auth file is not owned by the operator uid\n' >&2; exit 1; }
  auth_type="$(jq -r '.type // empty' "$auth_file")"
  case "$auth_type" in
    codex)
      jq -e '(.access_token | type == "string" and length > 0) and (.refresh_token | type == "string" and length > 0)' "$auth_file" >/dev/null
      codex_auth_count=$((codex_auth_count + 1))
      ;;
    claude)
      jq -e '(.access_token | type == "string" and length > 0) and (.refresh_token | type == "string" and length > 0)' "$auth_file" >/dev/null
      claude_auth_count=$((claude_auth_count + 1))
      ;;
    *)
      printf 'unsupported OAuth auth type found in canonical auth directory\n' >&2
      exit 1
      ;;
  esac
done < <(find state/cpa/auths -maxdepth 1 -type f -name '*.json' | sort)
[[ "$codex_auth_count" -gt 0 ]] || { printf 'no usable Codex OAuth auth file\n' >&2; exit 1; }
[[ "$claude_auth_count" -gt 0 ]] || { printf 'no usable Claude OAuth auth file\n' >&2; exit 1; }

curl -fsS -N --max-time 20 \
  -H "Authorization: Bearer $api_key" \
  -H 'Content-Type: application/json' \
  --data-binary @tests/fixtures/responses/basic.json \
  "$CPA_LOCAL_BASE_URL/v1/responses" >"$stream"

grep -q 'response.completed' "$stream"
grep -q 'CPA_AUTH_READY' "$stream"

printf 'CPA auth and model readiness: ok\n'
