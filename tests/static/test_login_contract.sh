#!/usr/bin/env bash
# TEST-003
set -euo pipefail
export LC_ALL=C

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"

script=scripts/cpa-codex-login.sh
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
grep -Fq -- '-codex-device-login' "$script"
grep -Fq 'state/cpa/auths' compose.yaml

printf 'login wrapper contract: ok\n'
