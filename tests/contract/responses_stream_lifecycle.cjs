#!/usr/bin/env node
// TEST-016: opt-in stream lifecycle diagnostic; no usage-queue consumption.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { parseEnv } = require("node:util");

async function inspectStream(response, { startedAt, controller, cancelAfterCreated = false }) {
  const traceId = response.headers.get("x-cpa-trace-id") || "";
  const summary = {
    startedAt: new Date(startedAt).toISOString(), httpStatus: response.status,
    // The full trace header includes an auth index. Keep only CPA's request ID.
    cpaRequestId: traceId.match(/-([a-f0-9]{8})$/i)?.[1] || null,
    headersMs: Date.now() - startedAt, firstEventMs: null, lastEventMs: null,
    eventCount: 0, terminalEvent: null, responseStatus: null,
    requestedReasoningEffort: "max", effectiveReasoningEffort: null,
    cancelledBy: null, totalTokens: null,
  };
  assert.equal(response.status, 200, "CPA must accept the Responses request");
  let pending = "";
  const decoder = new TextDecoder();
  try {
    for await (const chunk of response.body) {
      pending += decoder.decode(chunk, { stream: true });
      let end;
      while ((end = pending.indexOf("\n")) !== -1) {
        const line = pending.slice(0, end).trim();
        pending = pending.slice(end + 1);
        if (!line.startsWith("data:")) continue;
        const data = line.slice(5).trim();
        if (!data || data === "[DONE]") continue;
        const event = JSON.parse(data);
        summary.eventCount += 1;
        summary.firstEventMs ??= Date.now() - startedAt;
        summary.lastEventMs = Date.now() - startedAt;
        summary.responseStatus = event.response?.status ?? summary.responseStatus;
        summary.effectiveReasoningEffort = event.response?.reasoning?.effort ?? summary.effectiveReasoningEffort;
        if (cancelAfterCreated && event.type === "response.created") {
          summary.cancelledBy = "test-client-after-response.created";
          controller.abort();
          return summary;
        }
        if (["response.completed", "response.incomplete", "response.failed", "error"].includes(event.type)) {
          summary.terminalEvent = event.type;
          summary.totalTokens = event.response?.usage?.total_tokens ?? null;
          assert.equal(event.type, "response.completed", "normal probe requires response.completed");
          assert.equal(summary.responseStatus, "completed");
          assert.equal(summary.effectiveReasoningEffort, "max", "CPA must not rewrite native max");
          return summary;
        }
      }
    }
    assert.fail("Responses stream ended without a terminal event");
  } catch (error) {
    if (controller.signal.aborted && summary.cancelledBy) return summary;
    error.streamLifecycle = summary;
    throw error;
  } finally {
    summary.durationMs = Date.now() - startedAt;
  }
}

async function main() {
  const env = parseEnv(fs.readFileSync(path.resolve(__dirname, "../../.env"), "utf8"));
  assert.ok(env.CPA_API_KEY, "CPA_API_KEY is required in .env");
  const baseUrl = process.env.CPA_LOCAL_BASE_URL || env.CPA_LOCAL_BASE_URL || "http://127.0.0.1:8317";
  const results = [];
  for (const cancelAfterCreated of [false, true]) {
    const controller = new AbortController();
    const startedAt = Date.now();
    const response = await fetch(`${baseUrl.replace(/\/$/, "")}/v1/responses`, {
      method: "POST",
      headers: { Authorization: `Bearer ${env.CPA_API_KEY}`, "Content-Type": "application/json" },
      signal: AbortSignal.any([controller.signal, AbortSignal.timeout(20000)]),
      body: JSON.stringify({
        model: "gpt-5.6-luna", stream: true, reasoning: { effort: "max" },
        input: "Reply with the single word READY.",
      }),
    });
    results.push(await inspectStream(response, { startedAt, controller, cancelAfterCreated }));
  }
  process.stdout.write(`${JSON.stringify({ test: "TEST-016", results }, null, 2)}\n`);
}

if (require.main === module) {
  main().catch((error) => {
    // Do not serialize SDK/fetch errors or headers containing credentials.
    if (error.streamLifecycle) process.stderr.write(`${JSON.stringify(error.streamLifecycle)}\n`);
    process.stderr.write(`TEST-016 failed: ${error instanceof assert.AssertionError ? error.message : error.name}\n`);
    process.exitCode = 1;
  });
}

module.exports = { inspectStream };
