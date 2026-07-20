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

Runtime state, credentials, backups, and generated configuration are
intentionally untracked.

## Common operations

```bash
bash scripts/configure-cloudflare.sh
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
