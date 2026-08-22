#!/usr/bin/env bash
# TEST-003
set -euo pipefail
export LC_ALL=C

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"

for script in scripts/cpa-codex-login.sh scripts/cpa-claude-login.sh; do
  [[ -x "$script" ]] || { printf 'missing executable: %s\n' "$script" >&2; exit 1; }
  grep -Fq 'set -euo pipefail' "$script"
  if grep -Eq 'set[[:space:]]+-x|set[[:space:]]+-eux|set[[:space:]]+-ex' "$script"; then
    printf 'shell tracing is forbidden in login wrapper\n' >&2
    exit 1
  fi
  grep -Fq 'docker compose run' "$script"
  grep -Fq -- '--rm' "$script"
  grep -Fq -- '--no-deps' "$script"
  grep -Fq -- '--interactive' "$script"
  grep -Fq -- '--tty' "$script"
  grep -Fq 'cli-proxy-api' "$script"
  grep -Fq './CLIProxyAPI' "$script"
  grep -Fq -- '-config /CLIProxyAPI/config.yaml' "$script"
done
grep -Fq -- '-codex-device-login' scripts/cpa-codex-login.sh
grep -Fq -- '-claude-login' scripts/cpa-claude-login.sh
grep -Fq -- '-no-browser' scripts/cpa-claude-login.sh
grep -Fq -- '-p 127.0.0.1:54545:54545' scripts/cpa-claude-login.sh
grep -Fq 'state/cpa/auths' compose.yaml

smoke_script=scripts/smoke-claude.fish
[[ -x "$smoke_script" ]] || { printf 'missing executable: %s\n' "$smoke_script" >&2; exit 1; }
fish -n "$smoke_script"
grep -Fq -- 'curl -fsS --config -' "$smoke_script"
grep -Fq -- 'claude-sonnet-5' "$smoke_script"
grep -Fq -- 'claude-ok' "$smoke_script"
if grep -Eq -- '-H[[:space:]]+"x-api-key:|set[[:space:]]+-[^[:space:]]*x[^[:space:]]*[[:space:]]+CPA_API_KEY' "$smoke_script"; then
  printf 'Claude smoke must not expose CPA_API_KEY through argv or child environment\n' >&2
  exit 1
fi

printf 'login wrapper contract: ok\n'
