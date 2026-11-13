#!/usr/bin/env node
// Opt-in live capability probe. Never included in the default test gates.
"use strict";
const fs = require("node:fs");
const path = require("node:path");
const { parseEnv } = require("node:util");

async function main() {
  if (!process.argv[2]) throw new Error("output path required");
  const root = path.resolve(__dirname, "..");
  const env = parseEnv(fs.readFileSync(`${root}/.env`, "utf8"));
  const base = process.env.CPA_PROBE_BASE || "https://cpa.prls.co/v1";
  const model = "gpt-5.6-luna";
  const cases = [
    { name: "sources-and-citations", include: ["web_search_call.action.sources"], input: "Search the web for the official OpenAI Responses API documentation. Briefly describe it and cite the source." },
    { name: "structured-sources", include: ["web_search_call.action.sources"], input: "Search the web for the official OpenAI Responses API documentation. Return its official URL and a short description.", text: { format: { type: "json_schema", name: "official_source", strict: true, schema: { type: "object", additionalProperties: false, properties: { url: { type: "string" }, description: { type: "string" } }, required: ["url", "description"] } } } },
    { name: "image-results", include: ["web_search_call.results"], input: "Use web search to find one photograph of the Golden Gate Bridge. Give a short description of the image and its source.", image: true },
  ];
  const report = { observedAt: new Date().toISOString(), base, model, noAutomaticRetries: true, cases: [] };
  for (const item of cases) {
    const started = Date.now();
    const tool = { type: "web_search" };
    if (item.image) Object.assign(tool, { search_content_types: ["image", "text"], image_settings: { max_results: 1, caption: true } });
    const request = { model, stream: false, reasoning: { effort: "low" }, input: item.input, tools: [tool], tool_choice: { type: "web_search" }, include: item.include };
    if (item.text) request.text = item.text;
    const result = { name: item.name, requestedInclude: item.include };
    try {
      const response = await fetch(`${base}/responses`, { method: "POST", headers: { Authorization: `Bearer ${env.CPA_API_KEY}`, "Content-Type": "application/json", "X-Client-Request-Id": `cpa-upgrade-capability-${item.name}-${Date.now()}` }, body: JSON.stringify(request), signal: AbortSignal.timeout(20000) });
      result.httpStatus = response.status;
      result.origin = response.headers.get("x-cpa-origin-hostname");
      const body = await response.json();
      result.status = body.status || null;
      result.model = body.model || null;
      if (!response.ok) {
        const code = body.error?.code;
        result.errorCode = typeof code === "string" && /^[a-zA-Z0-9_.-]{1,80}$/.test(code) ? code : "upstream_request_rejected";
      } else {
        const output = Array.isArray(body.output) ? body.output : [];
        const calls = output.filter(x => x.type === "web_search_call");
        const sources = calls.flatMap(x => Array.isArray(x.action?.sources) ? x.action.sources : []);
        const rawResults = calls.flatMap(x => Array.isArray(x.results) ? x.results : []);
        const annotations = output.flatMap(x => Array.isArray(x.content) ? x.content : []).flatMap(x => Array.isArray(x.annotations) ? x.annotations : []);
        result.searchCalls = calls.length;
        result.completedSearchCalls = calls.filter(x => x.status === "completed").length;
        result.sourceCount = sources.length;
        result.sourceTypes = [...new Set(sources.map(x => x.type).filter(Boolean))];
        result.citationCount = annotations.filter(x => x.type === "url_citation").length;
        result.rawResultCount = rawResults.length;
        result.rawResultTypes = [...new Set(rawResults.map(x => x.type).filter(Boolean))];
        result.imageResultCount = rawResults.filter(x => x.type === "image_result").length;
        result.totalTokens = body.usage?.total_tokens ?? null;
        result.structuredJSONValid = item.text ? (() => { try { const text = output.filter(x => x.type === "message").flatMap(x => x.content || []).filter(x => x.type === "output_text").map(x => x.text).join(""); const d = JSON.parse(text); return typeof d.url === "string" && typeof d.description === "string" && Object.keys(d).length === 2; } catch { return false; } })() : null;
      }
    } catch (error) {
      result.errorCode = error.name === "TimeoutError" ? "client_timeout_outcome_unconfirmed" : "transport_or_decode_failure";
    }
    result.durationMs = Date.now() - started;
    report.cases.push(result);
    fs.writeFileSync(process.argv[2], JSON.stringify(report, null, 2) + "\n", { mode: 0o600 });
    process.stdout.write(JSON.stringify(result) + "\n");
  }
}
main().catch(() => { process.stderr.write("capability probe could not complete\n"); process.exitCode = 1; });
