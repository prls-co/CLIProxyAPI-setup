#!/usr/bin/env bash
# EVAL-002
set -euo pipefail
export LC_ALL=C

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
mkdir -p artifacts/P01

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

sanitize_config() {
  local destination="$1"
  python3 - "$destination" <<'PY'
from pathlib import Path
import sys
root = Path.cwd()
text = (root / "state/cpa/config.yaml").read_text()
for name in ("cpa-management-key", "cpa-api-key"):
    value = (root / "state/secrets" / name).read_text()
    text = text.replace(value, f"REDACTED_{name.upper().replace('-', '_')}")
Path(sys.argv[1]).write_text(text)
PY
}

for run in 1 2; do
  python3 scripts/render-cpa-config.py
  sanitize_config "$tmp/cpa-$run.yaml"
  COMPOSE_PROJECT_NAME=cliproxyapi-repro docker compose --profile public config --format json \
    | jq -S . >"$tmp/compose-$run.json"
done

cmp -s "$tmp/cpa-1.yaml" "$tmp/cpa-2.yaml"
cmp -s "$tmp/compose-1.json" "$tmp/compose-2.json"

cpa_expected='sha256:6f5bcee0c3b8d0536f4a3f0f5cb9fd0b7d2e17196dd40d30f11aec9cc2f5f161'
cpamp_expected='sha256:5897b299887dbe7a8fa2e23850fe64949e5a60a94ba5e5aebd3acd810e710351'
cpa_actual="$(docker buildx imagetools inspect eceasy/cli-proxy-api:v7.2.80 | awk '/^Digest:/ {print $2; exit}')"
cpamp_actual="$(docker buildx imagetools inspect seakee/cpa-manager-plus:v1.11.2 | awk '/^Digest:/ {print $2; exit}')"
[[ "$cpa_actual" == "$cpa_expected" ]]
[[ "$cpamp_actual" == "$cpamp_expected" ]]

jq -n \
  --arg cpa_config_sha256 "$(sha256sum "$tmp/cpa-1.yaml" | awk '{print $1}')" \
  --arg compose_sha256 "$(sha256sum "$tmp/compose-1.json" | awk '{print $1}')" \
  --arg cpa_digest "$cpa_actual" \
  --arg cpamp_digest "$cpamp_actual" \
  '{render_match_rate:1,pinned_digest_match_rate:1,cpa_config_sha256:$cpa_config_sha256,compose_sha256:$compose_sha256,cpa_digest:$cpa_digest,cpamp_digest:$cpamp_digest,status:"pass"}' \
  > artifacts/P01/EVAL-002.json

printf 'compose reproducibility: ok\n'
