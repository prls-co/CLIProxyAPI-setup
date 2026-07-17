# CLIProxyAPI Setup

Pinned, test-gated deployment of CLIProxyAPI and CPA Manager Plus for the
`cpa.prls.co` OpenAI-compatible gateway. The legacy `litellm.prls.co` hostname
remains owned by `/home/kirill/p/litellm-chatgpt` and serves LiteLLM directly.

The implementation plan is in `plans/cpa-manager-plus-migration.md`. Runtime
state, credentials, backups, and generated configuration are intentionally
untracked.

The CPA public contract is `https://cpa.prls.co/v1`, bearer
authentication, and `gpt-5.4-mini`. CPA uses persisted Codex OAuth subscription
access; no pay-per-token OpenAI provider is configured. CPA Manager Plus is
available at `https://cpa.prls.co/management.html` using CPAMP's native
admin-key login. The key is mirrored to `CPAMP_ADMIN_KEY` in the ignored,
mode-`0600` `.env`; there is no additional proxy username/password.
The unauthenticated CPAMP listener remains loopback-only on `127.0.0.1:18317`.
CPA and LiteLLM use independent Cloudflare tunnels. Switching the CPA public
origin changes only the upstream behind `cpa.prls.co`; both hostnames and both
tunnel connectors stay online.

## Common operations

```bash
bash scripts/switch-origin.sh cpa
bash scripts/switch-origin.sh litellm
bash scripts/configure-cloudflare.sh
bash scripts/restart-private.sh
bash scripts/backup.sh
bash scripts/install-systemd-service.sh
```

See `docs/operations.md` for device authorization, health, cutover, rollback,
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

Targets become runnable as their corresponding implementation phases land.
