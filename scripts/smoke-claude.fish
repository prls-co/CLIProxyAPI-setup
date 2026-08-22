#!/usr/bin/env fish

set -l script_dir (path resolve (dirname (status filename)))
set -l root (path resolve "$script_dir/..")
cd "$root"; or exit 1

test -f .env; or begin
    echo 'required environment file is unavailable: .env' >&2
    exit 1
end

set -l CPA_API_KEY (bash -c 'source "$1"; printf "%s" "${CPA_API_KEY:-}"' bash "$root/.env")
test -n "$CPA_API_KEY"; or begin
    echo 'CPA_API_KEY is missing from .env' >&2
    exit 1
end

set -l response (printf 'header = "x-api-key: %s"\n' "$CPA_API_KEY" | \
    curl -fsS --config - --max-time 30 https://cpa.prls.co/v1/messages \
    -H 'anthropic-version: 2023-06-01' \
    --json '{"model":"claude-sonnet-5","max_tokens":16,"messages":[{"role":"user","content":"Reply exactly: claude-ok"}]}')
or exit 1

set -l output_text (string join \n $response | jq -er \
    '.content | map(select(.type == "text") | .text) | join("")')
or exit 1

test "$output_text" = claude-ok; or begin
    echo 'unexpected Claude subscription response' >&2
    exit 1
end

printf '%s\n' "$output_text"
