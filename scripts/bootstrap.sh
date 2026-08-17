#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
umask 077

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

# shellcheck source=scripts/lib/common.sh
source scripts/lib/common.sh

usage() {
  cat <<'EOF'
Usage: bash scripts/bootstrap.sh [--skip-login] [--skip-systemd]

Prepare this checkout as the active public CPA machine. The command creates
the ignored .env file when needed, prompts for a missing Cloudflare API token
without echoing it, initializes local state, performs Codex device login when
no OAuth state is present, switches the public tunnel, and installs the user
service.

--skip-login     Use existing state/cpa/auths without starting device login.
--skip-systemd   Do not install or start the systemd user service.
--help           Show this help.
EOF
}

skip_login=0
skip_systemd=0
while (($# > 0)); do
  case "$1" in
    --skip-login) skip_login=1 ;;
    --skip-systemd) skip_systemd=1 ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      printf 'unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

required_commands=(docker curl jq python3 flock openssl find timeout install)
if (( skip_systemd == 0 )); then
  required_commands+=(systemctl)
fi
for command_name in "${required_commands[@]}"; do
  command -v "$command_name" >/dev/null || {
    printf 'required command is unavailable: %s\n' "$command_name" >&2
    exit 1
  }
done
docker compose version >/dev/null
docker info >/dev/null

[[ -f compose.yaml && -f .env.example ]] || {
  printf 'run this command from the repository checkout\n' >&2
  exit 1
}
if [[ -L .env || ( -e .env && ! -f .env ) ]]; then
  printf 'refusing to use non-regular .env\n' >&2
  exit 1
fi
if [[ ! -e .env ]]; then
  install -m 600 .env.example .env
  printf 'created ignored .env from .env.example\n'
fi
chmod 600 .env

load_env
if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
  if [[ ! -t 0 || ! -t 1 ]]; then
    printf 'CLOUDFLARE_API_TOKEN is missing from .env and no interactive terminal is available\n' >&2
    printf 'add it to .env, then rerun this command\n' >&2
    exit 1
  fi
  printf 'Cloudflare API token (input hidden): '
  IFS= read -r -s cloudflare_api_token
  printf '\n'
  [[ -n "$cloudflare_api_token" ]] || {
    printf 'Cloudflare API token cannot be empty\n' >&2
    exit 1
  }
  export CLOUDFLARE_API_TOKEN="$cloudflare_api_token"
  python3 scripts/sync-env.py CLOUDFLARE_API_TOKEN
  unset cloudflare_api_token
fi

printf 'initializing local state\n'
bash scripts/init-state.sh
python3 scripts/render-cpa-config.py

auth_file="$(find state/cpa/auths -maxdepth 1 -type f -name '*.json' -print -quit)"
if [[ -z "$auth_file" ]]; then
  if (( skip_login == 1 )); then
    printf 'Codex OAuth state is missing; rerun without --skip-login for device login\n' >&2
    exit 1
  fi
  if [[ ! -t 0 || ! -t 1 ]]; then
    printf 'Codex OAuth state is missing and no interactive terminal is available\n' >&2
    printf 'rerun this command interactively, or restore state before using --skip-login\n' >&2
    exit 1
  fi
  printf 'no Codex OAuth state found; starting device login\n'
  bash scripts/cpa-codex-login.sh
  auth_file="$(find state/cpa/auths -maxdepth 1 -type f -name '*.json' -print -quit)"
  [[ -n "$auth_file" ]] || {
    printf 'Codex device login completed without producing OAuth state\n' >&2
    exit 1
  }
else
  printf 'existing Codex OAuth state found; skipping device login\n'
fi

printf 'starting private services for readiness\n'
docker compose up -d cli-proxy-api cpa-manager-plus
timeout 180 bash -c 'until curl -fsS http://127.0.0.1:8317/healthz >/dev/null; do sleep 1; done'
timeout 180 bash -c 'until curl -fsS http://127.0.0.1:18317/health | jq -e ".ok == true" >/dev/null; do sleep 1; done'

printf 'switching the canonical public gateway to this machine\n'
bash scripts/switch-current-machine.sh

if (( skip_systemd == 0 )); then
  printf 'installing the user service\n'
  bash scripts/install-systemd-service.sh
fi

printf 'bootstrap complete for cpa.prls.co\n'
printf 'manual credentials remain only in .env; do not print or commit it\n'
