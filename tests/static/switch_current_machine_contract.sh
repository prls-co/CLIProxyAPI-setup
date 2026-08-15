#!/usr/bin/env bash
# TEST-014
set -euo pipefail
export LC_ALL=C

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"

script=scripts/switch-current-machine.sh
[[ -x "$script" ]] || { printf 'missing executable: %s\n' "$script" >&2; exit 1; }
bash -n "$script"

for phrase in \
  'bash scripts/init-state.sh' \
  'bash scripts/configure-cloudflare.sh' \
  'docker compose up -d --force-recreate cpamp-public' \
  'docker compose --profile public up -d --force-recreate cloudflared-token-init' \
  'docker compose --profile public up -d --force-recreate cloudflared' \
  'cfd_tunnel/$tunnel_id/connections?client_id='; do
  grep -Fq "$phrase" "$script" || {
    printf 'switch script is missing: %s\n' "$phrase" >&2
    exit 1
  }
done

if rg -n 'curl[^\n]*(cpa\.prls\.co|shaman\.prls\.co)|PUBLIC_BASE_URL' "$script"; then
  printf 'switch script must not probe the public CPA hostname\n' >&2
  exit 1
fi
if rg -n 'Bearer [A-Za-z0-9_-]{20,}|eyJ[A-Za-z0-9_-]{20,}' "$script"; then
  printf 'embedded credential found in switch script\n' >&2
  exit 1
fi

printf 'current-machine switch contract: ok\n'
