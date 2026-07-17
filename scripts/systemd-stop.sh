#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
exec 9>state/switch-origin.lock
flock -w 30 9 || { printf 'could not acquire connector lock for shutdown\n' >&2; exit 1; }

docker compose --profile public stop cloudflared
docker compose stop cpamp-public cpa-manager-plus cli-proxy-api
