#!/usr/bin/env bash
set -euo pipefail
umask 077

# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
root="$(repo_root)"
cd "$root"
load_local_env

directories=(
  state
  state/secrets
  state/cpa
  state/cpa/auths
  state/cpa/logs
  state/cpamp
  state/cpamp/data
  state/cpamp-public
)
mkdir -p "${directories[@]}"
chmod 700 "${directories[@]}"

ensure_local_secret CPA_API_KEY state/secrets/cpa-api-key cpa_ 32 128
ensure_local_secret CPA_MANAGEMENT_KEY state/secrets/cpa-management-key cpa_mgmt_ 30 72
ensure_local_secret CPAMP_ADMIN_KEY state/secrets/cpamp-admin-key cpamp_ 32 128

secret_variables=(CPA_API_KEY CPA_MANAGEMENT_KEY CPAMP_ADMIN_KEY)
if [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]]; then
  export CLOUDFLARE_API_TOKEN
  secret_variables+=(CLOUDFLARE_API_TOKEN)
fi
if [[ -z "${CPA_TUNNEL_TOKEN:-}" && -s state/secrets/tunnel-token ]]; then
  CPA_TUNNEL_TOKEN="$(<state/secrets/tunnel-token)"
fi
if [[ -n "${CPA_TUNNEL_TOKEN:-}" ]]; then
  export CPA_TUNNEL_TOKEN
  secret_variables+=(CPA_TUNNEL_TOKEN)
  write_runtime_secret_mirror state/secrets/tunnel-token "$CPA_TUNNEL_TOKEN"
fi

python3 scripts/sync-local-env.py --scrub-base "${secret_variables[@]}"
