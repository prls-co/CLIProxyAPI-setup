# CLIProxyAPI Setup

Pinned, test-gated deployment of CLIProxyAPI (CPA) and CPA Manager Plus for
the canonical `https://cpa.prls.co/v1` OpenAI-compatible gateway.

The runtime contract is bearer authentication, `gpt-5.4-mini`, and persisted
Codex OAuth subscription access. No pay-per-token OpenAI provider is configured.
CPA Manager Plus is available at `https://cpa.prls.co/management.html` using
its native admin-key login. All raw service ports remain loopback-only.

This repository owns one public API origin: CPA. Consumer migrations are owned
by their repositories and coordinated through GitHub issues, including
[utility-llm issue #15](https://github.com/prls-co/utility-llm/issues/15).

`.env.local` is the canonical local source for manually managed credentials.
Runtime mirrors, OAuth state, backups, and generated configuration are
intentionally untracked. This deployment does not require GCP Secret Manager.

## Common operations

```bash
bash scripts/switch-current-machine.sh
bash scripts/restart-private.sh
bash scripts/backup.sh
bash scripts/install-systemd-service.sh
```

See `docs/operations.md` for device authorization, health, recovery,
backup/restore, upgrade, and incident procedures.

## Verification groups

```bash
make test-static
make test-unit
make test-security
make test-local
make test-contract
make test-observability
make test-public
make eval
make verify
```

`make verify` exercises the local deployment. `make test-public` and `make
eval` include live provider calls and should be run when release evidence is
required.

## Public subscription smoke check (Fish)

Load the local CPA key into the current Fish session, then run the short public
Chat Completions request:

```fish
set -x CPA_API_KEY (string trim < state/secrets/cpa-api-key)

curl -i https://cpa.prls.co/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $CPA_API_KEY" \
  -d '{
    "model": "gpt-5.6-luna",
    "messages": [
      {
        "role": "user",
        "content": "How many r`s are in the word `strawberry?`"
      }
    ],
    "reasoning": {
      "effort": "low"
    }
  }'
```

The gateway bearer key authenticates CPA; its persisted Codex OAuth state uses
the ChatGPT subscription. The model name is `gpt-5.6-luna` without a provider
prefix. The response headers include `X-CPA-Origin-Hostname`, which identifies
the machine that served the request. Set the optional `CPA_ORIGIN_HOSTNAME` in
`.env.local` to override the machine hostname used by the edge.
