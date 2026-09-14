#!/usr/bin/env node
// TEST-016: parser and cancellation contract without a live model.
const assert = require("node:assert/strict");
const test = require("node:test");
const { inspectStream } = require("../contract/responses_stream_lifecycle.cjs");

function response(events) {
  const text = events.map((event) => `data: ${JSON.stringify(event)}\n\n`).join("");
  return new Response(new ReadableStream({ start(controller) {
    for (const character of text) controller.enqueue(new TextEncoder().encode(character));
    controller.close();
  } }), { headers: { "x-cpa-trace-id": "20260914000000-private-auth-index-a1b2c3d4" } });
}

test("TEST-016 terminal status and reasoning come from metadata, without content or auth index", async () => {
  const completed = { type: "response.completed", response: {
    status: "completed", reasoning: { effort: "max" }, usage: { total_tokens: 10 }, output_text: "private reply",
  } };
  const result = await inspectStream(response([completed]), { startedAt: Date.now(), controller: new AbortController() });
  assert.equal(result.cpaRequestId, "a1b2c3d4");
  assert.equal(result.terminalEvent, "response.completed");
  assert.equal(result.totalTokens, 10);
  assert.doesNotMatch(JSON.stringify(result), /private/);
  for (const effort of ["xhigh", undefined]) {
    await assert.rejects(inspectStream(response([{ ...completed, response: { ...completed.response, reasoning: { effort } } }]), {
      startedAt: Date.now(), controller: new AbortController(),
    }));
  }
  await assert.rejects(inspectStream(response([{ type: "response.output_text.delta", delta: "READY" }]), {
    startedAt: Date.now(), controller: new AbortController(),
  }), /without a terminal event/);
});

test("TEST-016 cancellation is explicit, not successful output or fabricated usage", async () => {
  const controller = new AbortController();
  const result = await inspectStream(response([{ type: "response.created", response: { status: "in_progress" } }]), {
    startedAt: Date.now(), controller, cancelAfterCreated: true,
  });
  assert.equal(controller.signal.aborted, true);
  assert.equal(result.cancelledBy, "test-client-after-response.created");
  assert.equal(result.terminalEvent, null);
  assert.equal(result.totalTokens, null);
});
