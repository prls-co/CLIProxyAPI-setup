# Repository Instructions

## Secrets and API keys

- Keep local secrets, API keys, and access tokens in the ignored `.env.local`
  file (preferred for machine-specific values) or `.env`.
- Never commit, print, log, paste, or otherwise expose values from either
  environment file. Read only the specific variables required for an approved
  task, and keep their values out of command output and generated artifacts.
- Do not introduce or use GCP Secret Manager or other GCP-hosted secrets for
  this repository. Use `.env.local` or `.env` instead to avoid that cost.
- Treat `.env.local` as the canonical source for manually managed secrets.
  Ignored mode-`0600` files under `state/` may be generated only as runtime
  mirrors required by CPA, Compose, or backup/restore; never edit them as the
  source of truth.

## LLM routing

- Treat `cpa.prls.co` and `shaman.prls.co` as unavailable. Do not call them or
  use them as fallback endpoints.
- For normal LLM work, prefer utility-llm with the exact
  `Novita DeepSeek V4 Flash` profile. A direct `Novita DeepSeek V4 Flash` call
  is also acceptable when utility-llm is not the appropriate caller.
- When a raw LLM call is needed, use OpenAI `gpt-5.6-luna` with low reasoning
  effort.
