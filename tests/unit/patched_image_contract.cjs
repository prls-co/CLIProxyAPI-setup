// TEST-023: reproducible patched image inputs without credentials or runtime state.
"use strict";
const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { createHash } = require("node:crypto");
const root = path.join(__dirname, "../..");
const read = (name) => fs.readFileSync(path.join(root, name), "utf8");

test("TEST-023 pinned patch hash, source, builder and runtime", () => {
  const source = JSON.parse(read("images/cpa/source.json"));
  assert.match(source.upstreamCommit, /^[a-f0-9]{40}$/);
  for (const key of ["builderImage", "runtimeImage"]) {
    assert.match(source[key], /@sha256:[a-f0-9]{64}$/);
  }
  assert.equal(source.patchSha256, createHash("sha256").update(read("patches/cpa-recovery-deadlines.patch")).digest("hex"));
  assert.equal(source.platform, "linux/amd64");
  assert.match(source.imageRepository, /^ghcr\.io\/prls-co\//);
});

test("TEST-023 build ships only upstream archive plus verified patch", () => {
  const script = read("scripts/build-patched-cpa.sh");
  const dockerfile = read("images/cpa/Dockerfile");
  assert.match(script, /archive FETCH_HEAD/);
  assert.match(script, /apply --check/);
  assert.match(script, /git diff --quiet HEAD/);
  assert.match(dockerfile, /go test \.\/sdk\/cliproxy\/auth/);
  assert.match(dockerfile, /TestCodexStreamCancellation/);
  assert.match(dockerfile, /COPY --from=builder \/CLIProxyAPI \/CLIProxyAPI\/CLIProxyAPI/);
  assert.doesNotMatch(dockerfile, /COPY \.|apt-get|\.env|state\//);
  assert.doesNotMatch(script, /source .*\.env|docker compose/);
});
