# Responses cancellation visibility

Owner tracker: [#3](https://github.com/prls-co/CLIProxyAPI-setup/issues/3).
Upstream correction: [#5819](https://github.com/router-for-me/CLIProxyAPI/issues/5819).

## Verified 2026-09-14

`TEST-016` completed one native `max` `gpt-5.6-luna` request and cancelled a
second after `response.created` on CPA v7.2.135, commit
`856ddd8df746a38a6033dbbf6c140974bf5aea0f`. The normal response reported native
`max`, `response.completed`, and 18 total tokens. Client duration was 1,221 ms;
the matching persisted CPAMP row reported 1,083 ms and `failed: false`.

The cancellation observed `response.created` at 2,204 ms and ended at 2,232 ms.
The matching origin access-log entry existed with HTTP 200 and 2,204 ms, but
there was no persisted CPAMP `usage_events` row for that exact request ID.
Correlation used the request-ID suffix of `X-CPA-TRACE-ID`, not a timestamp
guess or a second reader of CPA's destructive usage queue. The full header's
credential-selection index was neither logged nor published.

This reproduces a cancellation-accounting gap, not a nine-minute provider
stall. The historical stream sequence was not retained; its upstream cause
remains unknown. HTTP 200 means streaming headers were sent, not that a model
completed generation. Missing token usage remains unknown, not zero.

## Source explanation and fix boundary

In the deployed [`codex_executor_stream.go`](https://github.com/router-for-me/CLIProxyAPI/blob/856ddd8df746a38a6033dbbf6c140974bf5aea0f/internal/runtime/executor/codex_executor_stream.go),
`ctx.Done()` while forwarding chunks and `ctx.Err()` after a scanner error
return without `PublishFailure`. The released v7.3.2 source still contains
these exits. Its bootstrap path explicitly says downstream cancellation must
not be recorded as upstream failure or penalize the credential. That separation
is correct; publishing a generic upstream failure is not the recommended fix.

The required upstream improvement is a distinct terminal cancellation outcome
in the existing lifecycle/access-log path, correlated by request ID, without
credential cooldown, fabricated token counts, or duplicate usage accounting.
Changing the HTTP status after streaming headers were committed cannot solve
this. The existing access log and client terminal metadata can be joined for
diagnosis now; CPAMP usage is not a complete request census.

No CPA image, concurrency setting, retry policy, timeout, credential, or
running service was changed. Do not upgrade simply because a newer image
exists: cancellation visibility must be verified on the correction itself.

## Reproduce safely

Run `node tests/contract/responses_stream_lifecycle.cjs` against the existing
local service; it makes two opt-in model calls with a 20-second probe deadline.
`CPA_LOCAL_BASE_URL` may select the same deployment's public edge explicitly.
Read only the exact returned `cpaRequestId` values from existing access logs
and persisted CPAMP exports or its read-only database. The diagnostic prints
metadata only, never prompts, response text, keys, or the full trace header.
`node --test tests/unit/responses_stream_lifecycle.cjs` checks metadata handling,
reasoning downgrade rejection, premature EOF, and explicit cancellation offline.

The setup-level checks `make test-static test-unit test-security` pass. The
restart/restore portions of `make verify` were deliberately not run against
the shared service for this investigation.
