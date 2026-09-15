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
[upgrade gates](operations.md#incident-response). The backup/restore helper
images can remain on the original digest: those only execute shell tools.

Rollback changes only the CPA image pin back to the previous recorded digest
and recreates `cli-proxy-api`; it must not restore old OAuth or CPAMP database
state over newly collected state. Use a state restore only for an independently
verified state-corruption incident. Do not prune either image during the gate.

Full upstream tests have existing reproduced failures described in
[recovery-deadlines.md](recovery-deadlines.md). Focused regression/build success
is not an all-green upstream suite claim. Require the local, public, collection,
backup/recovery and complete hosted clustering gates after image promotion.
