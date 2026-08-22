#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
root="$(repo_root)"
cd "$root"

require_nonempty_file state/cpa/config.yaml
[[ -t 0 && -t 1 ]] || {
  printf 'Claude OAuth login requires an interactive terminal\n' >&2
  exit 1
}

printf 'SSH login: keep a local port forward to this host open on port 54545\n'
printf 'the login command will print the authorization URL; open it in your local browser\n'
docker compose run --rm --no-deps --interactive --tty \
  -p 127.0.0.1:54545:54545 \
  cli-proxy-api ./CLIProxyAPI \
  -config /CLIProxyAPI/config.yaml \
  -claude-login \
  -no-browser

operator_uid="$(id -u)"
operator_gid="$(id -g)"
docker compose run --rm --no-deps \
  -e OPERATOR_UID="$operator_uid" -e OPERATOR_GID="$operator_gid" \
  cli-proxy-api /usr/bin/bash -c \
  'find /root/.cli-proxy-api -type f -name "*.json" -exec chmod 600 {} + -exec chown "$OPERATOR_UID:$OPERATOR_GID" {} +'

claude_auth_found=0
while IFS= read -r auth_file; do
  if jq -e \
    '.type == "claude" and
     (.access_token | type == "string" and length > 0) and
     (.refresh_token | type == "string" and length > 0)' \
    "$auth_file" >/dev/null 2>&1; then
    claude_auth_found=1
    break
  fi
done < <(find state/cpa/auths -maxdepth 1 -type f -name '*.json' | sort)
[[ "$claude_auth_found" -eq 1 ]] || {
  printf 'Claude login completed without producing usable OAuth state\n' >&2
  exit 1
}

printf 'Claude OAuth state is ready; CPA will load it without a restart\n'
