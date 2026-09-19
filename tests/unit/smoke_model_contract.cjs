// TEST-025: smoke fixtures use the selected catalog model and preserve MODEL overrides.
"use strict";
const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const root = path.join(__dirname, "../..");

test("TEST-025 Responses fixtures request Astra low; TEST-016 separately certifies max", () => {
  const dir = path.join(root, "tests/fixtures/responses");
  for (const file of fs.readdirSync(dir).filter((name) => name.endsWith(".json"))) {
    const fixture = JSON.parse(fs.readFileSync(path.join(dir, file), "utf8"));
    assert.equal(fixture.model, "gpt-6-astra", file);
    assert.deepEqual(fixture.reasoning, { effort: "low" }, file);
  }
  const readiness = fs.readFileSync(path.join(root, "tests/integration/cpa_auth_models.sh"), "utf8");
  assert.match(readiness, /jq --arg model "\$MODEL" '\.model = \$model'/);
  assert.match(readiness, /--data-binary @"\$request"/);
  const contract = fs.readFileSync(path.join(root, "tests/contract/responses_contract.sh"), "utf8");
  assert.match(contract, /"\$ARTIFACT_DIR\/\$name\.json"/);
});
