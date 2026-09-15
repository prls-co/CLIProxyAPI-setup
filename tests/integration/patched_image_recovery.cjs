#!/usr/bin/env node
// TEST-024: opt-in real CPA image against a synthetic loopback upstream only.
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const http = require("node:http");
const { randomUUID } = require("node:crypto");
const { execFileSync } = require("node:child_process");
const { setTimeout: wait } = require("node:timers/promises");

async function main() {
  const [image, out] = process.argv.slice(2);
  assert.match(image || "", /@sha256:[a-f0-9]{64}$/);
  assert.ok(out && !fs.existsSync(out), "fresh output path required");
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "cpa-recovery-fixture-"));
  const name = `cpa-recovery-fixture-${randomUUID()}`;
  const results = { test: "TEST-024", image, startedAt: new Date().toISOString(), upstreamCalls: 0, responses: [] };
  const upstream = http.createServer((req, res) => {
    req.resume();
    results.upstreamCalls += 1;
    res.setHeader("Content-Type", "application/json");
    res.setHeader("X-Synthetic-Private", "must-not-pass-through");
    if (results.upstreamCalls === 1) {
      res.writeHead(503);
      res.end(JSON.stringify({ error: { message: "synthetic upstream unavailable", type: "server_error" } }));
    } else {
      res.end(JSON.stringify({ id: "synthetic", object: "chat.completion", model: "recovery-probe", choices: [{ index: 0, message: { role: "assistant", content: "RECOVERED" }, finish_reason: "stop" }], usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 } }));
    }
  });
  let created = false;
  try {
    await new Promise((resolve) => upstream.listen(0, "127.0.0.1", resolve));
    const portProbe = http.createServer();
    await new Promise((resolve) => portProbe.listen(0, "127.0.0.1", resolve));
    const port = portProbe.address().port;
    await new Promise((resolve) => portProbe.close(resolve));
    fs.writeFileSync(path.join(dir, "config.yaml"), `host: "127.0.0.1"
port: ${port}
auth-dir: "/tmp/auths"
api-keys: ["synthetic-client"]
remote-management:
  disable-control-panel: true
logging-to-file: false
passthrough-headers: false
request-retry: 0
max-retry-interval: 0
transient-error-cooldown-seconds: 3
openai-compatibility:
  - name: "recovery-probe"
    base-url: "http://127.0.0.1:${upstream.address().port}/v1"
    api-key-entries:
      - api-key: "synthetic-upstream"
    models:
      - name: "recovery-probe"
        alias: "recovery-probe"
`, { mode: 0o600 });
    execFileSync("docker", ["run", "-d", "--name", name, "--user", `${process.getuid()}:${process.getgid()}`, "--network", "host", "--read-only", "--tmpfs", "/tmp", "--cap-drop", "ALL", "--security-opt", "no-new-privileges:true", "-v", `${dir}/config.yaml:/CLIProxyAPI/config.yaml:ro`, image, "./CLIProxyAPI", "-config", "/CLIProxyAPI/config.yaml", "--local-model"], { stdio: "pipe" });
    created = true;
    const base = `http://127.0.0.1:${port}`;
    let healthy = false;
    for (let index = 0; index < 80; index += 1) {
      try { healthy = (await fetch(`${base}/healthz`, { signal: AbortSignal.timeout(1000) })).ok; } catch {}
      if (healthy) break;
      await wait(250);
    }
    assert.ok(healthy, "isolated image must start");
    const request = async () => {
      const response = await fetch(`${base}/v1/chat/completions`, {
        method: "POST", signal: AbortSignal.timeout(10000),
        headers: { Authorization: "Bearer synthetic-client", "Content-Type": "application/json" },
        body: JSON.stringify({ model: "recovery-probe", messages: [{ role: "user", content: "synthetic" }] }),
      });
      const record = { status: response.status, retryAfter: response.headers.get("retry-after"), body: await response.json() };
      results.responses.push(record);
      assert.equal(response.headers.get("x-synthetic-private"), null);
      return record;
    };
    assert.equal((await request()).status, 503);
    const blocked = await request();
    assert.equal(blocked.status, 503);
    assert.match(blocked.body.error.message, /auth_unavailable/);
    assert.ok(Number(blocked.retryAfter) > 0 && Number(blocked.retryAfter) <= 3, "temporary recovery must retain Retry-After with passthrough disabled");
    assert.equal(results.upstreamCalls, 1, "blocked selection must not call upstream");
    await wait(Number(blocked.retryAfter) * 1000 + 50);
    const recovered = await request();
    assert.equal(recovered.status, 200);
    assert.equal(recovered.body.choices[0].message.content, "RECOVERED");
    assert.equal(results.upstreamCalls, 2);
    results.status = "pass";
  } catch (error) {
    results.status = "fail";
    results.error = error instanceof assert.AssertionError ? error.message : error.name;
    process.exitCode = 1;
  } finally {
    if (created) {
      results.containerLog = execFileSync("docker", ["logs", name], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
      execFileSync("docker", ["rm", "-f", name], { stdio: "ignore" });
    }
    await new Promise((resolve) => upstream.close(resolve));
    fs.rmSync(dir, { recursive: true });
    fs.writeFileSync(out, `${JSON.stringify(results, null, 2)}\n`, { flag: "wx", mode: 0o600 });
    console.log(JSON.stringify({ test: results.test, status: results.status, upstreamCalls: results.upstreamCalls, error: results.error }));
  }
}

main().catch((error) => { console.error(error.name); process.exitCode = 1; });
