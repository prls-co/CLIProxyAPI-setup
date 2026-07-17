#!/usr/bin/env bash
set -euo pipefail
umask 077

# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
root="$(repo_root)"
source_env="/home/kirill/p/litellm-chatgpt/.env"
cd "$root"

require_nonempty_file "$source_env"
bash scripts/init-state.sh

set -a
# shellcheck disable=SC1091
source "$source_env"
set +a

: "${LITELLM_MASTER_KEY:?LITELLM_MASTER_KEY is missing from the source environment}"

write_imported_secret() {
  local path="$1"
  local value="$2"
  if [[ -s "$path" ]]; then
    secure_file_mode "$path"
    return
  fi
  local tmp
  tmp="$(mktemp "${path}.tmp.XXXXXX")"
  printf '%s' "$value" >"$tmp"
  secure_file_mode "$tmp"
  mv -f "$tmp" "$path"
}

write_imported_secret state/secrets/cpa-api-key "$LITELLM_MASTER_KEY"
unset LITELLM_MASTER_KEY
