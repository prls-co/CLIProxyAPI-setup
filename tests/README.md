# Tests

Test files contain a `TEST-###` tag and evaluation files contain an
`EVAL-###` tag. Tests write sanitized evidence under `artifacts/Pxx/` and do
not print credential values.

`tests/e2e/public_dashboard.sh` proves that the dashboard page is public while
CPAMP's native API rejects missing and invalid admin keys. `tests/e2e/utility_llm_shaman.js` loads the real
`/home/kirill/p/utility-llm` Shaman profile and requires `gpt-5.4-mini`, strict
JSON Schema, and native web search in one request with a 20-second hard limit.
