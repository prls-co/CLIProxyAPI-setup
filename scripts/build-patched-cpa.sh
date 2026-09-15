#!/usr/bin/env bash
set -euo pipefail
umask 077

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
mode="${1:---load}"
[[ "$mode" == --load || "$mode" == --push ]] || { printf 'usage: build-patched-cpa.sh [--load|--push] [metadata-file]\n' >&2; exit 1; }
metadata="${2:-$root/state/patched-image-build.json}"
[[ ! -e "$metadata" ]] || { printf 'metadata output already exists\n' >&2; exit 1; }
mkdir -p "$(dirname "$metadata")"
inputs=images/cpa/source.json
upstream_commit="$(jq -r .upstreamCommit "$inputs")"
patch_hash="$(jq -r .patchSha256 "$inputs")"
version="$(jq -r .version "$inputs")"
revision="$(git rev-parse HEAD)"
build_date="$(git show -s --format=%cI HEAD)"
[[ "$(sha256sum patches/cpa-recovery-deadlines.patch | cut -d ' ' -f 1)" == "$patch_hash" ]]
# Unrelated local artifacts never enter the context. Build inputs must be committed.
git diff --quiet HEAD -- images/cpa patches/cpa-recovery-deadlines.patch scripts/build-patched-cpa.sh
[[ -z "$(git ls-files --others --exclude-standard images/cpa patches/cpa-recovery-deadlines.patch scripts/build-patched-cpa.sh)" ]]
build_dir="$(mktemp -d)"
trap 'rm -rf -- "$build_dir"' EXIT
git init -q "$build_dir/upstream"
git -C "$build_dir/upstream" fetch -q --depth 1 https://github.com/router-for-me/CLIProxyAPI.git "$upstream_commit"
[[ "$(git -C "$build_dir/upstream" rev-parse FETCH_HEAD)" == "$upstream_commit" ]]
mkdir -p "$build_dir/context/source"
git -C "$build_dir/upstream" archive FETCH_HEAD | tar -x -C "$build_dir/context/source"
git -C "$build_dir/context/source" apply --check "$root/patches/cpa-recovery-deadlines.patch"
git -C "$build_dir/context/source" apply "$root/patches/cpa-recovery-deadlines.patch"
cp images/cpa/Dockerfile "$build_dir/context/Dockerfile"
tag="$(jq -r .imageRepository "$inputs"):$version-$revision"
provenance=false
[[ "$mode" == --push ]] && provenance=mode=max
docker buildx build "$mode" --platform "$(jq -r .platform "$inputs")" \
  --provenance="$provenance" \
  --build-arg "BUILDER_IMAGE=$(jq -r .builderImage "$inputs")" \
  --build-arg "RUNTIME_IMAGE=$(jq -r .runtimeImage "$inputs")" \
  --build-arg "VERSION=$version" --build-arg "COMMIT=$revision" \
  --build-arg "BUILD_DATE=$build_date" --build-arg "UPSTREAM_COMMIT=$upstream_commit" \
  --build-arg "PATCH_SHA256=$patch_hash" \
  --tag "$tag" --metadata-file "$metadata" "$build_dir/context"
printf 'built %s; metadata: %s\n' "$tag" "$metadata"
