#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

timeout 180 bash -c 'until docker info >/dev/null 2>&1; do sleep 2; done'
bash scripts/init-state.sh
python3 scripts/render-cpa-config.py
python3 scripts/render-public-config.py
docker compose up -d cli-proxy-api cpa-manager-plus
docker compose up -d --force-recreate cpamp-public
docker compose --profile public up -d cloudflared
timeout 180 bash -c 'until curl -fsS http://127.0.0.1:8317/healthz >/dev/null; do sleep 1; done'
timeout 180 bash -c 'until curl -fsS http://127.0.0.1:18317/health | jq -e ".ok == true" >/dev/null; do sleep 1; done'
timeout 180 bash -c 'until curl -fsS http://127.0.0.1:18417/health | jq -e ".ok == true" >/dev/null; do sleep 1; done'
