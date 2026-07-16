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
