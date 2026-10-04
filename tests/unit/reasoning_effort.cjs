#!/usr/bin/env node
// TEST-026: terminal metadata and strict-schema reasoning assertions, without provider calls.
"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");
const { inspectResponse } = require("../contract/reasoning_effort.cjs");

function completed(overrides = {}) {
  return {
    status: "completed", model: "gpt-5.6-luna", error: null,
    reasoning: { effort: "low" }, text: { format: { type: "json_schema", strict: true } },
    output: [{ type: "message", content: [{ type: "output_text", text: '{"sentinel":"STRUCTURED_OUTPUT_ENFORCED"}' }] }],
    ...overrides,
  };
}

function streamed(events, trailingNewline = true) {
  const text = events.map((event) => `data: ${JSON.stringify(event)}`).join("\r\n\r\n") + (trailingNewline ? "\r\n\r\n" : "");
  return new Response(new ReadableStream({ start(controller) {
    // Exercise fragmented SSE data, including split line endings.
    for (const character of text) controller.enqueue(new TextEncoder().encode(character));
    controller.close();
  } }), { headers: { "x-cpa-origin-hostname": "test-origin" } });
}

function options(overrides = {}) {
  return { model: "gpt-5.6-luna", requestedEffort: "none", stream: true, startedAt: Date.now(), ...overrides };
}

test("TEST-026 accepts none->low from terminal metadata in fragmented streams and nonstream responses", async () => {
  for (const trailingNewline of [true, false]) {
    const response = streamed([
      { type: "response.created", response: { reasoning: { effort: "none" } } },
      { type: "response.output_text.delta", delta: "private text" },
      { type: "response.completed", response: completed() },
    ], trailingNewline);
    const result = await inspectResponse(response, options({ expectedOrigin: "test-origin" }));
    assert.equal(result.requestedEffort, "none");
    assert.equal(result.effectiveEffort, "low");
    assert.equal(result.originVerified, true);
    assert.doesNotMatch(JSON.stringify(result), /private|sentinel|authorization/i);
  }
  const result = await inspectResponse(new Response(JSON.stringify(completed())), options({ stream: false, requestedEffort: "low" }));
  assert.equal(result.effectiveEffort, "low");
});

test("TEST-026 rejects missing completion, failed streams and HTTP errors", async () => {
  await assert.rejects(inspectResponse(streamed([{ type: "response.created", response: completed() }]), options()), /terminal/);
  for (const type of ["response.failed", "response.incomplete", "error"]) {
    await assert.rejects(inspectResponse(streamed([{ type }]), options()), /complete successfully/);
  }
  await assert.rejects(inspectResponse(new Response("private error body", { status: 400 }), options()), /HTTP 200/);
});

test("TEST-026 rejects incorrect effort, missing effort, wrong model, invalid schema and wrong origin", async () => {
  for (const overrides of [
    { reasoning: { effort: "none" } }, { reasoning: { effort: "medium" } }, { reasoning: {} },
    { model: "other-model" }, { status: "incomplete" }, { error: { message: "failure" } },
    { text: { format: { type: "json_object", strict: true } } },
    { text: { format: { type: "json_schema", strict: false } } },
    { output: [{ type: "message", content: [{ type: "output_text", text: '{"sentinel":"WRONG"}' }] }] },
  ]) {
    await assert.rejects(inspectResponse(new Response(JSON.stringify(completed(overrides))), options({ stream: false })));
  }
  await assert.rejects(inspectResponse(streamed([{ type: "response.completed", response: completed() }]), options({ expectedOrigin: "other-origin" })), /active origin/);
});
