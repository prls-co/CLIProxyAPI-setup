#!/usr/bin/env bash
set -euo pipefail
umask 077

# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
root="$(repo_root)"
cd "$root"

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

write_generated_secret() {
  local path="$1"
  local prefix="$2"
  local random_bytes="$3"
  local max_length="$4"
  if [[ -s "$path" ]]; then
    local current
    current="$(<"$path")"
    if (( ${#current} <= max_length )); then
      secure_file_mode "$path"
      return
    fi
  fi
  local tmp
  tmp="$(mktemp "${path}.tmp.XXXXXX")"
  printf '%s%s' "$prefix" "$(openssl rand -hex "$random_bytes")" >"$tmp"
  secure_file_mode "$tmp"
  mv -f "$tmp" "$path"
}

write_generated_secret state/secrets/cpa-management-key cpa_mgmt_ 30 72
write_generated_secret state/secrets/cpamp-admin-key cpamp_ 32 128
