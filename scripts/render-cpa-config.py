#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parent.parent
TEMPLATE = ROOT / "config" / "cpa" / "config.yaml.template"
OUTPUT = ROOT / "state" / "cpa" / "config.yaml"
sys.path.insert(0, str(ROOT / "scripts"))

from lib.env import load_env, require_env_value  # noqa: E402


def read_secret(values: dict[str, str], name: str) -> str:
    return require_env_value(values, name)


def main() -> None:
    values = load_env(ROOT / ".env")
    text = TEMPLATE.read_text(encoding="utf-8")
    replacements = {
        "__CPA_MANAGEMENT_KEY_JSON__": json.dumps(read_secret(values, "CPA_MANAGEMENT_KEY")),
        "__CPA_API_KEY_JSON__": json.dumps(read_secret(values, "CPA_API_KEY")),
    }
    for marker, value in replacements.items():
        if marker not in text:
            raise SystemExit(f"missing template marker: {marker}")
        text = text.replace(marker, value)
    if "__CPA_" in text:
        raise SystemExit("unrendered CPA template marker")

    OUTPUT.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    tmp = OUTPUT.with_name(f"{OUTPUT.name}.tmp.{os.getpid()}")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, OUTPUT)
        os.chmod(OUTPUT, 0o600)
    finally:
        if tmp.exists():
            tmp.unlink()


if __name__ == "__main__":
    main()
