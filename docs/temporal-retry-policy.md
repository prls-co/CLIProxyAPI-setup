# CPA retry policy for durable callers

## 1. Configuration ownership

The renderer reads these optional settings from the canonical protected `.env`:

| Environment variable | CPA setting | Default | Accepted range |
| --- | --- | --- | --- |
| `CPA_REQUEST_RETRY` | `request-retry` | 3 | 0–10 |
| `CPA_MAX_RETRY_CREDENTIALS` | `max-retry-credentials` | 1 | 0–1000 |
| `CPA_MAX_RETRY_INTERVAL_SECONDS` | `max-retry-interval` | 30 | 0–3600 seconds |

Blank or absent settings retain the existing defaults. Invalid values fail
before publishing configuration. `python3 scripts/render-cpa-config.py` renders
the existing mode-0600 runtime file atomically; it does not restart CPA. Changing
the shared service's policy affects every consumer and needs separate rollout
qualification. This change does not edit the local `.env` or running policy.

These settings govern retry rounds, credential selection and cooldown waiting.
They do not increase account quota or configure an active-call concurrency cap.
Keep account cooling enabled. Do not rotate identities to circumvent a provider
restriction. `max-retry-credentials: 0` permits all eligible credentials during
selection; it is not a zero-concurrency setting.

## 2. Durable caller recommendation

Harden-LLM's self-hosted Temporal dispatcher can persist queue state and honor
`Retry-After`. `request-retry: 0` is a candidate when that dispatcher owns retry
timing: it exposes the first refusal promptly instead of hiding upstream rounds
inside an occupied caller slot. Preserve `max-retry-credentials: 1` and cooling.
Direct/synchronous consumers may rely on CPA's existing retries, so retain the
shared default `3` until they have been qualified. There is no per-request
retry-policy override in this repository.

The owner handoff is [issue #6](https://github.com/prls-co/CLIProxyAPI-setup/issues/6).
Before promotion, compare successful results, refusals, native attempt counts,
latency, recovery, authentication and existing consumer contracts with 0 and 3.
Never infer native attempt counts from the caller's HTTP 200 alone.

## 3. Pinned-image qualification

On 2026-10-16, `TEST-024` ran both settings against the pinned deployed image
`sha256:99bedd436cf04530451aeff67b88d3e76dfff2f2c48691dbf68d07e0c27c7288`
using an isolated container and local synthetic upstream (no real account,
provider credentials or shared-service changes). The upstream returned one
503, then success, with a three-second transient cooldown:

| Setting | Caller observations | Native synthetic calls |
| --- | --- | --- |
| 0 | First 503 in 42 ms; immediate cooling refusal in 7 ms with `Retry-After`; later success in 7 ms | 2 across 3 caller requests |
| 3 | One HTTP 200 in 3,474 ms after CPA waited and retried | 2 inside 1 caller request |

Both passed and removed their owned containers. This establishes retry/cooling
semantics for that synthetic failure. It does not establish Codex quota, live
throughput or compatibility of all shared consumers. Refresh explicitly with:

```sh
node tests/integration/patched_image_recovery.cjs PINNED_IMAGE FRESH_OUTPUT_JSON 0
node tests/integration/patched_image_recovery.cjs PINNED_IMAGE FRESH_OUTPUT_JSON 3
```

`make test-unit` covers rendering and rejects invalid/injected settings without
reading real secrets. `make test-static` checks repository/deployment contracts.
