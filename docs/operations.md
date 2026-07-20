# Operations runbook

All commands run from `/home/kirill/p/CLIProxyAPI-setup`. Credentials remain in
`state/secrets/` and the ignored mode-`0600` `.env`; never paste them into
commands, tickets, or logs.

## Install and boot ownership

Initialize state, render configuration, provision the CPA tunnel, and install
the user service:

```bash
bash scripts/init-state.sh
python3 scripts/render-cpa-config.py
python3 scripts/render-public-config.py
bash scripts/configure-cloudflare.sh
bash scripts/install-systemd-service.sh
systemctl --user status cliproxyapi-setup.service
```

Cloudflare provisioning requires `CLOUDFLARE_API_TOKEN` in the ignored `.env`
with Zone Read, DNS Edit, and Cloudflare Tunnel Write. The script creates or
updates only the `shaman-cpa` tunnel and `cpa.prls.co` DNS record, then stores
its connector token in ignored mode-`0600` state.

The user unit starts CPA, CPA Manager Plus, the `cpa-edge` sidecar, and the
`shaman-cpa` connector. The edge always passes `/v1/*` directly to CPA and
serves CPA Manager Plus at `https://cpa.prls.co/management.html`. User lingering
must remain enabled. If the running user manager predates the operator's Docker
group membership, the installer enables the unit for the next boot and
converges the live stack without restarting unrelated user services.

## Health and status

```bash
docker compose ps
curl -fsS http://127.0.0.1:8317/healthz
curl -fsS http://127.0.0.1:18317/health
curl -fsS https://cpa.prls.co/healthz
CPAMP_KEY="$(<state/secrets/cpamp-admin-key)"
curl -fsS -H "Authorization: Bearer $CPAMP_KEY" http://127.0.0.1:18317/status | jq .
unset CPAMP_KEY
```

The public dashboard uses CPA Manager Plus's native admin-key login. The
renderer mirrors `state/secrets/cpamp-admin-key` into `CPAMP_ADMIN_KEY` in the
ignored `.env`. Caddy does not add a second authentication layer or inject
authorization.

```bash
bash tests/e2e/public_dashboard.sh
```

Healthy collector status has `collector.collector == "running"`, an empty
`collector.lastError`, and advancing consumption and insertion timestamps after
a request.

## Device login

If Codex OAuth is revoked or expires, perform device login interactively and
then re-run readiness:

```bash
bash scripts/cpa-codex-login.sh
CPA_BASE_URL=http://127.0.0.1:8317 CPA_API_KEY_FILE=state/secrets/cpa-api-key MODEL=gpt-5.4-mini bash tests/integration/cpa_auth_models.sh
```

## Contract tests

```bash
make test-static
make test-unit
make test-security
make test-local
make test-contract
make test-observability
make test-public
```

`make test-public` also loads the real `/home/kirill/p/utility-llm` CPA profile
and requires `gpt-5.4-mini`, streaming and non-streaming Responses, strict JSON
Schema, and native `web_search`. That test should be run after utility-llm's
CPA migration is committed and its local runtime credentials use `CPA_API_KEY`.

## Backup and restore

Create and verify a consistent protected local backup. CPA stays online while
CPA Manager Plus pauses briefly for the snapshot:

```bash
archive="$(bash scripts/backup.sh)"
bash scripts/restore-test.sh "$archive" | jq .
unset archive
```

Copy mode-`0600` archives from `backups/` to encrypted off-host storage. A live
restore is an incident action: stop the user unit, validate the archive, extract
as root while preserving numeric ownership, replace CPA configuration/auth,
CPA Manager Plus `usage.sqlite*` plus `data.key`, and secrets as one recovery
point, then start the unit and run local and public contracts. Never restore
SQLite without its matching `data.key`.

## Restart and recovery

Recreate CPA and CPA Manager Plus while retaining the public connector:

```bash
bash scripts/restart-private.sh
bash tests/integration/restart_persistence.sh
```

For full service recovery:

```bash
systemctl --user restart cliproxyapi-setup.service
systemctl --user status cliproxyapi-setup.service
make test-public
```

## Upgrade

Never replace an image digest in place. Record the new tag, index digest,
release notes, and previous CPA digest; update `compose.yaml` and the static
digest assertions together. Render Compose twice, then run all local, contract,
observability, public, and recovery gates. Keep the previous immutable CPA image
and a fresh verified backup until the new version passes.

## Incident response

- Public 5xx: compare local and public health, inspect sanitized recent logs,
  and restart the CPA stack if local health is degraded.
- Tunnel failure: confirm local CPA health, inspect the CPA connector, and
  recreate only `cloudflared` after checking the stored connector token.
- OAuth failure: keep paid providers absent, repeat device login, and verify the
  model catalog before restoring traffic.
- Collector stall: check `/status`, disk space, `usage-statistics-enabled`, and
  the private management-key mount; do not expose management publicly.
- Suspected credential disclosure: stop evidence capture, remove unsafe local
  artifacts, rotate the affected credential, re-render CPA, and repeat the
  security and public contract tests.
