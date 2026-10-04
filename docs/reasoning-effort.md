# Lowest supported reasoning effort

`lowest` means the least reasoning effort supported by the selected model
through the selected provider route. Use `none` when that route supports it;
otherwise use its lowest supported level, such as `minimal` or `low`.
It does not promise zero reasoning tokens.

## Configuration owner

utility-llm owns the per-model application mapping in
[`src/models/model-config.json`](https://github.com/prls-co/utility-llm/blob/main/src/models/model-config.json).
The existing `reasoningEffortMap` is the configuration flag:

```json
"reasoningEffortMap": {
  "lowest": { "reasoning": { "effort": "low" } },
  "middle": { "reasoning": { "effort": "medium" } },
  "highest": { "reasoning": { "effort": "max" } }
}
```

Select it with a contracted utility-llm call:

```js
await utilityLLMCall({
  modelId: "gpt-5.6-luna",
  callType: "contracted",
  reasoningEffort: "lowest",
  userPrompt: "Return the requested object.",
  schema,
});
```

Native calls, including provider-specific web search, use the corresponding
native options from `MODEL_CONFIG[modelId].reasoningEffortMap.lowest`.
Do not combine contracted `reasoningEffort` with native `reasoning` fields.
A model without a mapping needs capability research and an explicit registry
entry before callers can select contracted `lowest`.

## Current CPA capability research

Checked on 2026-10-03 against CPA's upstream
[model catalog](https://github.com/router-for-me/models/blob/ff3a6ab4316d31204c90a891ddc1cbbee14d0358/models.json)
and the active authenticated `/v1/models` list. CPA refreshes this capability
catalog at startup and periodically; these values are a dated snapshot.
The [JSON research evidence](../artifacts/P07/model-capabilities.json) records
the source revision, per-model supported levels and `none` support flags.

| CPA text model | Catalog effort levels | Lowest on CPA | Acceptance coverage |
| --- | --- | --- | --- |
| `gpt-5.6-luna` | `low`, `medium`, `high`, `xhigh`, `max` | `low` | Local/public stream and nonstream; utility contracted lowest |
| `gpt-5.6-sol` | `low`, `medium`, `high`, `xhigh`, `max` | `low` | utility contracted lowest |
| `gpt-6-astra` | `low`, `medium`, `high`, `xhigh`, `max` | `low` | Local/public stream and nonstream; setup readiness at all five levels |
| `gpt-5.6-terra`, `gpt-6-luna`, `gpt-6-sol`, `gpt-6.1-sol` | `low`, `medium`, `high`, `xhigh`, `max` | `low` | Catalog research only |
| `gpt-5.5`, `codex-auto-review` | `low`, `medium`, `high`, `xhigh` | `low` | Catalog research only |

The utility-llm CPA Luna and Sol entries already map `lowest` to `low`.
Its retained CPA `gpt-5.4` and `gpt-5.4-mini` entries are absent from the
current CPA catalog; they are not certified by this release. Astra is this
repository's setup baseline, not an existing utility-llm preset. Image and
Claude models are outside this Codex reasoning-effort policy.

Direct OpenAI and CPA are distinct routes. A value accepted by a direct backend
does not establish support through CPA. Research each route independently when
adding or changing a model, update the owning registry, and verify a completed
response reports the mapped native effort. Keep utility-llm's existing
`reasoning_effort_mismatch` guard: a correctly mapped request should match its
completed response.

## Accepted CPA normalization

CPA `v7.3.8-prls.3` normalizes an unsupported explicit `none` to the lowest
catalog level (`low` for the acceptance models). This satisfies the requirement
in [setup issue #2](https://github.com/prls-co/CLIProxyAPI-setup/issues/2).
Applications should select `lowest`, which sends `low` directly for these
profiles. Omitting reasoning uses a provider default and does not select
`lowest`.

No CPA binary patch or payload override is needed. Keep the maintained image
pin and cancellation patch. Regression expectations live in the tests;
this setup does not introduce a second application model registry.

## Release gates

```bash
make verify
make test-public
make eval
node tests/contract/responses_stream_lifecycle.cjs
```

`TEST-026` checks `low -> low` and accepted `none -> low` for Luna and Astra,
with strict JSON Schema in streamed and nonstreamed local/public requests.
It requires terminal completion metadata and verifies the public origin.
`TEST-015` runs actual contracted `lowest` calls for CPA Luna and Sol, then a
native Luna web-search/schema call using the same registry mapping. Existing
readiness and schema tests also assert the reported reasoning effort.
Unit tests cover fragmented SSE, missing completion, wrong effort/model,
invalid schema, failed requests and wrong origin without making provider calls.

Run all gates before pushing the release or reconciling production. Recheck
public acceptance after reconciliation and retain sanitized evidence under
`artifacts/P07/`. A successful HTTP status or reasoning-token count alone does
not prove that the selected effort was applied.
