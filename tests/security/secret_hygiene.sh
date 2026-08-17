#!/usr/bin/env bash
# TEST-004
set -euo pipefail
export LC_ALL=C
umask 077

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"

required_scripts=(
  scripts/bootstrap.sh
  scripts/restore.sh
  scripts/init-state.sh
  scripts/configure-cloudflare.sh
  scripts/switch-current-machine.sh
  scripts/render-cpa-config.py
  scripts/render-public-config.py
  scripts/sync-env.py
)
for file in "${required_scripts[@]}"; do
  [[ -x "$file" ]] || { printf 'missing executable: %s\n' "$file" >&2; exit 1; }
done

bash scripts/init-state.sh
python3 scripts/render-cpa-config.py
python3 scripts/render-public-config.py

[[ -f .env ]] || { printf 'missing canonical .env\n' >&2; exit 1; }
[[ "$(stat -c '%a' .env)" == 600 ]] || { printf '.env must be mode 0600\n' >&2; exit 1; }
[[ ! -e .env.local ]] || { printf '.env.local must not exist\n' >&2; exit 1; }
[[ ! -e state/secrets ]] || { printf 'state/secrets mirrors must not exist\n' >&2; exit 1; }

for file in state/cpa/config.yaml; do
  [[ -s "$file" ]] || { printf 'missing generated state file: %s\n' "$file" >&2; exit 1; }
  [[ "$(stat -c '%a' "$file")" == 600 ]] || { printf 'incorrect mode for %s\n' "$file" >&2; exit 1; }
done
[[ -s state/cpamp-public/Caddyfile ]] || { printf 'missing generated Caddyfile\n' >&2; exit 1; }
[[ "$(stat -c '%a' state/cpamp-public/Caddyfile)" == 644 ]] || {
  printf 'generated Caddyfile must be mode 644 for the fixed edge uid\n' >&2
  exit 1
}

for dir in state state/cpa state/cpa/auths state/cpa/logs state/cpamp state/cpamp/data state/cpamp-public; do
  mode="$(stat -c '%a' "$dir")"
  [[ "$mode" == 700 ]] || { printf 'incorrect mode %s for %s\n' "$mode" "$dir" >&2; exit 1; }
done

git check-ignore -q .env
git check-ignore -q state/cpa/config.yaml
git check-ignore -q state/cpamp/data/usage.sqlite
git check-ignore -q state/cpamp-public/Caddyfile

python3 - <<'PY'
from pathlib import Path
import sys

sys.path.insert(0, str(Path.cwd() / "scripts"))
from lib.env import load_env, require_env_value

values = load_env(Path(".env"))
required = (
    "CPA_API_KEY",
    "CPA_MANAGEMENT_KEY",
    "CPAMP_ADMIN_KEY",
    "CLOUDFLARE_API_TOKEN",
    "CPA_TUNNEL_TOKEN",
)
for key in required:
    require_env_value(values, key)
if len(values["CPA_MANAGEMENT_KEY"]) > 72:
    raise SystemExit("CPA management key exceeds bcrypt limit")

for candidate in sorted(Path(".").rglob("*")):
    if not candidate.is_file():
        continue
    if any(part in {".git", "state", "backups", "artifacts"} for part in candidate.parts):
        continue
    if candidate == Path(".env"):
        continue
    text = candidate.read_text(encoding="utf-8", errors="ignore")
    for key in required:
        if values[key] and values[key] in text:
            raise SystemExit(f"{key} value found outside .env: {candidate}")
PY

if grep -Eqi 'basic_auth|header_up[[:space:]]+Authorization' state/cpamp-public/Caddyfile; then
  printf 'redundant dashboard authentication found in edge configuration\n' >&2
  exit 1
fi

grep -q '__CPA_' config/cpa/config.yaml.template
if grep -q '__CPA_' state/cpa/config.yaml; then
  printf 'unrendered placeholder in generated CPA config\n' >&2
  exit 1
fi
if grep -Eqi 'openai-api-key|OPENAI_API_KEY' state/cpa/config.yaml; then
  printf 'paid OpenAI provider configuration is forbidden\n' >&2
  exit 1
fi

printf 'secret hygiene: ok\n'
