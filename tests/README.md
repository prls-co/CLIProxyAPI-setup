# Tests

Test files contain a `TEST-###` tag and evaluation files contain an
`EVAL-###` tag. Tests write sanitized evidence under `artifacts/Pxx/` and do
not print credential values. Fish is a test dependency because the static
login contract parses the operator smoke and the public target executes it.

`tests/e2e/public_dashboard.sh` proves that the dashboard page is public while
CPAMP's native API rejects missing and invalid admin keys. `tests/e2e/utility_llm_shaman.js` loads the real
`/home/kirill/p/utility-llm` Shaman profile and requires `gpt-5.6-luna`, strict
JSON Schema, and native web search in one request with a 20-second hard limit.
It also runs contracted `reasoningEffort: "lowest"` calls for CPA Luna and Sol
using utility-llm's existing per-model mapping and mismatch guard. Each call
has the same 20-second hard limit.
The public target also invokes `fish scripts/smoke-claude.fish`, which proves
that `claude-sonnet-5` is served through the persisted Claude subscription and
prints only the expected `claude-ok` sentinel.

`node tests/contract/responses_stream_lifecycle.cjs` is an opt-in `TEST-016`
diagnostic: it completes one native `max` Astra response and cancels another
immediately after `response.created`, using the existing 20-second probe budget.
It prints only lifecycle metadata and the request-ID suffix from
`X-CPA-TRACE-ID`, not the credential-selection index or response text. Match
`cpaRequestId` against existing origin access logs and persisted CPAMP records;
never consume CPA's pop-based usage queue. HTTP 200 alone is not completion,
and missing CPAMP usage after client cancellation must not be counted as zero
tokens or as an upstream provider failure. The unit target checks this diagnostic
without making model calls. No service restart or configuration change occurs.

`TEST-026` runs in `make test-contract` locally and `make test-public` through
the public gateway. It checks explicit `low` and unsupported `none` both report
CPA-supported `low` for Luna and Astra, with strict schema in streaming and
nonstreaming responses. Public requests must identify the active origin.
The unit target checks negative cases and fragmented SSE. Sanitized reasoning
and consumer acceptance evidence is written under `artifacts/P07/`.
See [reasoning policy](../docs/reasoning-effort.md) for configuration ownership
and the dated per-model capability snapshot.

`TEST-027` exercises the real Claude login wrapper in an isolated workspace
with a mocked Docker command and an interactive terminal. It rejects expired,
unchanged, disabled, malformed, and incomplete credentials, including a CLI
timeout that returns zero. It accepts newly refreshed OAuth state with UTC or
an explicit timezone offset. No real credential or model call is used.
