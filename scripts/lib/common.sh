#!/usr/bin/env bash
set -euo pipefail

repo_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd
}

require_nonempty_file() {
  local path="$1"
  [[ -s "$path" ]] || { printf 'required file is unavailable: %s\n' "$path" >&2; return 1; }
}

secure_file_mode() {
  local path="$1"
  chmod 600 "$path"
}

load_env() {
  local root restore_allexport=0
  root="$(repo_root)"
  [[ -f "$root/.env" ]] || { printf 'required environment file is unavailable: %s/.env\n' "$root" >&2; return 1; }
  if [[ -e "$root/.env.local" ]]; then
    printf '.env.local is unsupported; move all values to .env and remove it\n' >&2
    return 1
  fi
  [[ $- == *a* ]] && restore_allexport=1
  set -a
  # shellcheck disable=SC1091
  source "$root/.env"
  (( restore_allexport == 1 )) || set +a
}

ensure_env_secret() {
  local variable="$1" prefix="$2" random_bytes="$3" max_length="$4"
  local value="${!variable:-}"

  if [[ -z "$value" ]]; then
    value="${prefix}$(openssl rand -hex "$random_bytes")"
  fi
  if (( ${#value} > max_length )); then
    printf '%s exceeds its maximum supported length\n' "$variable" >&2
    return 1
  fi

  printf -v "$variable" '%s' "$value"
  export "$variable"
  python3 "$(repo_root)/scripts/sync-env.py" "$variable"
}
