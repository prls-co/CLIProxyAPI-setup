#!/usr/bin/env bash
# TEST-009
set -euo pipefail
export LC_ALL=C

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"

python3 - <<'PY'
from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path

path = Path("scripts/render-public-config.py")
spec = spec_from_file_location("render_public_config", path)
if spec is None or spec.loader is None:
    raise SystemExit("could not load public edge renderer")
module = module_from_spec(spec)
spec.loader.exec_module(module)

rendered = module.render_caddyfile()
if rendered.count("reverse_proxy cli-proxy-api:4000") != 1:
    raise SystemExit("public API must have exactly one CPA upstream")
if rendered.count("reverse_proxy cpa-manager-plus:18317") != 1:
    raise SystemExit("dashboard must have exactly one management upstream")
if "@openai_api path /v1 /v1/* /healthz /healthz/* /health/liveliness" not in rendered:
    raise SystemExit("public API route matcher is incomplete")
PY

mkdir -p artifacts/P05
printf 'TEST-009 status=pass api_upstreams=1 management_upstreams=1\n' >artifacts/P05/TEST-009-green.txt
printf 'public edge configuration: ok\n'
