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

load_local_env() {
  local root file restore_allexport=0
  root="$(repo_root)"
  [[ $- == *a* ]] && restore_allexport=1
  set -a
  for file in "$root/.env" "$root/.env.local"; do
    if [[ -f "$file" ]]; then
      # shellcheck disable=SC1090
      source "$file"
    fi
  done
  (( restore_allexport == 1 )) || set +a
}

write_runtime_secret_mirror() {
  local path="$1" value="$2"
  local temporary
  temporary="$(mktemp "${path}.tmp.XXXXXX")"
  printf '%s' "$value" >"$temporary"
  secure_file_mode "$temporary"
  mv -f "$temporary" "$path"
}

ensure_local_secret() {
  local variable="$1" path="$2" prefix="$3" random_bytes="$4" max_length="$5"
  local value="${!variable:-}"

  if [[ -z "$value" && -s "$path" ]]; then
    value="$(<"$path")"
  fi
  if [[ -z "$value" ]]; then
    value="${prefix}$(openssl rand -hex "$random_bytes")"
  fi
  if (( ${#value} > max_length )); then
    printf '%s exceeds its maximum supported length\n' "$variable" >&2
    return 1
  fi

  printf -v "$variable" '%s' "$value"
  export "$variable"
  write_runtime_secret_mirror "$path" "$value"
}
