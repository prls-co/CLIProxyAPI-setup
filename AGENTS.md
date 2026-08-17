# Repository Instructions

## Secrets and API keys

- Keep local secrets, API keys, access tokens, and configuration variables in
  the ignored mode-`0600` `.env` file. `.env` is the single source of truth;
  `.env.local` is unsupported.
- Never commit, print, log, paste, or otherwise expose values from `.env`.
  Read only the specific variables required for an approved task, and keep
  their values out of command output and generated artifacts.
- Do not introduce or use GCP Secret Manager or other GCP-hosted secrets for
  this repository. Use `.env` instead to avoid that cost.
- Do not create credential mirrors under `state/secrets/`. Generated OAuth
  state, databases, and rendered configuration under `state/` are runtime data,
  not configuration sources.

## LLM routing

- For normal LLM work, prefer utility-llm with the exact
  `Novita DeepSeek V4 Flash` profile. A direct `Novita DeepSeek V4 Flash` call
  is also acceptable when utility-llm is not the appropriate caller.
- When a raw LLM call is needed, use OpenAI `gpt-5.6-luna` with low reasoning
  effort.
