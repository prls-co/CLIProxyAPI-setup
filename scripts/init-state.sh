#!/usr/bin/env bash
set -euo pipefail
umask 077

# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
root="$(repo_root)"
cd "$root"
load_env

if [[ -e state/secrets ]]; then
  printf 'state/secrets is obsolete; move its values into .env and remove the directory\n' >&2
  exit 1
fi

directories=(
  state
  state/cpa
  state/cpa/auths
  state/cpa/logs
  state/cpamp
  state/cpamp/data
  state/cpamp-public
)
mkdir -p "${directories[@]}"
chmod 700 "${directories[@]}"

ensure_env_secret CPA_API_KEY cpa_ 32 128
ensure_env_secret CPA_MANAGEMENT_KEY cpa_mgmt_ 30 72
ensure_env_secret CPAMP_ADMIN_KEY cpamp_ 32 128

secret_variables=(CPA_API_KEY CPA_MANAGEMENT_KEY CPAMP_ADMIN_KEY)
if [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]]; then
  secret_variables+=(CLOUDFLARE_API_TOKEN)
fi
if [[ -n "${CPA_TUNNEL_TOKEN:-}" ]]; then
  secret_variables+=(CPA_TUNNEL_TOKEN)
fi

python3 scripts/sync-env.py "${secret_variables[@]}"
