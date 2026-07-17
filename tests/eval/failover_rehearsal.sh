#!/usr/bin/env bash
# EVAL-005
set -euo pipefail
export LC_ALL=C

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"

[[ "${ALLOW_PUBLIC_FAILOVER:-}" == 1 ]] || { printf 'set ALLOW_PUBLIC_FAILOVER=1 to authorize public failover rehearsal\n' >&2; exit 2; }
: "${PUBLIC_BASE_URL:=https://cpa.prls.co/v1}"
: "${PUBLIC_API_KEY_FILE:=state/secrets/cpa-api-key}"
: "${MODEL:=gpt-5.4-mini}"
[[ -s "$PUBLIC_API_KEY_FILE" ]] || { printf 'public API key file is unavailable\n' >&2; exit 1; }

artifact_dir=artifacts/P05/EVAL-005
mkdir -p "$artifact_dir"
samples="$artifact_dir/samples.ndjson"
: >"$samples"
connector_change_count=0

connector_snapshot() {
  docker ps --format '{{.Names}}\t{{.ID}}' |
    awk '$1 == "cliproxyapi-setup-cloudflared-1" || $1 == "shaman-api-cloudflared-1"' |
    sort
}

baseline_connectors="$(connector_snapshot)"
[[ "$(wc -l <<<"$baseline_connectors")" == 2 ]] || {
  printf 'CPA and LiteLLM connectors must both be running before rehearsal\n' >&2
  exit 1
}

transition_index=0
for seed in 7101 7102; do
  for target in litellm cpa; do
    transition_index=$((transition_index + 1))
    start_ns="$(date +%s%N)"
    trace="$artifact_dir/transition-$transition_index-$target.trace"
    log="$artifact_dir/transition-$transition_index-$target.log"
    SWITCH_TRACE_FILE="$trace" bash scripts/switch-origin.sh "$target" >"$log" 2>&1 &
    pid=$!
    connector_changed=0
    while kill -0 "$pid" 2>/dev/null; do
      if [[ "$(connector_snapshot)" != "$baseline_connectors" ]]; then
        connector_changed=1
      fi
      sleep 0.1
    done
    set +e
    wait "$pid"
    rc=$?
    set -e
    end_ns="$(date +%s%N)"
    duration_ms=$(( (end_ns - start_ns) / 1000000 ))
    connector_change_count=$((connector_change_count + connector_changed))

    [[ "$rc" -eq 0 ]] || { printf 'transition %s to %s failed\n' "$transition_index" "$target" >&2; exit 1; }
    [[ "$(<state/active-origin)" == "$target" ]]
    [[ "$(connector_snapshot)" == "$baseline_connectors" ]]
    (( duration_ms <= 120000 ))

    jq -nc \
      --argjson transition "$transition_index" \
      --argjson seed "$seed" \
      --arg target "$target" \
      --argjson recovery_ms "$duration_ms" \
      --argjson connector_changed "$connector_changed" \
      '{transition:$transition,seed:$seed,target:$target,status:"pass",recovery_ms:$recovery_ms,connector_changed:$connector_changed}' \
      >>"$samples"
    printf 'transition %s -> %s recovered in %sms\n' "$transition_index" "$target" "$duration_ms"
  done
done

[[ "$(<state/active-origin)" == cpa ]]
(( connector_change_count == 0 ))
PUBLIC_BASE_URL="$PUBLIC_BASE_URL" PUBLIC_API_KEY_FILE="$PUBLIC_API_KEY_FILE" MODEL="$MODEL" \
  ARTIFACT_DIR="$artifact_dir/final-public-contract" bash tests/e2e/public_contract.sh

python3 - "$samples" "$artifact_dir/summary.json" <<'PY'
import json
import random
import statistics
import sys

samples = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
durations = [sample["recovery_ms"] / 1000 for sample in samples]
rng = random.Random(7101)
means = sorted(statistics.mean(rng.choices(durations, k=len(durations))) for _ in range(10000))
connector_changes = sum(sample["connector_changed"] for sample in samples)
successes = sum(sample["status"] == "pass" for sample in samples)
summary = {
    "evaluation": "EVAL-005",
    "status": "pass" if len(samples) == 4 and successes == 4 and connector_changes == 0 and max(durations) <= 120 and samples[-1]["target"] == "cpa" else "fail",
    "transition_count": len(samples),
    "transition_success_rate": successes / 4,
    "connector_change_count": connector_changes,
    "recovery_seconds": {
        "mean": statistics.mean(durations),
        "standard_deviation": statistics.pstdev(durations),
        "max": max(durations),
        "bootstrap_mean_95_ci": [means[249], means[9749]],
    },
    "final_origin": samples[-1]["target"],
    "thresholds": {"transition_success_rate": 1.0, "connector_change_count": 0, "recovery_seconds_max": 120},
    "samples": samples,
}
with open(sys.argv[2], "w", encoding="utf-8") as handle:
    json.dump(summary, handle, indent=2)
    handle.write("\n")
if summary["status"] != "pass":
    raise SystemExit(1)
PY

printf 'public failover evaluation: ok\n'
