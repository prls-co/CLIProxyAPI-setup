#!/usr/bin/env bash
# TEST-013
set -euo pipefail
export LC_ALL=C

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"

required=(
  systemd/cliproxyapi-setup.service.in
  scripts/systemd-start.sh
  scripts/systemd-stop.sh
  scripts/install-systemd-service.sh
  config/litellm/compose.override.yaml
  docs/operations.md
)
for file in "${required[@]}"; do
  [[ -f "$file" ]] || { printf 'systemd implementation is unavailable: %s\n' "$file" >&2; exit 1; }
done
for file in scripts/systemd-start.sh scripts/systemd-stop.sh scripts/install-systemd-service.sh; do
  [[ -x "$file" ]]
done

unit=systemd/cliproxyapi-setup.service.in
grep -Eq '^After=.*network-online.target' "$unit"
grep -Eq '^Type=oneshot$' "$unit"
grep -Eq '^RemainAfterExit=yes$' "$unit"
grep -Fq 'WorkingDirectory=@ROOT@' "$unit"
grep -Fq 'ExecStart=@ROOT@/scripts/systemd-start.sh' "$unit"
grep -Fq 'ExecStop=@ROOT@/scripts/systemd-stop.sh' "$unit"
grep -Eq '^Restart=on-failure$' "$unit"
grep -Eq '^UMask=0077$' "$unit"
grep -Eq '^PrivateTmp=true$' "$unit"
grep -Eq '^NoNewPrivileges=true$' "$unit"

grep -Fq 'python3 scripts/render-public-config.py' scripts/systemd-start.sh
grep -Fq 'docker compose up -d cli-proxy-api cpa-manager-plus' scripts/systemd-start.sh
grep -Fq 'docker compose up -d --force-recreate cpamp-public' scripts/systemd-start.sh
grep -Fq 'scripts/switch-origin.sh "$origin"' scripts/systemd-start.sh
grep -Fq 'docker compose --profile public stop cloudflared' scripts/systemd-stop.sh
grep -Fq 'docker compose stop cpamp-public cpa-manager-plus cli-proxy-api' scripts/systemd-stop.sh
grep -Fq 'compose.override.yaml' scripts/install-systemd-service.sh
grep -Fq 'systemctl --user enable cliproxyapi-setup.service' scripts/install-systemd-service.sh
grep -Fq 'scripts/systemd-start.sh' scripts/install-systemd-service.sh
grep -Eq '^    profiles:$' config/litellm/compose.override.yaml

for phrase in 'device login' 'health' 'contract tests' 'cut over' 'roll back' 'backup' 'restore' 'upgrade' 'incident'; do
  grep -Fqi "$phrase" docs/operations.md || { printf 'operations documentation is missing: %s\n' "$phrase" >&2; exit 1; }
done

if rg -n 'Bearer [A-Za-z0-9_-]{20,}|eyJ[A-Za-z0-9_-]{20,}' systemd scripts/systemd-start.sh scripts/systemd-stop.sh scripts/install-systemd-service.sh docs/operations.md config/litellm/compose.override.yaml; then
  printf 'embedded credential found in boot integration\n' >&2
  exit 1
fi

mkdir -p artifacts/P06
sha256sum "$unit" | awk '{print "TEST-013 status=pass unit_sha256=" $1}' >artifacts/P06/TEST-013-green.txt
printf 'systemd boot contract: ok\n'
