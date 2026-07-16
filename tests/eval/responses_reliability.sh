#!/usr/bin/env bash
# EVAL-003
set -euo pipefail
export LC_ALL=C

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
: "${CPA_BASE_URL:=http://127.0.0.1:8317}"
: "${CPA_API_KEY_FILE:=state/secrets/cpa-api-key}"
: "${MODEL:=gpt-5.4-mini}"

artifact_dir=artifacts/P03/EVAL-003
mkdir -p "$artifact_dir"
results="$artifact_dir/results.tsv"
: >"$results"

run_samples() {
  local case_name="$1"
  local count="$2"
  local prefix="$3"
  for sample in $(seq 1 "$count"); do
    correlation="EVAL-003-${prefix}-${sample}"
    started="$(date +%s%N)"
    set +e
    CASE_FILTER="$case_name" CORRELATION_ID="$correlation" \
      CPA_BASE_URL="$CPA_BASE_URL" CPA_API_KEY_FILE="$CPA_API_KEY_FILE" MODEL="$MODEL" \
      bash tests/contract/responses_contract.sh >"$artifact_dir/$correlation.log" 2>&1
    status=$?
    set -e
    elapsed=$(( ($(date +%s%N) - started) / 1000000 ))
    printf '%s\t%s\t%s\t%s\n' "$case_name" "$sample" "$status" "$elapsed" >>"$results"
  done
}

run_samples strict-schema 10 strict
run_samples web-search-schema 5 combined

python3 - "$results" "$artifact_dir/summary.json" <<'PY'
import json
import math
import statistics
import sys
from pathlib import Path

rows = []
for line in Path(sys.argv[1]).read_text().splitlines():
    case, sample, status, elapsed = line.split("\t")
    rows.append((case, int(sample), int(status), int(elapsed)))

def rate(case):
    selected = [row for row in rows if row[0] == case]
    return sum(row[2] == 0 for row in selected) / len(selected)

def wilson(successes, total):
    z = 1.959963984540054
    p = successes / total
    denominator = 1 + z * z / total
    center = (p + z * z / (2 * total)) / denominator
    margin = z * math.sqrt((p * (1 - p) + z * z / (4 * total)) / total) / denominator
    return [center - margin, center + margin]

strict = [r for r in rows if r[0] == "strict-schema"]
combined = [r for r in rows if r[0] == "web-search-schema"]
times = [r[3] for r in rows]
summary = {
    "strict_schema_conformance_rate": rate("strict-schema"),
    "combined_search_schema_conformance_rate": rate("web-search-schema"),
    "combined_search_call_rate": rate("web-search-schema"),
    "max_request_seconds": max(times) / 1000,
    "mean_request_seconds": statistics.mean(times) / 1000,
    "strict_wilson_95_ci": wilson(sum(r[2] == 0 for r in strict), len(strict)),
    "combined_wilson_95_ci": wilson(sum(r[2] == 0 for r in combined), len(combined)),
}
summary["status"] = "pass" if (
    summary["strict_schema_conformance_rate"] == 1
    and summary["combined_search_schema_conformance_rate"] == 1
    and summary["combined_search_call_rate"] == 1
    and summary["max_request_seconds"] <= 20
) else "fail"
Path(sys.argv[2]).write_text(json.dumps(summary, indent=2) + "\n")
if summary["status"] != "pass":
    raise SystemExit(1)
PY

printf 'Responses reliability: ok\n'
