#!/usr/bin/env bash
# EVAL-001
set -euo pipefail
export LC_ALL=C

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
mkdir -p artifacts/P00

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

for run in 1 2 3; do
  bash tests/static/test_repository_contract.sh >"$tmp/run-$run.txt"
done

unique_hashes="$(sha256sum "$tmp"/run-*.txt | awk '{print $1}' | sort -u | wc -l)"
if [[ "$unique_hashes" -ne 1 ]]; then
  printf 'harness output was not reproducible\n' >&2
  exit 1
fi

jq -n \
  --argjson successful_runs 3 \
  --argjson unique_normalized_output_hashes "$unique_hashes" \
  '{successful_runs:$successful_runs,unique_normalized_output_hashes:$unique_normalized_output_hashes,status:"pass"}' \
  > artifacts/P00/EVAL-001.json

printf 'harness reproducibility: ok\n'
