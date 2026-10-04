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
login_started_epoch="$(date +%s)"
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

python3 - "$login_started_epoch" <<'PY' || {
import datetime
import json
import pathlib
import sys

started = int(sys.argv[1])
now = datetime.datetime.now(datetime.timezone.utc)
for path in pathlib.Path('state/cpa/auths').glob('*.json'):
    try:
        auth = json.loads(path.read_text())
        if auth.get('type') != 'claude' or auth.get('disabled', False):
            continue
        if not all(isinstance(auth.get(key), str) and auth[key].strip()
                   for key in ('access_token', 'refresh_token')):
            continue
        expires = datetime.datetime.fromisoformat(auth['expired'].replace('Z', '+00:00'))
        refreshed = datetime.datetime.fromisoformat(auth['last_refresh'].replace('Z', '+00:00'))
        if (expires.tzinfo is not None and refreshed.tzinfo is not None
                and expires > now and started <= refreshed.timestamp() <= now.timestamp()):
            sys.exit(0)
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        continue
sys.exit(1)
PY
  printf 'Claude login did not produce fresh, unexpired OAuth state; complete browser authorization and retry\n' >&2
  exit 1
}

printf 'Claude OAuth state is ready; CPA will load it without a restart\n'
