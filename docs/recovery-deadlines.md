# Trusted recovery hints and cancellation lifecycle evidence

Owner: [#4](https://github.com/prls-co/CLIProxyAPI-setup/issues/4).
Upstream: [#5842](https://github.com/router-for-me/CLIProxyAPI/issues/5842).
Client correction: [utility-llm #38](https://github.com/prls-co/utility-llm/issues/38).

Status: the user-approved maintained image `v7.2.135-prls.2` is deployed by
immutable digest. See [build, deployment and rollback evidence](patched-cpa-image.md).
The CPA runtime configuration hash is unchanged; no credentials, retry policy,
concurrency control, or CPAMP image was changed. The source patch below is the
single deployed implementation, built by the explicit publication workflow.

## Source-level correction

The upstream base is v7.2.135,
`856ddd8df746a38a6033dbbf6c140974bf5aea0f`. The tested local patch commit is
`a57201f4` on `fix/retry-deadline-propagation`, retained in
`patches/cpa-recovery-deadlines.patch`. Apply only against the specified source
revision; do not apply it blindly to a different upstream release.

`collectAvailableByPriority`,
`availableAuthsForRouteModelWithPriorityMode`, and
`availabilitySummaryLocked` previously retained only quota cooldown deadlines.
Temporary `blockReasonOther` / `scheduledStateBlocked` recovery state was lost,
yielding `auth_unavailable` without `Retry-After`. The patch retains the earliest
future recovery deadline while preserving the distinction from disabled
credentials and quota cooldowns.

`newAuthUnavailableError` carries a trusted recovery hint without changing the
public four-field `Error` layout. An initial version adding a field broke the
existing downstream unkeyed-literal test; that approach was removed.
`enrichAuthSelectionError` preserves the hint when adding provider/model context,
including through wrapped errors. `SafeResponseHeaders` allows only local
`HomeConcurrencyBusyError`, `modelCooldownError`, and `authUnavailableError`
recovery hints. It does not enable arbitrary upstream header passthrough.

This matters because `recoverableFailureRetryAfter` defaults to one minute,
whereas the deployed `max-retry-interval` is 30 seconds. When CPA cannot wait
internally, the client needs the remaining recovery minimum. The utility fix
honors that minimum plus jitter; it cannot recover hints that CPA omits.

For cancellation, `CodexExecutor.ExecuteStream` writes one existing-log lifecycle
event, `codex.stream.cancelled`, with `outcome: "cancelled"` and
`provider_usage_known: false`, correlated using `helps.LogWithRequestID`.
The same non-secret constants appear in the log message because `LogFormatter`
filters arbitrary structured fields; the regression test verifies the actual
formatted output as well as the hook entry. It does not call `PublishFailure`,
add a usage record, or penalize credentials.
Upstream [#5819](https://github.com/router-for-me/CLIProxyAPI/issues/5819) was
closed as not planned: cancellation exclusion from usage is intentional.
The required evidence is therefore a lifecycle log, not fabricated CPAMP usage.

## Verification

Passed on the patch:

- `go test ./sdk/cliproxy/auth ./sdk/api/handlers ./sdk/api/handlers/openai`
- `go test -run 'TestCodexStreamCancellation|TestCodexExecutorExecuteStream' ./internal/runtime/executor`
- `go test -count=3 -run '^TestGetPluginSyncCancellationInterruptsRead$' ./internal/home`
- `go build -o <private temporary output> ./cmd/server`

New tests verify temporary 503 and quota 429 hints through default header policy,
disabled-credential exclusion, scheduler classification, wrapped-error context,
and actual HTTP stream cancellation with exactly one lifecycle event and no
provider failure. The public `Error` layout compatibility test passes.

`go test ./...` is not all green. The untouched deployed source reproduces
`TestPionMediaRelayBridgesAudioAndDataChannel` (upstream DataChannel missing),
three existing Claude fingerprint tests (`MacOS` versus expected `Linux`), and
`TestGetPluginSyncCancellationInterruptsRead` (120-second delay when run with
the full Home package). The isolated Home cancellation test passes on the patch
three times; the failure depends on the existing full-package test context.
Those failures are outside this patch and have not been disguised as successes.
Private full/baseline logs are retained in the two temporary source worktrees.

Setup `make test-static test-unit test-security` passed. The retained patch
passes `git apply --check` against the untouched deployed source revision.
The security gate regenerated configuration from the unchanged canonical `.env`
and verified rejected invalid credentials; no model inference or service restart
was needed for that check. The refreshed `TEST-008` artifact contains hashes and
status codes only.

The approved image followed the immutable-image upgrade and rollback runbook:
fresh verified backup, isolated image recovery test, local/public contracts,
collection, and recovery rehearsal. No live quota manipulation or production
state restore was performed. The synthetic recovery fixture uses an isolated
container and loopback upstream, never real credentials.

## Fresh hosted recurrence after the client release

Clustering deployed published utility `0.15.6` and completed all three 18-request
100-item waves: 18/18, 18/18, and 17/18. The failed request was
`dadc6e64-d722-443a-98b5-6e20efe55ba4`, call
`939ac666-8b2d-4ae2-a178-0c9abfd32392`, in an 11-item initial batch.
Its first attempt received an overload SSE failure; the following three
attempts returned HTTP 503 `auth_unavailable`, each without `Retry-After`.
Saved utility waits were 317, 915, and 1,030 ms, followed by `attempt_limit`.
The operation failed after 24.490 seconds, not at the 540-second host deadline.

Exact `cpaRequestId: 261adbad` joins the first attempt to origin HTTP 200 /
1.61 seconds and a persisted CPAMP failed row at
`2026-09-15T07:01:22.757498121Z`, native `max`, upstream status 502, latency
1,608 ms. HTTP 200 identifies committed streaming headers, not completion.
The subsequent three attempts have no retained CPA request ID or historical
credential eligibility snapshot; their exact recovery deadline is unknown.
The one-minute default is source evidence, not a reconstructed deadline.

That client already had jitter and one client retry owner, but could not honor
an omitted recovery hint. This fresh recurrence keeps #4 and the all-green
hosted gate open. No successful-only rerun replaced the failure. The source
patch is now deployed; the complete post-deployment campaign is recorded in
the linked deployment evidence, not replaced with a successful-only rerun,
a longer timeout, or a consumer rate limiter.
