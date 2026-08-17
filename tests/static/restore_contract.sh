#!/usr/bin/env bash
# TEST-016
set -euo pipefail
export LC_ALL=C

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"

script=scripts/restore.sh
[[ -x "$script" ]] || { printf 'missing executable: %s\n' "$script" >&2; exit 1; }
bash -n "$script"

for phrase in \
  '.env' \
  '.env.local is unsupported' \
  '--network none' \
  'tar -tzf /backup/archive.tar.gz' \
  'unsafe archive path' \
  'symbolic links are not allowed' \
  'sha256sum' \
  '.pre-restore-state-' \
  '--validate-only' \
  'scripts/bootstrap.sh --skip-login'; do
  grep -Fq -- "$phrase" "$script" || {
    printf 'restore script is missing: %s\n' "$phrase" >&2
    exit 1
  }
done

if grep -Eq 'state/secrets|sync-local-env|CPA_API_KEY_FILE' "$script"; then
  printf 'restore script contains obsolete credential storage\n' >&2
  exit 1
fi

if grep -Eq 'set[[:space:]]+-x|set[[:space:]]+-eux|set[[:space:]]+-ex' "$script"; then
  printf 'shell tracing is forbidden in restore script\n' >&2
  exit 1
fi
if rg -n 'Bearer [A-Za-z0-9_-]{20,}|eyJ[A-Za-z0-9_-]{20,}' "$script"; then
  printf 'embedded credential found in restore script\n' >&2
  exit 1
fi

bash "$script" --help >/dev/null
printf 'restore contract: ok\n'
