#!/usr/bin/env bash
# TEST-014
set -euo pipefail
export LC_ALL=C
umask 077

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
: "${CPAMP_PUBLIC_URL:=https://cpa.prls.co}"
: "${CPAMP_ADMIN_KEY_FILE:=state/secrets/cpamp-admin-key}"

[[ -s "$CPAMP_ADMIN_KEY_FILE" ]] || {
  printf 'CPAMP admin key file is unavailable: %s\n' "$CPAMP_ADMIN_KEY_FILE" >&2
  exit 1
}
admin_key="$(<"$CPAMP_ADMIN_KEY_FILE")"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

status="$(curl -sS --max-time 20 -o "$tmp/page.html" -w '%{http_code}' "$CPAMP_PUBLIC_URL/management.html")"
[[ "$status" == 200 ]]
grep -Fq '<title>CPA Manager Plus' "$tmp/page.html"

status="$(curl -sS --max-time 20 -o "$tmp/unauth-status.json" -w '%{http_code}' "$CPAMP_PUBLIC_URL/status")"
[[ "$status" == 401 ]]

cat >"$tmp/invalid.curl" <<'EOF'
header = "Authorization: Bearer invalid"
EOF
chmod 600 "$tmp/invalid.curl"
status="$(curl -sS --max-time 20 --config "$tmp/invalid.curl" -o "$tmp/invalid-status.json" -w '%{http_code}' "$CPAMP_PUBLIC_URL/status")"
[[ "$status" == 401 ]]

python3 - "$tmp/admin.curl" "$admin_key" <<'PY'
from pathlib import Path
import json
import sys
Path(sys.argv[1]).write_text("header = " + json.dumps("Authorization: Bearer " + sys.argv[2]) + "\n", encoding="utf-8")
PY
chmod 600 "$tmp/admin.curl"
status="$(curl -sS --max-time 20 --config "$tmp/admin.curl" -o "$tmp/status.json" -w '%{http_code}' "$CPAMP_PUBLIC_URL/status")"
[[ "$status" == 200 ]]
jq -e '.collector.collector == "running" and (.collector.lastError // "") == ""' "$tmp/status.json" >/dev/null

printf 'public dashboard native admin-key boundary: ok\n'
