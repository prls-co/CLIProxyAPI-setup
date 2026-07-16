# Operations runbook

All commands run from `/home/kirill/p/CLIProxyAPI-setup`. Credentials remain in
`state/secrets/` and the ignored mode-`0600` `.env`; never paste them into
commands, tickets, or logs.

## Install and boot ownership

Initialize state, render configuration, and install the user service:

```bash
bash scripts/init-state.sh
python3 scripts/render-cpa-config.py
python3 scripts/render-public-config.py
bash scripts/install-systemd-service.sh
systemctl --user status cliproxyapi-setup.service
```

The installer adds a managed LiteLLM Compose override that profiles its old
cloudflared service out of the legacy system unit's default `compose up`. The
LiteLLM container remains boot-managed as the local fallback. The new user unit
starts CPA and CPAMP, reads `state/active-origin`, and starts exactly that
origin's connector. When CPA is active, the tunnel's existing
`http://litellm:4000` origin resolves to the authenticated edge sidecar. It
passes `/v1/*` to CPA unchanged and serves CPAMP at
`https://litellm.prls.co/management.html`. User lingering must remain enabled (`loginctl show-user
kirill -p Linger` currently reports `yes`). If the already-running user manager
predates the operator's Docker group membership, the installer enables the unit
for the next boot and converges the live stack directly without restarting the
user manager and disrupting unrelated desktop or worker services.

## Health and status

```bash
docker compose ps
curl -fsS http://127.0.0.1:8317/healthz
curl -fsS http://127.0.0.1:18317/health
CPAMP_KEY="$(<state/secrets/cpamp-admin-key)"
curl -fsS -H "Authorization: Bearer $CPAMP_KEY" http://127.0.0.1:18317/status | jq .
unset CPAMP_KEY
```

The public dashboard uses CPAMP's native admin-key login. The renderer mirrors
`state/secrets/cpamp-admin-key` into `CPAMP_ADMIN_KEY` in the ignored,
mode-`0600` `.env`. Caddy adds no second authentication layer and does not
inject authorization; CPAMP itself rejects unauthenticated or invalid API
requests. Verify this boundary without exposing the key on the process command
line:

```bash
bash tests/e2e/public_dashboard.sh
```

Healthy CPAMP status has `collector.collector == "running"`, an empty
`collector.lastError`, and advancing consumption/insertion timestamps after a
request.

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

`make test-public` also runs the real `/home/kirill/p/utility-llm` Shaman
profile against `https://litellm.prls.co/v1`. The smoke asserts that
`gpt-5.4-mini` uses the Responses interface and succeeds with strict JSON Schema
and required native `web_search` in the same request.

Run the release evaluations explicitly; public failover is intentionally gated:

```bash
make eval
ALLOW_PUBLIC_FAILOVER=1 PUBLIC_BASE_URL=https://litellm.prls.co/v1 PUBLIC_API_KEY_FILE=state/secrets/cpa-api-key bash tests/eval/failover_rehearsal.sh
```

## Cut over and roll back

Cut over to CPA or roll back to LiteLLM with the serialized state machine:

```bash
bash scripts/switch-origin.sh cpa
bash scripts/switch-origin.sh litellm
```

Each transition preflights the local target, stops and confirms the other
connector, starts one connector, performs a bounded public probe, and writes
`state/active-origin` atomically. A failed public probe restores the prior
connector and marker. Never start either cloudflared service manually while a
switch is running.

## Backup and restore

Create a consistent protected local backup (CPAMP pauses; CPA stays online):

```bash
archive="$(bash scripts/backup.sh)"
bash scripts/restore-test.sh "$archive" | jq .
unset archive
```

Copy mode-`0600` archives from `backups/` to encrypted off-host storage. A live
restore is an incident action: stop the user unit, validate the archive with
`restore-test.sh`, extract as root while preserving numeric ownership, replace
CPA config/auth, CPAMP `usage.sqlite*` plus `data.key`, secrets, and
`active-origin` as one recovery point, then start the unit and run all local and
public contracts. Do not restore SQLite without its matching `data.key`.

## Restart and recovery

Recreate only CPA and CPAMP while retaining the public connector identity:

```bash
bash scripts/restart-private.sh
bash tests/integration/restart_persistence.sh
```

For a full service recovery:

```bash
systemctl --user restart cliproxyapi-setup.service
systemctl --user status cliproxyapi-setup.service
make test-public
```

## Upgrade

Never replace an image digest in place. Record the new tag, index digest,
release notes, and rollback digest; update `compose.yaml` and the static digest
assertions together. Render Compose twice, then repeat TEST-002 through TEST-013
and EVAL-002 through EVAL-006. Keep the previous images and a fresh verified
backup until the new version completes the failover rehearsal.

## Incident response

- Public 5xx: run the local target health test, inspect sanitized recent logs,
  then roll back with `bash scripts/switch-origin.sh litellm` if CPA is suspect.
- Split connector suspicion: stop both cloudflared services, verify local
  targets, then run one switch command. Do not alter `active-origin` by hand.
- OAuth failure: keep paid OpenAI providers absent, repeat device login, and
  verify the catalog before moving traffic.
- Collector stalled: check `/status`, disk space, `usage-statistics-enabled`,
  and the private management-key mount; do not expose management publicly.
- Suspected credential disclosure: stop evidence capture, remove unsafe local
  artifacts, rotate the affected credential, re-render CPA, and repeat the
  security tests.
