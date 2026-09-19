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
sys.path.insert(0, str(root / "scripts"))
from lib.env import load_env
values = load_env(root / ".env")
text = (root / "state/cpa/config.yaml").read_text()
for name in ("CPA_MANAGEMENT_KEY", "CPA_API_KEY"):
    text = text.replace(values[name], f"REDACTED_{name}")
Path(sys.argv[1]).write_text(text)
PY
}

for run in 1 2; do
  python3 scripts/render-cpa-config.py
  sanitize_config "$tmp/cpa-$run.yaml"
  docker compose --project-name cliproxyapi-repro --profile public config --format json \
    | jq -S . >"$tmp/compose-$run.json"
done

cmp -s "$tmp/cpa-1.yaml" "$tmp/cpa-2.yaml"
cmp -s "$tmp/compose-1.json" "$tmp/compose-2.json"

cpa_expected='sha256:99bedd436cf04530451aeff67b88d3e76dfff2f2c48691dbf68d07e0c27c7288'
cpamp_expected='sha256:5897b299887dbe7a8fa2e23850fe64949e5a60a94ba5e5aebd3acd810e710351'
cpa_actual="$(docker buildx imagetools inspect ghcr.io/prls-co/cli-proxy-api-patched:v7.3.8-prls.3-f375487d29a06bd4cb0ad204cc19dbcf6e7dfb6d | awk '/^Digest:/ {print $2; exit}')"
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
