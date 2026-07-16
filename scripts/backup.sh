#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
umask 077

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
helper_image='eceasy/cli-proxy-api@sha256:6f5bcee0c3b8d0536f4a3f0f5cb9fd0b7d2e17196dd40d30f11aec9cc2f5f161'
mkdir -p backups
chmod 700 backups
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
archive_name="cpa-state-$timestamp-$$.tar.gz"
archive="$root/backups/$archive_name"
work="$(mktemp -d "$root/backups/.backup-work.XXXXXX")"
cpamp_stopped=0

restart_cpamp() {
  if (( cpamp_stopped == 1 )); then
    docker compose up -d cpa-manager-plus >&2
    timeout 90 bash -c 'until curl -fsS http://127.0.0.1:18317/health | jq -e ".ok == true" >/dev/null; do sleep 1; done'
    cpamp_stopped=0
  fi
}

cleanup() {
  restart_cpamp || true
  docker run --rm --network none -v "$work:/work" --entrypoint /bin/bash "$helper_image" -euc 'rm -rf /work/* /work/.[!.]* /work/..?* 2>/dev/null || true' >/dev/null 2>&1 || true
  rmdir "$work" 2>/dev/null || true
}
trap cleanup EXIT

for required in \
  state/cpa/config.yaml \
  state/cpamp/data/data.key \
  state/cpamp/data/usage.sqlite \
  state/secrets/cpa-api-key \
  state/secrets/cpa-management-key \
  state/secrets/cpamp-admin-key \
  state/secrets/tunnel-token \
  state/active-origin; do
  [[ -f "$required" ]] || { printf 'required backup state is unavailable: %s\n' "$required" >&2; exit 1; }
done
find state/cpa/auths -maxdepth 1 -type f -name '*.json' -print -quit | grep -q . || { printf 'Codex OAuth state is unavailable\n' >&2; exit 1; }

docker compose stop cpa-manager-plus >&2
cpamp_stopped=1

docker run --rm --network none \
  -e ARCHIVE_NAME="$archive_name" \
  -e HOST_UID="$(id -u)" \
  -e HOST_GID="$(id -g)" \
  -v "$root:/source:ro" \
  -v "$work:/work" \
  --entrypoint /bin/bash \
  "$helper_image" -euc '
    cd /source
    mkdir -p /work/payload
    files=(
      state/cpa/config.yaml
      state/active-origin
      state/cpamp/data/data.key
      state/cpamp/data/usage.sqlite
    )
    while IFS= read -r -d "" file; do files+=("$file"); done < <(find state/cpa/auths -maxdepth 1 -type f -name "*.json" -print0 | sort -z)
    while IFS= read -r -d "" file; do files+=("$file"); done < <(find state/secrets -maxdepth 1 -type f -print0 | sort -z)
    while IFS= read -r -d "" file; do
      case "$file" in state/cpamp/data/usage.sqlite) ;; *) files+=("$file") ;; esac
    done < <(find state/cpamp/data -maxdepth 1 -type f -name "usage.sqlite*" -print0 | sort -z)
    cp -a --parents "${files[@]}" /work/payload
    cd /work/payload
    : >manifest.tsv
    while IFS= read -r -d "" path; do
      printf "%s\t%s\t%s\t%s\t%s\t%s\n" \
        "$path" \
        "$(sha256sum "$path" | awk "{print \$1}")" \
        "$(stat -c %a "$path")" \
        "$(stat -c %u "$path")" \
        "$(stat -c %g "$path")" \
        "$(stat -c %s "$path")" >>manifest.tsv
    done < <(find state -type f -print0 | sort -z)
    tar --sort=name --numeric-owner -czf "/work/$ARCHIVE_NAME" manifest.tsv state
    chmod 0600 "/work/$ARCHIVE_NAME"
    chown "$HOST_UID:$HOST_GID" "/work/$ARCHIVE_NAME"
  ' >/dev/null

mv "$work/$archive_name" "$archive"
chmod 600 "$archive"
restart_cpamp
printf '%s\n' "$archive"
