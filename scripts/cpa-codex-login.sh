#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
root="$(repo_root)"
cd "$root"

require_nonempty_file state/cpa/config.yaml
docker compose run --rm --no-deps --interactive --tty \
  cli-proxy-api ./CLIProxyAPI -config /CLIProxyAPI/config.yaml -codex-device-login

operator_uid="$(id -u)"
operator_gid="$(id -g)"
docker compose run --rm --no-deps \
  -e OPERATOR_UID="$operator_uid" -e OPERATOR_GID="$operator_gid" \
  cli-proxy-api /usr/bin/bash -c \
  'find /root/.cli-proxy-api -type f -name "*.json" -exec chmod 600 {} + -exec chown "$OPERATOR_UID:$OPERATOR_GID" {} +'
