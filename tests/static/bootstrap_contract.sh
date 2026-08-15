#!/usr/bin/env bash
# TEST-015
set -euo pipefail
export LC_ALL=C

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"

script=scripts/bootstrap.sh
[[ -x "$script" ]] || { printf 'missing executable: %s\n' "$script" >&2; exit 1; }
bash -n "$script"

for phrase in \
  'bash scripts/init-state.sh' \
  'bash scripts/cpa-codex-login.sh' \
  'bash scripts/switch-current-machine.sh' \
  'bash scripts/install-systemd-service.sh' \
  'python3 scripts/sync-local-env.py CLOUDFLARE_API_TOKEN'; do
  grep -Fq "$phrase" "$script" || {
    printf 'bootstrap script is missing: %s\n' "$phrase" >&2
    exit 1
  }
done

if grep -Eq 'set[[:space:]]+-x|set[[:space:]]+-eux|set[[:space:]]+-ex' "$script"; then
  printf 'shell tracing is forbidden in bootstrap script\n' >&2
  exit 1
fi
if rg -n 'Bearer [A-Za-z0-9_-]{20,}|eyJ[A-Za-z0-9_-]{20,}' "$script"; then
  printf 'embedded credential found in bootstrap script\n' >&2
  exit 1
fi

bash "$script" --help >/dev/null
printf 'bootstrap contract: ok\n'
