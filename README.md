# CLIProxyAPI Setup

Pinned, test-gated deployment of CLIProxyAPI (CPA) and CPA Manager Plus for
the canonical `https://cpa.prls.co/v1` OpenAI-compatible gateway.

The runtime contract is bearer authentication with persisted Codex and Claude
OAuth subscription access. Automated local and public Codex contract tests use
`gpt-5.4-mini` as their acceptance baseline. CPA does not configure a
server-side default model; each request selects its model. The operator smoke
checks use `gpt-5.6-luna` with low reasoning and `claude-sonnet-5`. No
pay-per-token OpenAI or Anthropic provider is configured.
CPA Manager Plus is available at `https://cpa.prls.co/management.html` using
its native admin-key login. All raw service ports remain loopback-only.

This repository owns one public API origin: CPA. Consumer migrations are owned
by their repositories and coordinated through GitHub issues, including
[utility-llm issue #15](https://github.com/prls-co/utility-llm/issues/15).

`.env` is the single canonical local source for manually managed secrets,
keys, and configuration variables. It is ignored and must remain mode `0600`.
`.env.local` and `state/secrets/` are obsolete and unsupported; OAuth state,
backups, and generated configuration remain derived runtime data. This
deployment does not require GCP Secret Manager.

## Common operations

```bash
bash scripts/bootstrap.sh
bash scripts/cpa-claude-login.sh
fish scripts/smoke-claude.fish
bash scripts/switch-current-machine.sh
bash scripts/restart-private.sh
bash scripts/backup.sh
bash scripts/restore.sh /secure/path/cpa-state-ARCHIVE.tar.gz
bash scripts/install-systemd-service.sh
```

See `docs/operations.md` for device authorization, health, recovery,
backup/restore, upgrade, and incident procedures.

## Install on a new machine

On a Linux machine with Docker Engine and the Compose plugin installed. The
bootstrap preflight also requires `curl`, `jq`, Python 3, OpenSSL, `flock`, and
standard `find`/`timeout` tools. Systemd user tooling is required unless
`--skip-systemd` is used:

```bash
git clone git@github.com:prls-co/CLIProxyAPI-setup.git
cd CLIProxyAPI-setup
bash scripts/bootstrap.sh
```

The bootstrap command creates the ignored mode-`0600` `.env`, prompts for
the Cloudflare API token without echoing it, generates local CPA keys, starts
Codex device login when OAuth state is absent, switches `cpa.prls.co` to this
machine, and installs the user service. Add Claude subscription access with
`bash scripts/cpa-claude-login.sh` after bootstrap; its SSH-safe flow keeps the
OAuth callback on loopback. Use `--skip-systemd` when the host is managed by
another supervisor. Neither command prints API keys.

The runtime services—CPA, CPA Manager Plus, the Caddy edge, and `cloudflared`—
run in Docker Compose. Bootstrap, Cloudflare reconciliation, systemd
integration, and state backup/restore remain host-side because they need access
to the host Docker daemon, user service manager, and protected local files.

## Move the gateway to another machine

For a real migration, clone-only is not enough: the backup preserves the CPA
keys, Manager Plus database, and Codex and Claude subscription state. On the
old machine:

```bash
archive="$(bash scripts/backup.sh)"
```

Transfer that mode-`0600` archive through encrypted storage. On the new
machine, clone the repository, create `.env` from the example, add the
Cloudflare API token, and run:

```bash
bash scripts/restore.sh /secure/path/to/cpa-state-ARCHIVE.tar.gz
bash scripts/bootstrap.sh --skip-login
```

The restore validates the archive, keeps a recoverable copy of the previous
state, and leaves services stopped until bootstrap completes the cutover. Stop
the old machine's `cloudflared`/Compose stack after the new machine reports
success; an old live connector can reconnect after Cloudflare cleanup.

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
required. Fish is required by the static login contract and the public Claude
subscription smoke.

## Public subscription smoke check (Fish)

Run Fish explicitly when invoking these examples from a Bash-backed command
runner. Pasting Fish syntax such as `set -l NAME (...)` directly into Bash
fails before `curl` runs.

Test the Claude subscription through the public Anthropic Messages endpoint:

```console
fish scripts/smoke-claude.fish
```

Expected output is `claude-ok`. The script parses the Bash-style `.env` with
Bash, retains `CPA_API_KEY` only inside the Fish process, and passes the header
to `curl` through standard input rather than a command argument.

Load the local CPA key from the canonical `.env` into the current Fish session,
then run the short public Chat Completions request:

```fish
set -l CPA_API_KEY (bash -c 'source "$1"; printf "%s" "${CPA_API_KEY:-}"' bash .env)
test -n "$CPA_API_KEY"; or begin
    echo 'CPA_API_KEY is missing from .env' >&2
    exit 1
end

printf 'header = "Authorization: Bearer %s"\n' "$CPA_API_KEY" | \
curl -i --config - https://cpa.prls.co/v1/chat/completions \
  -H "Content-Type: application/json" \
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

The gateway bearer key authenticates CPA; its persisted OAuth state uses the
matching ChatGPT or Claude subscription according to the requested model. Model
names have no provider prefix. The response headers include
`X-CPA-Origin-Hostname`, which identifies the machine that served the request.
Set the optional `CPA_ORIGIN_HOSTNAME` in `.env` to override the machine
hostname used by the edge.
