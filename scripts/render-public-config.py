#!/usr/bin/env python3
"""Render the public edge from the canonical .env configuration."""

from __future__ import annotations

import os
from pathlib import Path
import re
import socket
import sys
import tempfile


ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

from lib.env import load_env  # noqa: E402


def resolve_origin_hostname(values: dict[str, str] | None = None) -> str:
    if values is None:
        values = load_env(ROOT / ".env") if (ROOT / ".env").is_file() else {}
    value = values.get("CPA_ORIGIN_HOSTNAME", "").strip() or socket.gethostname().strip()
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,252}", value):
        raise ValueError("CPA origin hostname is empty or has an unexpected format")
    return value


def render_caddyfile(origin_hostname: str | None = None) -> str:
    origin_hostname = origin_hostname or resolve_origin_hostname()
    return f""":4000 {{
\t@openai_api path /v1 /v1/* /healthz /healthz/* /health/liveliness
\thandle @openai_api {{
\t\treverse_proxy cli-proxy-api:4000 {{
\t\t\theader_down X-CPA-Origin-Hostname "{origin_hostname}"
\t\t}}
\t}}

\thandle {{
\t\treverse_proxy cpa-manager-plus:18317
\t}}
}}
"""


def atomic_write(path: Path, content: str, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(path.parent, 0o700)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def main() -> int:
    values = load_env(ROOT / ".env")

    # The Caddy container runs as uid 1000, while the checkout owner varies
    # between machines. This file contains only routing rules, so it must be
    # world-readable on the bind mount for the fixed container uid to read it.
    atomic_write(
        ROOT / "state" / "cpamp-public" / "Caddyfile",
        render_caddyfile(resolve_origin_hostname(values)),
        mode=0o644,
    )
    print("rendered public edge configuration from .env")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError) as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
