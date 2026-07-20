#!/usr/bin/env bash
# TEST-004
set -euo pipefail
export LC_ALL=C
umask 077

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"

required_scripts=(scripts/init-state.sh scripts/configure-cloudflare.sh scripts/render-cpa-config.py scripts/render-public-config.py)
for file in "${required_scripts[@]}"; do
  [[ -x "$file" ]] || { printf 'missing executable: %s\n' "$file" >&2; exit 1; }
done

bash scripts/init-state.sh
python3 scripts/render-cpa-config.py
python3 scripts/render-public-config.py

secret_files=(
  state/secrets/cpa-api-key
  state/secrets/cpa-management-key
  state/secrets/cpamp-admin-key
  state/secrets/tunnel-token
)
for file in "${secret_files[@]}" state/cpa/config.yaml state/cpamp-public/Caddyfile; do
  [[ -s "$file" ]] || { printf 'missing generated state file: %s\n' "$file" >&2; exit 1; }
  mode="$(stat -c '%a' "$file")"
  [[ "$mode" == 600 ]] || { printf 'incorrect mode %s for %s\n' "$mode" "$file" >&2; exit 1; }
done

for dir in state state/secrets state/cpa state/cpa/auths state/cpa/logs state/cpamp state/cpamp/data state/cpamp-public; do
  mode="$(stat -c '%a' "$dir")"
  [[ "$mode" == 700 ]] || { printf 'incorrect mode %s for %s\n' "$mode" "$dir" >&2; exit 1; }
done

git check-ignore -q state/secrets/cpa-api-key
git check-ignore -q state/cpa/config.yaml
git check-ignore -q state/cpamp/data/usage.sqlite
git check-ignore -q state/cpamp-public/Caddyfile
git check-ignore -q .env
[[ "$(stat -c '%a' .env)" == 600 ]] || { printf '.env must be mode 0600\n' >&2; exit 1; }
python3 - <<'PY'
from pathlib import Path
expected = Path("state/secrets/cpamp-admin-key").read_text(encoding="utf-8").strip()
values = []
for raw in Path(".env").read_text(encoding="utf-8").splitlines():
    line = raw.strip()
    if line and not line.startswith("#") and "=" in line:
        key, value = line.split("=", 1)
        if key.strip() == "CPAMP_ADMIN_KEY":
            values.append(value.strip().strip("\"'"))
if values != [expected]:
    raise SystemExit(".env must contain exactly one matching CPAMP_ADMIN_KEY")
PY
if grep -Eq 'basic_auth|header_up[[:space:]]+Authorization' state/cpamp-public/Caddyfile; then
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

for secret_file in "${secret_files[@]}"; do
  secret="$(<"$secret_file")"
  [[ -n "$secret" ]] || { printf 'empty secret file: %s\n' "$secret_file" >&2; exit 1; }
  if [[ "$secret_file" == state/secrets/cpa-management-key && ${#secret} -gt 72 ]]; then
    printf 'CPA management key exceeds bcrypt limit\n' >&2
    exit 1
  fi
  while IFS= read -r candidate; do
    case "$candidate" in
      ./.git/*|./state/*|./backups/*|./artifacts/*) continue ;;
    esac
    if [[ "$secret_file" == state/secrets/cpamp-admin-key && "$candidate" == ./.env ]]; then
      continue
    fi
    if grep -Fq -- "$secret" "$candidate" 2>/dev/null; then
      printf 'secret value found outside ignored state: %s\n' "$candidate" >&2
      exit 1
    fi
  done < <(find . -type f -not -path './.git/*' | sort)
done

printf 'secret hygiene: ok\n'
