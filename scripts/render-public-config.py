#!/usr/bin/env python3
"""Render the public edge and mirror CPAMP's native admin key into .env."""

from __future__ import annotations

import os
from pathlib import Path
import re
import sys
import tempfile


ROOT = Path(__file__).resolve().parent.parent
ENV_PATH = ROOT / ".env"
STATE = ROOT / "state"


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


def sync_dotenv_key(path: Path, key: str, value: str) -> None:
    lines = path.read_text(encoding="utf-8").splitlines()
    replacement = f"{key}={value}"
    output: list[str] = []
    replaced = False
    for line in lines:
        candidate = line.strip()
        if candidate and not candidate.startswith("#") and "=" in candidate:
            current = candidate.split("=", 1)[0].strip()
            if current == key:
                if not replaced:
                    output.append(replacement)
                    replaced = True
                continue
        output.append(line)
    if not replaced:
        if output and output[-1] != "":
            output.append("")
        output.append(replacement)

    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write("\n".join(output) + "\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def main() -> int:
    if not ENV_PATH.is_file():
        raise ValueError(f"missing ignored environment file: {ENV_PATH}")
    admin_key = (STATE / "secrets" / "cpamp-admin-key").read_text(encoding="utf-8").strip()
    if not re.fullmatch(r"[A-Za-z0-9._-]{16,256}", admin_key):
        raise ValueError("CPAMP admin key is empty or has an unexpected format")
    sync_dotenv_key(ENV_PATH, "CPAMP_ADMIN_KEY", admin_key)

    origin = os.environ.get("CPA_PUBLIC_ORIGIN")
    if origin is None:
        origin = (STATE / "active-origin").read_text(encoding="utf-8").strip()
    upstreams = {
        "cpa": "cli-proxy-api:4000",
        "litellm": "litellm:4000",
    }
    if origin not in upstreams:
        raise ValueError("public origin must be exactly cpa or litellm")
    api_upstream = upstreams[origin]

    caddyfile = f""":4000 {{
\t@openai_api path /v1 /v1/* /healthz /healthz/* /health/liveliness
\thandle @openai_api {{
\t\treverse_proxy {api_upstream}
\t}}

\thandle {{
\t\treverse_proxy cpa-manager-plus:18317
\t}}
}}
"""
    atomic_write(STATE / "cpamp-public" / "Caddyfile", caddyfile)
    print(f"rendered {origin} API and native-admin-key dashboard edge configuration")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError) as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
