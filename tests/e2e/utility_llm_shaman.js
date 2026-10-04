#!/usr/bin/env node
// TEST-015: real utility-llm -> Shaman -> CPA structured web-search smoke.
"use strict";

const fs = require("fs");
const path = require("path");

function loadDotEnv(filePath) {
  const values = new Map();
  for (const [index, rawLine] of fs.readFileSync(filePath, "utf8").split(/\r?\n/).entries()) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) continue;
    const match = line.match(/^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$/);
    if (!match) throw new Error(`invalid .env assignment at ${filePath}:${index + 1}`);
    const [, key, rawValue] = match;
    if (values.has(key)) throw new Error(`duplicate .env variable: ${key}`);
    let value = rawValue.trim();
    if (value.startsWith("'") && value.endsWith("'")) {
      value = value.slice(1, -1).replaceAll("'\"'\"'", "'");
    } else if (value.startsWith('"') && value.endsWith('"')) {
      value = value.slice(1, -1).replaceAll('\\"', '"').replaceAll('\\\\', '\\');
    }
    values.set(key, value);
  }
  for (const [key, value] of values) process.env[key] = value;
}

const setupRoot = path.join(__dirname, "..", "..");
loadDotEnv(path.join(setupRoot, ".env"));
const utilityRoot = process.env.UTILITY_LLM_ROOT || "/home/kirill/p/utility-llm";
const { loadAndApplyRuntimeEnv } = require(path.join(utilityRoot, "dev/runtime-env"));
loadAndApplyRuntimeEnv({ repoRoot: utilityRoot });
loadDotEnv(path.join(setupRoot, ".env"));
const api = require(utilityRoot);

const modelId = "gpt-5.6-luna";
const expectedBaseUrl = "https://cpa.prls.co/v1";
const schema = {
  type: "object",
  additionalProperties: false,
  required: ["domain", "search_used", "marker"],
  properties: {
    domain: { type: "string", const: "openai.com" },
    search_used: { type: "boolean", const: true },
    marker: { type: "string", const: "utility-llm-shaman-web-schema" },
  },
};

async function main() {
  const model = api.MODEL_CONFIG[modelId];
  if (!model || model.provider !== "cpa" || model.apiInferenceType !== "responses") {
    throw new Error("gpt-5.6-luna is not routed through the CPA Responses profile");
  }
  const provider = api.PROVIDER_CONFIG[model.provider];
  if (!provider || provider.baseURL !== expectedBaseUrl) {
    throw new Error(`Shaman base URL mismatch: ${provider && provider.baseURL}`);
  }
  if (!process.env.CPA_API_KEY) {
    throw new Error("CPA_API_KEY is unavailable in utility-llm runtime env");
  }

  const lowestResults = [];
  for (const lowestModelId of ["gpt-5.6-luna", "gpt-5.6-sol"]) {
    const lowestModel = api.MODEL_CONFIG[lowestModelId];
    if (lowestModel?.provider !== "cpa" || lowestModel.apiInferenceType !== "responses" ||
        lowestModel.reasoningEffortMap?.lowest?.reasoning?.effort !== "low") {
      throw new Error(`${lowestModelId} must map contracted lowest to CPA-supported low`);
    }
    const lowestResult = await api.utilityLLMCall({
      modelId: lowestModelId,
      callType: "contracted",
      reasoningEffort: "lowest",
      userPrompt: "Return the requested sentinel object.",
      schema: {
        type: "object", additionalProperties: false, required: ["sentinel"],
        properties: { sentinel: { type: "string", enum: ["LOWEST_SUPPORTED_EFFORT"] } },
      },
      max_tokens: 256,
      timeout: 19000,
      overallTimeoutMs: 20000,
      maxAttempts: 1,
      cacheMode: "off",
      loggingContext: { taskId: "utility-llm-shaman-lowest", taskSlug: "utility-llm-shaman-lowest" },
    });
    if (lowestResult?.sentinel !== "LOWEST_SUPPORTED_EFFORT" || Object.keys(lowestResult).length !== 1) {
      throw new Error("contracted lowest call returned an unexpected structured result");
    }
    // utility-llm's existing mismatch guard checks returned effort against the mapped request.
    lowestResults.push({ model: lowestModelId, reasoningEffort: "lowest", nativeEffort: "low", status: "pass" });
  }

  const result = await api.utilityLLMCall({
    modelId,
    callType: "native",
    systemPrompt: "Obey the strict response schema. Use the required web search tool before answering.",
    userPrompt: "Search the web for the official OpenAI homepage and return its registrable domain.",
    schema,
    tools: [{ type: "web_search", search_context_size: "low" }],
    tool_choice: "required",
    ...model.reasoningEffortMap.lowest,
    max_tokens: 256,
    timeout: 19000,
    overallTimeoutMs: 20000,
    maxAttempts: 1,
    cacheMode: "off",
    loggingContext: {
      taskId: "utility-llm-shaman-web-schema",
      taskSlug: "utility-llm-shaman-web-schema",
    },
  });

  if (!result || result.domain !== "openai.com" || result.search_used !== true || result.marker !== "utility-llm-shaman-web-schema") {
    throw new Error("native web-search call returned an unexpected structured result");
  }
  const summary = {
    ok: true,
    profile: "cpa",
    baseURL: expectedBaseUrl,
    model: modelId,
    api: "responses",
    structuredOutput: "strict-json-schema",
    webSearch: "required",
    lowestResults,
    result,
  };
  const artifactDirectory = path.join(setupRoot, "artifacts/P07/TEST-015");
  fs.mkdirSync(artifactDirectory, { recursive: true });
  fs.writeFileSync(path.join(artifactDirectory, "summary.json"), `${JSON.stringify(summary, null, 2)}\n`);
  console.log(JSON.stringify(summary, null, 2));
}

main().catch((error) => {
  // Provider errors can carry headers and request bodies; do not print them.
  console.error(`TEST-015 failed: ${error.code || error.name || "Error"}`);
  process.exitCode = 1;
});
