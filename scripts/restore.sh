#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
umask 077

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

helper_image='eceasy/cli-proxy-api@sha256:53162ac4ebf4f399b729a80830ad13e992add2430e1387a54e09a192987f6df3'

usage() {
  cat <<'EOF'
Usage: bash scripts/restore.sh [--validate-only] BACKUP_ARCHIVE

Validate and restore a CPA state archive created by scripts/backup.sh. The
current state directory is moved into backups as a recoverable pre-restore
copy. Services remain stopped after a successful restore; run
scripts/bootstrap.sh --skip-login next to render configuration, switch the
public tunnel, and start the machine.

--validate-only  Verify the archive without stopping services or changing state.
EOF
}

validate_only=0
if (( $# > 0 )) && [[ "$1" == --validate-only ]]; then
  validate_only=1
  shift
fi
if [[ $# == 0 || "$1" == --help || "$1" == -h ]]; then
  usage
  [[ $# == 0 ]] && exit 2 || exit 0
fi
if [[ $# != 1 ]]; then
  usage >&2
  exit 2
fi

for command_name in docker python3 readlink mktemp date mv mkdir cp chmod find id rm; do
  command -v "$command_name" >/dev/null || {
    printf 'required command is unavailable: %s\n' "$command_name" >&2
    exit 1
  }
done
docker info >/dev/null

archive="$(readlink -f -- "$1")"
[[ -f "$archive" ]] || {
  printf 'backup archive is unavailable: %s\n' "$1" >&2
  exit 1
}
if [[ -L state ]]; then
  printf 'refusing to restore into symlinked state directory\n' >&2
  exit 1
fi

temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/cliproxyapi-restore.XXXXXX")"
state_gitignore="$temporary_directory/state.gitignore"
local_env_backup="$temporary_directory/env.local"
local_env_existed=0
rollback_path=''
restore_committed=0

cleanup() {
  if (( restore_committed == 0 )) && [[ -n "$rollback_path" && -d "$rollback_path" ]]; then
    failed_path="$root/backups/.failed-restore-$(date -u +%Y%m%dT%H%M%SZ)-$$"
    if [[ -d "$root/state" ]]; then
      mv "$root/state" "$failed_path" 2>/dev/null || true
    fi
    mv "$rollback_path" "$root/state" 2>/dev/null || true
    printf 'restore failed; original state was returned to state/\n' >&2
    printf 'failed restored state was retained at %s\n' "$failed_path" >&2
  fi
  if (( restore_committed == 0 )); then
    if (( local_env_existed == 1 )); then
      cp "$local_env_backup" .env.local 2>/dev/null || true
      chmod 600 .env.local 2>/dev/null || true
    else
      rm -f .env.local 2>/dev/null || true
    fi
  fi
  rm -rf -- "$temporary_directory"
}
trap cleanup EXIT

if [[ -L .env.local || ( -e .env.local && ! -f .env.local ) ]]; then
  printf 'refusing to use non-regular .env.local\n' >&2
  exit 1
fi
if [[ -f .env.local ]]; then
  cp .env.local "$local_env_backup"
  local_env_existed=1
fi

if [[ -f state/.gitignore ]]; then
  cp state/.gitignore "$state_gitignore"
else
  printf '*\n!.gitignore\n' >"$state_gitignore"
  chmod 664 "$state_gitignore"
fi

operator_uid="$(id -u)"
operator_gid="$(id -g)"
docker run --rm --network none --user "$operator_uid:$operator_gid" \
  -v "$archive:/backup/archive.tar.gz:ro" \
  -v "$temporary_directory:/restore" \
  --entrypoint /bin/bash \
  "$helper_image" -euc '
    set -euo pipefail
    tar -tzf /backup/archive.tar.gz > /tmp/archive.list
    while IFS= read -r path; do
      case "$path" in
        /*|../*|*/../*|*/..|"")
          printf "unsafe archive path\n" >&2
          exit 1
          ;;
      esac
    done < /tmp/archive.list
    tar --no-same-owner -xzf /backup/archive.tar.gz -C /restore
    if find /restore/state -type l -print -quit | grep -q .; then
      printf "symbolic links are not allowed in state archives\n" >&2
      exit 1
    fi
    [[ -s /restore/manifest.tsv ]]
    checked=0
    while IFS="$(printf "\\011")" read -r path expected_hash expected_mode expected_uid expected_gid expected_size; do
      case "$path" in state/*) ;; *) printf "unsafe manifest path\n" >&2; exit 1 ;; esac
      file="/restore/$path"
      [[ -f "$file" && ! -L "$file" ]]
      actual_hash="$(sha256sum "$file")"
      actual_hash="${actual_hash%% *}"
      [[ "$actual_hash" == "$expected_hash" ]]
      [[ "$(stat -c %a "$file")" == "$expected_mode" ]]
      [[ "$(stat -c %s "$file")" == "$expected_size" ]]
      checked=$((checked + 1))
    done </restore/manifest.tsv
    (( checked > 0 ))
    for required in \
      state/cpa/config.yaml \
      state/cpamp/data/data.key \
      state/cpamp/data/usage.sqlite \
      state/secrets/cpa-api-key \
      state/secrets/cpa-management-key \
      state/secrets/cpamp-admin-key \
      state/secrets/tunnel-token; do
      [[ -s "/restore/$required" ]]
    done
    find /restore/state/cpa/auths -maxdepth 1 -type f -name "*.json" -print -quit | grep -q .
  '

if (( validate_only == 1 )); then
  printf 'archive validation complete: %s\n' "$archive"
  exit 0
fi

if command -v systemctl >/dev/null && systemctl --user is-active --quiet cliproxyapi-setup.service; then
  unit_root="$(systemctl --user show cliproxyapi-setup.service -p WorkingDirectory --value)"
  if [[ "$unit_root" == "$root" ]]; then
    systemctl --user stop cliproxyapi-setup.service
  fi
fi
docker compose --profile public stop cloudflared >/dev/null 2>&1 || true
docker compose stop cpamp-public cpa-manager-plus cli-proxy-api >/dev/null 2>&1 || true

mkdir -p backups
chmod 700 backups
if [[ -d state ]]; then
  rollback_path="$root/backups/.pre-restore-state-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  mv state "$rollback_path"
fi
mkdir -m 700 state
cp "$state_gitignore" state/.gitignore
cp -a "$temporary_directory/state/." state/
find state -type d -exec chmod 700 {} +
find state/secrets -maxdepth 1 -type f -exec chmod 600 {} +
chmod 600 state/cpa/config.yaml

export CPA_API_KEY="$(<state/secrets/cpa-api-key)"
export CPA_MANAGEMENT_KEY="$(<state/secrets/cpa-management-key)"
export CPAMP_ADMIN_KEY="$(<state/secrets/cpamp-admin-key)"
export CPA_TUNNEL_TOKEN="$(<state/secrets/tunnel-token)"
python3 scripts/sync-local-env.py CPA_API_KEY CPA_MANAGEMENT_KEY CPAMP_ADMIN_KEY CPA_TUNNEL_TOKEN

restore_committed=1
printf 'state restore complete\n'
if [[ -n "$rollback_path" ]]; then
  printf 'previous state retained at %s\n' "$rollback_path"
fi
printf 'services remain stopped; next run: bash scripts/bootstrap.sh --skip-login\n'
