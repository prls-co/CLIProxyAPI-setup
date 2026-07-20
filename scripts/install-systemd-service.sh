#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
umask 077

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
unit_path="$unit_dir/cliproxyapi-setup.service"

install -d -m 0755 "$unit_dir"
docker compose -f "$root/compose.yaml" --profile public config >/dev/null

escaped_root="${root//&/\\&}"
escaped_root="${escaped_root//|/\\|}"
tmp="$(mktemp "$unit_dir/.cliproxyapi-setup.service.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
sed "s|@ROOT@|$escaped_root|g" "$root/systemd/cliproxyapi-setup.service.in" >"$tmp"
chmod 0644 "$tmp"
mv -f "$tmp" "$unit_path"

systemctl --user daemon-reload
systemctl --user enable cliproxyapi-setup.service

docker_gid="$(getent group docker | awk -F: '{print $3}')"
manager_pid="$(pgrep -u "$(id -u)" -x systemd | head -n 1)"
if [[ -n "$manager_pid" ]] && awk -v gid="$docker_gid" '$1 == "Groups:" {for (i=2; i<=NF; i++) if ($i == gid) found=1} END {exit !found}' "/proc/$manager_pid/status"; then
  systemctl --user restart cliproxyapi-setup.service
  systemctl --user is-active --quiet cliproxyapi-setup.service
else
  systemctl --user stop cliproxyapi-setup.service >/dev/null 2>&1 || true
  systemctl --user reset-failed cliproxyapi-setup.service >/dev/null 2>&1 || true
  bash "$root/scripts/systemd-start.sh"
  printf 'unit enabled; live activation deferred until the user manager restarts with Docker group membership\n' >&2
fi
sha256sum "$unit_path" | awk -v path="$unit_path" '{print path " sha256=" $1}'
