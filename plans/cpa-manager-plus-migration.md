# Canonical CPA gateway plan

## Status

The canonical gateway migration tracker
[#1](https://github.com/prls-co/CLIProxyAPI-setup/issues/1) is closed.
The utility-llm [provider migration #15](https://github.com/prls-co/utility-llm/issues/15)
and query-set [consumer migration #14](https://github.com/prls-co/query-set/issues/14)
are closed. Independent defects and their acceptance evidence remain separate
from that completed migration.

Issue [#2](https://github.com/prls-co/CLIProxyAPI-setup/issues/2) is closed.
Its accepted resolution is that `lowest` means the lowest effort supported by the
selected model through CPA. Unsupported `none -> low` normalization is allowed.
See the [reasoning policy, capability snapshot and regression gates](../docs/reasoning-effort.md).
All release gates and production acceptance passed on 2026-10-04; the updated
tests, documentation and sanitized evidence are published on main.

## Current ownership and decisions

```text
consumers -> utility-llm -> cpa.prls.co -> CLIProxyAPI -> subscription OAuth backend
```

- This repository owns the sole canonical public API origin,
  `https://cpa.prls.co/v1`, its Compose stack, public edge and Cloudflare tunnel.
- Persisted Codex and Claude OAuth provide subscription access. Paid OpenAI
  and Anthropic provider configuration remains absent.
- CPA Manager Plus owns operational usage collection. utility-llm owns
  application tracing and per-model provider/reasoning mappings.
- The maintained CPA image is `v7.3.8-prls.3`, pinned by immutable digest in
  `compose.yaml`. Source/build identity and rollback are documented in
  [the maintained-image contract](../docs/patched-cpa-image.md).
- `gpt-6-astra` at `low` is the setup Codex baseline. utility-llm acceptance
  uses CPA Luna and Sol at contracted `lowest`; Claude uses `claude-sonnet-5`.
- Raw service ports remain loopback-only. The public edge routes `/v1/*`
  directly to CPA and other paths to CPA Manager Plus.
- Consumer changes belong in consumer repositories and are coordinated through
  their issues.

## Ongoing release acceptance

- Run every static, unit, security, integration, contract, observability,
  public and evaluation group before pushing or reconciling production.
- Require completed Responses metadata, strict schema equality, expected
  reasoning effort, and public origin identity.
- Preserve streaming and nonstreaming schema, native web search, client tools,
  usage collection, redaction, restart persistence and isolated backup/restore
  coverage.
- Run the stream lifecycle diagnostic for normal completion and client abort.
- Retain commit/image identity, timing and sanitized test evidence. Historical
  consumer incident and host reboot evidence is not re-certified by a setup
  policy-only release.
