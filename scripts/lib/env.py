"""Small, strict .env reader used by generated runtime configuration."""

from __future__ import annotations

import re
import shlex
from pathlib import Path


ASSIGNMENT = re.compile(r"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$")


def load_env(path: Path) -> dict[str, str]:
    if not path.is_file():
        raise ValueError(f"required environment file is unavailable: {path}")

    values: dict[str, str] = {}
    for line_number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        match = ASSIGNMENT.fullmatch(line)
        if match is None:
            raise ValueError(f"invalid .env assignment at {path}:{line_number}")
        key, raw_value = match.groups()
        if key in values:
            raise ValueError(f"duplicate .env variable: {key}")
        try:
            tokens = shlex.split(raw_value, comments=False, posix=True)
        except ValueError as error:
            raise ValueError(f"invalid .env value for {key}: {error}") from error
        if len(tokens) > 1:
            raise ValueError(f"unquoted whitespace in .env value for {key}")
        values[key] = tokens[0] if tokens else ""
    return values


def require_env_value(values: dict[str, str], key: str) -> str:
    value = values.get(key, "").strip()
    if not value:
        raise ValueError(f"required .env variable is empty: {key}")
    return value
