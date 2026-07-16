#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
umask 077

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
helper_image='eceasy/cli-proxy-api@sha256:6f5bcee0c3b8d0536f4a3f0f5cb9fd0b7d2e17196dd40d30f11aec9cc2f5f161'
archive="${1:-}"
[[ -f "$archive" ]] || { printf 'backup archive is unavailable\n' >&2; exit 1; }
archive="$(readlink -f "$archive")"
restore="$(mktemp -d)"

cleanup() {
  docker run --rm --network none -v "$restore:/restore" --entrypoint /bin/bash "$helper_image" -euc 'rm -rf /restore/* /restore/.[!.]* /restore/..?* 2>/dev/null || true' >/dev/null 2>&1 || true
  rmdir "$restore" 2>/dev/null || true
}
trap cleanup EXIT

docker run --rm --network none \
  -v "$archive:/backup/archive.tar.gz:ro" \
  -v "$restore:/restore" \
  --entrypoint /bin/bash \
  "$helper_image" -euc '
    while IFS= read -r path; do
      case "$path" in /*|../*|*/../*|*/..) printf "unsafe archive path\n" >&2; exit 1 ;; esac
    done < <(tar -tzf /backup/archive.tar.gz)
    tar --numeric-owner -xzf /backup/archive.tar.gz -C /restore
    [[ -s /restore/manifest.tsv ]]
    checked=0
    while IFS=$'"'"'\t'"'"' read -r path expected_hash expected_mode expected_uid expected_gid expected_size; do
      file="/restore/$path"
      [[ -f "$file" ]]
      [[ "$(sha256sum "$file" | awk "{print \$1}")" == "$expected_hash" ]]
      [[ "$(stat -c %a "$file")" == "$expected_mode" ]]
      [[ "$(stat -c %u "$file")" == "$expected_uid" ]]
      [[ "$(stat -c %g "$file")" == "$expected_gid" ]]
      [[ "$(stat -c %s "$file")" == "$expected_size" ]]
      checked=$((checked + 1))
    done </restore/manifest.tsv
    printf "{\"test\":\"restore\",\"status\":\"pass\",\"checked_files\":%s,\"hash_match_rate\":1.0,\"mode_match_rate\":1.0,\"ownership_match_rate\":1.0}\n" "$checked"
  '
