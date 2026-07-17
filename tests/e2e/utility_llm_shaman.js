#!/usr/bin/env node
// TEST-015: real utility-llm -> Shaman -> CPA structured web-search smoke.
"use strict";

const path = require("path");

const utilityRoot = process.env.UTILITY_LLM_ROOT || "/home/kirill/p/utility-llm";
const { loadAndApplyRuntimeEnv } = require(path.join(utilityRoot, "dev/runtime-env"));
loadAndApplyRuntimeEnv({ repoRoot: utilityRoot });
const api = require(utilityRoot);

const modelId = "gpt-5.4-mini";
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
  if (!model || model.provider !== "shaman-litellm" || model.apiInferenceType !== "responses") {
    throw new Error("gpt-5.4-mini is not routed through the Shaman Responses profile");
  }
  const provider = api.PROVIDER_CONFIG[model.provider];
  if (!provider || provider.baseURL !== expectedBaseUrl) {
    throw new Error(`Shaman base URL mismatch: ${provider && provider.baseURL}`);
  }
  if (!process.env.SHAMAN_LITELLM_API_KEY) {
    throw new Error("SHAMAN_LITELLM_API_KEY is unavailable in utility-llm runtime env");
  }

  const result = await api.utilityLLMCall({
    modelId,
    callType: "native",
    systemPrompt: "Obey the strict response schema. Use the required web search tool before answering.",
    userPrompt: "Search the web for the official OpenAI homepage and return its registrable domain.",
    schema,
    tools: [{ type: "web_search", search_context_size: "low" }],
    tool_choice: "required",
    reasoning: { effort: "none" },
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
    throw new Error(`unexpected structured result: ${JSON.stringify(result)}`);
  }
  console.log(JSON.stringify({
    ok: true,
    profile: "shaman-litellm",
    baseURL: expectedBaseUrl,
    model: modelId,
    api: "responses",
    structuredOutput: "strict-json-schema",
    webSearch: "required",
    result,
  }, null, 2));
}

main().catch((error) => {
  console.error(error && error.message ? error.message : error);
  process.exitCode = 1;
});
