#!/usr/bin/env node
// TEST-026: lowest supported CPA reasoning, including accepted none-to-low normalization.
"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { parseEnv } = require("node:util");

const root = path.resolve(__dirname, "../..");
// Regression expectations for the two acceptance models, not a runtime model registry.
const models = Object.freeze(["gpt-5.6-luna", "gpt-6-astra"]);

async function inspectResponse(response, { model, requestedEffort, stream, startedAt, expectedOrigin }) {
  assert.equal(response.status, 200, "reasoning request must return HTTP 200");
  if (expectedOrigin) {
    assert.equal(response.headers.get("x-cpa-origin-hostname"), expectedOrigin, "public request must reach the active origin");
  }
  let completed;
  if (stream) {
    let pending = "";
    const decoder = new TextDecoder();
    function consume(line) {
      if (!line.startsWith("data:")) return;
      const data = line.slice(5).trim();
      if (!data || data === "[DONE]") return;
      const event = JSON.parse(data);
      assert.ok(!["response.failed", "response.incomplete", "error"].includes(event.type), "stream must complete successfully");
      if (event.type === "response.completed") completed = event.response;
    }
    for await (const chunk of response.body) {
      pending += decoder.decode(chunk, { stream: true });
      let end;
      while ((end = pending.indexOf("\n")) !== -1) {
        consume(pending.slice(0, end).trim());
        pending = pending.slice(end + 1);
      }
    }
    pending += decoder.decode();
    consume(pending.trim());
  } else {
    completed = await response.json();
  }
  assert.ok(completed, "terminal response.completed metadata is required");
  assert.equal(completed.status, "completed");
  assert.equal(completed.error ?? null, null);
  assert.equal(completed.model, model, "response must use the requested model");
  assert.equal(completed.reasoning?.effort, "low", "both explicit low and unsupported none must resolve to CPA's lowest supported low");
  assert.equal(completed.text?.format?.type, "json_schema");
  assert.equal(completed.text?.format?.strict, true);
  const text = (completed.output || []).filter((item) => item.type === "message")
    .flatMap((item) => item.content || []).filter((item) => item.type === "output_text")
    .map((item) => item.text).join("");
  assert.deepEqual(JSON.parse(text), { sentinel: "STRUCTURED_OUTPUT_ENFORCED" });
  // Persist only contract metadata. Do not retain response bodies, headers, IDs or credentials.
  return {
    model, stream, requestedEffort, effectiveEffort: completed.reasoning.effort,
    status: completed.status, strictSchema: true, originVerified: Boolean(expectedOrigin),
    durationMs: Date.now() - startedAt,
  };
}

async function main() {
  assert.ok(process.argv.slice(2).every((arg) => arg === "--public"), "only --public is supported");
  const publicRoute = process.argv.includes("--public");
  const env = parseEnv(fs.readFileSync(path.join(root, ".env"), "utf8"));
  assert.ok(env.CPA_API_KEY, "CPA_API_KEY is required in .env");
  const baseUrl = publicRoute
    ? (process.env.PUBLIC_BASE_URL || env.PUBLIC_BASE_URL || "https://cpa.prls.co/v1")
    : `${(process.env.CPA_LOCAL_BASE_URL || env.CPA_LOCAL_BASE_URL || "http://127.0.0.1:8317").replace(/\/$/, "")}/v1`;
  let expectedOrigin;
  if (publicRoute) {
    expectedOrigin = fs.readFileSync(path.join(root, "state/cpamp-public/Caddyfile"), "utf8")
      .match(/header_down\s+X-CPA-Origin-Hostname\s+"?([^"\s]+)/)?.[1];
    assert.ok(expectedOrigin, "generated edge config must identify the active origin");
  }
  const fixture = JSON.parse(fs.readFileSync(path.join(root, "tests/fixtures/responses/strict-schema.json"), "utf8"));
  const results = [];
  for (const model of models) {
    for (const requestedEffort of ["low", "none"]) {
      for (const stream of [true, false]) {
        const startedAt = Date.now();
        const response = await fetch(`${baseUrl.replace(/\/$/, "")}/responses`, {
          method: "POST",
          headers: {
            Authorization: `Bearer ${env.CPA_API_KEY}`, "Content-Type": "application/json",
            "User-Agent": "curl/8.5.0",
          },
          signal: AbortSignal.timeout(20000),
          body: JSON.stringify({ ...fixture, model, stream, reasoning: { effort: requestedEffort } }),
        });
        results.push(await inspectResponse(response, { model, requestedEffort, stream, startedAt, expectedOrigin }));
        process.stdout.write(`TEST-026 ${publicRoute ? "public" : "local"} ${model} ${stream ? "stream" : "nonstream"} ${requestedEffort}->low: pass\n`);
      }
    }
  }
  const directory = process.env.CPA_REASONING_ARTIFACT_DIR || path.join(root, "artifacts/P07/TEST-026");
  fs.mkdirSync(directory, { recursive: true });
  fs.writeFileSync(path.join(directory, `${publicRoute ? "public" : "local"}.json`), `${JSON.stringify({
    test: "TEST-026", status: "pass", checkedAt: new Date().toISOString(),
    route: publicRoute ? "public" : "local", results,
  }, null, 2)}\n`);
}

if (require.main === module) {
  main().catch((error) => {
    // Fetch/parser errors can contain bodies or credentials; retain only the error class.
    process.stderr.write(`TEST-026 failed: ${error.name}\n`);
    process.exitCode = 1;
  });
}

module.exports = { inspectResponse, models };
