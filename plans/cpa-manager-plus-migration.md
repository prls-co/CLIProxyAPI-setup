# Canonical CPA gateway plan

## Status and target

Status: implemented infrastructure with consumer migration and incident-level
acceptance still in progress.

The canonical gateway is `https://cpa.prls.co/v1`. This repository owns one API
origin, one Cloudflare tunnel, and one subscription-backed provider path:

```text
consumers -> utility-llm -> cpa.prls.co -> CLIProxyAPI -> Codex OAuth backend
```

CPA Manager Plus owns operational usage collection. utility-llm remains the
application-level trace and provider-contract owner.

## Decisions

- CPA is the only public API origin managed by this repository.
- `gpt-5.4-mini` is the initial required model.
- The certified CPA baseline is `v7.2.80`, pinned by immutable image digest.
- Codex OAuth is the only provider credential class; paid OpenAI provider
  configuration is forbidden.
- Runtime images are pinned by immutable digest.
- CPA, raw management, and edge listeners bind to loopback on the host.
- The public edge routes `/v1/*` directly to CPA and other paths to CPA Manager
  Plus.
- Strict Responses JSON Schema, native web search, client tools, usage capture,
  restart persistence, backup, and restore are release gates.
- The translator must preserve the complete `text.format` subtree while
  removing backend-rejected transport fields such as `max_output_tokens`.
- Consumer changes happen in consumer repositories and are coordinated through
  GitHub issues rather than cross-repository edits from this checkout.

## Implemented requirements

- Reproducible Compose deployment with immutable CPA, CPA Manager Plus, Caddy,
  and Cloudflare connector images.
- Persisted CPA OAuth/config/log state and CPA Manager Plus database/data key.
- Loopback-only raw service bindings.
- CPA-only public edge rendering.
- Systemd user-service installation and startup scripts.
- Local and public health, authentication, model, schema, web-search, usage,
  redaction, restart, backup, and restore tests.
- Public contract at `https://cpa.prls.co/v1`.

## Work that can complete independently

These gates do not depend on consumer deployment:

1. Strengthen the strict-schema smoke to require the output-text terminal event,
   completed metadata, exact sentinel equality, timing, immutable image digest,
   and a non-secret correlation identifier.
2. Add streaming and non-streaming contract cases.
3. Add explicit invalid-schema, invalid-auth, unsupported-model, rate-limit, and
   upstream-error behavior checks where deterministic injection is possible.
4. Add client-abort coverage proving upstream work and usage mutation stop.
5. Re-run restart, backup/restore, public contract, and boot recovery evidence
   after every image or routing change.

## Consumer-dependent acceptance

These gates must wait until the relevant consumer migration is available, but
they do not block infrastructure cleanup:

1. utility-llm must commit its CPA provider/preset migration and pass its own
   suite. Coordination: https://github.com/prls-co/utility-llm/issues/15
2. query-set must select the CPA provider contract and run hosted `TEST-138`
   against `https://cpa.prls.co/v1`.
3. The original failed re-clustering workload must be replayed through the
   migrated consumer path with pre-repair response capture.
4. The replay must produce a schema-valid first response with no JSON repair or
   semantic repair retry.
5. An outer abort must prevent late completion and late trace mutation in the
   complete consumer-to-provider path.

## Final acceptance

- This repository contains no alternate gateway deployment or routing path.
- CPA remains healthy locally and publicly after restart.
- Strict schema and native web-search contracts pass locally and publicly.
- utility-llm's committed presets select the CPA endpoint and provider identity.
- query-set hosted `TEST-138` passes through CPA.
- The original re-clustering incident succeeds on the first schema-valid result.
- Cancellation prevents late provider work and trace mutation.
- Evidence records commit SHA, immutable image digest, endpoint, timing,
  completed response metadata, and non-secret correlation IDs.
