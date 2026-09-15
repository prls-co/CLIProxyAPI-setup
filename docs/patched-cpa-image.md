# Maintained pinned CPA image

Owner: [#4](https://github.com/prls-co/CLIProxyAPI-setup/issues/4), with
cancellation lifecycle evidence tracked in [#3](https://github.com/prls-co/CLIProxyAPI-setup/issues/3).
The user approved deploying a maintained pinned patched image on 2026-09-15.

`images/cpa/source.json` pins the upstream commit, patch hash, Go builder,
runtime image and platform. `scripts/build-patched-cpa.sh` archives only that
upstream revision into a fresh context and applies the verified patch. It never
loads `.env` or copies this checkout's credentials, state, artifacts or logs.
The runtime layer is the previous deployed CPA image, with only the rebuilt
binary and upstream license added. Go dependencies remain pinned by upstream
`go.mod` / `go.sum`; no apt packages are refreshed.

Run `Publish pinned patched CPA` manually on the desired committed revision.
The workflow runs the patch's Go regression gates inside the builder, publishes
`ghcr.io/prls-co/cli-proxy-api-patched:<version>-<setup-commit>`, and retains
`patched-image-build.json` and BuildKit provenance. It uses the workflow's
short-lived `GITHUB_TOKEN`, not a new stored provider/deployment secret.
See [GitHub's GHCR publication contract](https://docs.github.com/en/actions/tutorials/publish-packages/publish-docker-images)
and [Docker provenance guidance](https://docs.docker.com/build/ci/github-actions/attestations/).
Local compilation/testing is `bash scripts/build-patched-cpa.sh --load`;
local Docker loading does not retain provenance attestations.

Do not deploy a mutable tag. Pull the published digest, inspect its source,
version and patch labels, and record its binary SHA-256. Take a fresh backup
using `scripts/backup.sh` and verify it with `scripts/restore-test.sh`. Keep the
previous immutable image locally. Change both CPA uses in `compose.yaml` and
`tests/static/test_compose_contract.sh` together, then follow the existing
[upgrade gates](operations.md). The backup/restore helper
images can remain on the original digest: those only execute shell tools.

Rollback changes only the CPA image pin back to the previous recorded digest
and recreates `cli-proxy-api`; it must not restore old OAuth or CPAMP database
state over newly collected state. Use a state restore only for an independently
verified state-corruption incident. Do not prune either image during the gate.

Full upstream tests have existing reproduced failures described in
[recovery-deadlines.md](recovery-deadlines.md). Focused regression/build success
is not an all-green upstream suite claim. Require the local, public, collection,
backup/recovery and complete hosted clustering gates after image promotion.

## First image and pre-deployment gate (superseded)

- Build source: `c77a5d0486bfcb9ab5f2d7404156526b56db6347`.
- [Publish workflow](https://github.com/prls-co/CLIProxyAPI-setup/actions/runs/34995869919): passed, including all focused Go tests and compilation.
- Index digest: `sha256:1c7851e4c0952ccadb123bb4981dc4d703d1f4c820195cbb895d85b836e436f2`.
- Linux/amd64 manifest: `sha256:defb725cb81adda85f4ae221fec9bf791dfa0c51205c7203c52ea9e4f5bec9bc`.
- GHCR package is private, linked to this repository; existing host registry
  authentication successfully pulled the exact digest. Fresh hosts require
  package read access. No registry credentials were added to the source/build.

`TEST-024` runs the real image against a synthetic loopback upstream, with a
test-only three-second cooldown and `passthrough-headers: false`. The old image
fails because `auth_unavailable` omits `Retry-After`; the patched digest returns
the remaining hint, makes no upstream request while blocked, and completes
after that hint. Exactly two upstream calls occur (injected 503, then 200).
Production cooldown configuration and OAuth state are not used or changed.
An initial fixture startup error was a test-container UID/0600 mount mismatch;
running the unprivileged fixture as its file owner corrected the harness.

Run it explicitly with:

```bash
node tests/integration/patched_image_recovery.cjs IMAGE_AT_DIGEST FRESH_PRIVATE_JSON
```

The pre-deployment backup passed all six file hash/mode/ownership checks.
Hosted and shared-runtime post-deployment results are recorded separately.

## First image verification found two additional boundaries

The first image was healthy and served a completed Luna native `max` stream.
Public cancellation request `e3b3641e` reached its cancellation log, but
`LogFormatter.Format` at `internal/logging/global_logger.go:91` filters fields
outside `logFieldOrder`. Consequently hook assertions passed while persisted
text omitted `event`, `outcome`, and `provider_usage_known`. The `prls.2` patch
keeps the same structured fields and includes their non-secret constant values
in the cancellation message. The test now formats the captured entry through
the actual `LogFormatter`; it fails on `prls.1` and passes on the correction.
No global formatter policy, usage publication, or credential state changes.

The first `make verify` stopped at `TEST-005`: its default `gpt-5.4-mini` is
absent from both the live catalog and the remote catalog loaded by
`StartModelsUpdater`. The embedded source snapshot still lists it. The patch
does not change registry behavior; the test assumed a mutable upstream catalog
would keep the older model. Smoke fixtures/defaults now use the user-selected
`gpt-5.6-luna`, at explicit native `low` per setup routing policy. `TEST-016`
and all hosted clustering calls continue testing native `max` separately.
`TEST-005` also now applies its existing `MODEL` selection to the outgoing
request, rather than only checking the catalog and sending the old fixture.
`TEST-025` checks these boundaries. Existing time limits are unchanged.
The operator `.env` also retained `MODEL=gpt-5.4-mini`, overriding corrected
defaults via `load_env`; its non-secret model selection was aligned to Luna.
Provider keys and rendered CPA runtime policy remain unchanged.

## Deployed correction: `v7.2.135-prls.2`

- Build source: `0f0b42d137ead26fd1e2fb2632117f23e7645545`.
- [Publish workflow](https://github.com/prls-co/CLIProxyAPI-setup/actions/runs/34996922032): passed, including focused Go tests, compilation and provenance publication.
- Index digest: `sha256:4c6edfdbeff8baa252fb1295a14a99d1d4e434051a407e326ded47e6cce83c39`.
- Linux/amd64 manifest: `sha256:ec5d8f65e2686aa5c71754f1d8cf955a1f4bf1852497e5f423cb3794b4316383`.
- Running binary SHA-256: `92c7976a11e88216145d132c4673917e5b48f03a3c77426780931c238c843953`.
- Applied patch SHA-256: `3a86cc53679b243bdc5465d3082912e64b8af32f0b063702a9df86d8e39abdb1`.
- Compose promotion: `e4ade74182d19e2b2e678cc5ac06a0cfff99c5f4`.

The registry digest, source/version/patch labels, deployed image and running
binary were read back. Both patched images and the original upstream digest
remain available for rollback; the original runtime is still the build base.
The new six-file backup again passed all hash/mode/ownership checks before
promotion. `TEST-024` passed against this exact digest too.

Final `make verify`, `make test-public`, Compose reproducibility, and
`tests/eval/recovery_rehearsal.sh` passed. These cover strict schemas in streaming
and non-streaming Responses, web search, filtering, utility-llm, Claude, public
authentication, CPAMP persistence/collection and backup/restart recovery.
Recovery measured 13.284 seconds against the existing 180-second gate. The
public connector remained unchanged; no live state restore was needed.

The public `TEST-016` probe completed at native `max` in 1.958 seconds, with a
matching successful CPAMP record. A second request cancelled after
`response.created` in 809 ms. Exact request correlation found one persisted
`event=codex.stream.cancelled outcome=cancelled provider_usage_known=false`
entry and no CPAMP usage record, as intended. This is unknown usage, not zero.
Raw probe/log/database read-back evidence remains private.

The normal rendered CPA configuration hash remained unchanged throughout.
Only non-secret operator `MODEL` and `CPA_VERSION` selections were aligned to
the chosen model/image. No new key, Secret Manager resource, credential mirror,
provider fallback, concurrency limit, retry count or timeout was introduced.
Complete concurrent hosted clustering verification follows these service gates.
