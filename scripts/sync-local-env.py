#!/usr/bin/env python3
"""Atomically synchronize selected exported secrets into ignored .env.local."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import sys
import tempfile


ROOT = Path(__file__).resolve().parent.parent
LOCAL_ENV = ROOT / ".env.local"
BASE_ENV = ROOT / ".env"
ASSIGNMENT = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=")
SAFE_VALUE = re.compile(r"^[A-Za-z0-9_@%+=:,./-]+$")


def quote(value: str) -> str:
    if "\x00" in value or "\n" in value or "\r" in value:
        raise ValueError("environment secret contains an unsupported control character")
    if SAFE_VALUE.fullmatch(value):
        return value
    return "'" + value.replace("'", "'\"'\"'") + "'"


def atomic_write(path: Path, content: str) -> None:
    if path.is_symlink():
        raise ValueError(f"refusing to replace symlink: {path}")
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def assignment_key(line: str) -> str | None:
    match = ASSIGNMENT.match(line)
    return match.group(1) if match else None


def synchronize(path: Path, values: dict[str, str]) -> None:
    lines = path.read_text(encoding="utf-8").splitlines() if path.exists() else []
    output: list[str] = []
    written: set[str] = set()
    for line in lines:
        key = assignment_key(line)
        if key not in values:
            output.append(line)
            continue
        if key not in written:
            output.append(f"{key}={quote(values[key])}")
            written.add(key)

    missing = [key for key in values if key not in written]
    if missing:
        if output and output[-1] != "":
            output.append("")
        if not lines:
            output.append("# Machine-local secrets. Never commit this file.")
        output.extend(f"{key}={quote(values[key])}" for key in missing)

    atomic_write(path, "\n".join(output) + "\n")


def scrub(path: Path, keys: set[str]) -> None:
    if not path.exists():
        return
    lines = path.read_text(encoding="utf-8").splitlines()
    output = [line for line in lines if assignment_key(line) not in keys]
    atomic_write(path, "\n".join(output) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--scrub-base", action="store_true")
    parser.add_argument("variables", nargs="+")
    args = parser.parse_args()

    values: dict[str, str] = {}
    for name in args.variables:
        value = os.environ.get(name)
        if not value:
            raise ValueError(f"required exported secret is unavailable: {name}")
        values[name] = value

    synchronize(LOCAL_ENV, values)
    if args.scrub_base:
        scrub(BASE_ENV, set(values))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
