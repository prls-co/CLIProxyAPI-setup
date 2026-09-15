# Trusted recovery hints and cancellation lifecycle evidence

Owner: [#4](https://github.com/prls-co/CLIProxyAPI-setup/issues/4).
Upstream: [#5842](https://github.com/router-for-me/CLIProxyAPI/issues/5842).
Client correction: [utility-llm #38](https://github.com/prls-co/utility-llm/issues/38).

Status: source patch implemented and tested, **not deployed**. Replacing the
shared upstream CPA image with a maintained pinned patched image is awaiting
the user's deployment choice. `compose.yaml`, runtime configuration, credential
state, and CPAMP remain unchanged. This patch is retained evidence, not a second
running provider implementation or an automatic deployment path.

## Source-level correction

The deployed source is v7.2.135,
`856ddd8df746a38a6033dbbf6c140974bf5aea0f`. The tested local patch commit is
`2033572a` on `fix/retry-deadline-propagation`, retained in
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
It does not call `PublishFailure`, add a usage record, or penalize credentials.
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

No shared-service restart, restore, upgrade, or live quota manipulation was
performed. A patched image must follow the existing immutable-image upgrade
and rollback runbook, including a fresh verified backup and post-deploy gates.
