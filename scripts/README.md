# Scripts

Operational scripts never enable shell tracing or pass credentials through
command arguments. The ignored mode-`0600` `.env` is the single canonical
source for manually managed secrets, keys, and configuration variables.
`init-state.sh` creates missing CPA secrets directly in `.env`; Docker Compose
receives them through environment-backed ephemeral secret mounts. There are no
credential mirrors under `state/secrets/`. The generated Caddy configuration
remains ignored and contains no credentials. It is mode `0644` so the fixed
uid-1000 edge container can read it when the checkout owner has a different
uid.

`configure-cloudflare.sh` idempotently creates or updates the independently
managed `shaman-cpa` tunnel, routes `cpa.prls.co` to the `cpa-edge` sidecar,
updates the proxied DNS record, stores the connector token in `.env`, and
records non-secret tunnel context for cutover automation. Its API token needs
Zone Read, DNS Edit, and Cloudflare Tunnel Write.

`bootstrap.sh` is the one-command fresh-machine entry point. It creates the
ignored `.env` when needed, prompts for a missing Cloudflare token without
echoing it, initializes state, performs Codex device login when OAuth state is
absent, switches the canonical machine, and installs the user service. Use
`--skip-login` after restoring a state archive and `--skip-systemd` when another
supervisor owns the host.

`restore.sh` validates and restores an archive produced by `backup.sh`. It
checks archive traversal safety, manifest hashes and modes, required runtime
state, and Codex OAuth files in an isolated pinned helper container. It keeps a
recoverable copy of the existing `state/` directory and leaves services stopped
so `bootstrap.sh --skip-login` can complete the cutover.

`switch-current-machine.sh` is the canonical repeated-machine cutover. It
brings up and health-checks this machine's CPA origin and public edge,
reconciles the tunnel/DNS configuration, starts a fresh `cloudflared` replica,
waits for Cloudflare to report that replica, and removes the connector IDs that
were registered before the switch. It never probes `cpa.prls.co`; a live old
machine can reconnect after cleanup, so stop the old machine when moving the
repo.

The generated public edge adds `X-CPA-Origin-Hostname` to API responses. It
defaults to the hostname of the machine that rendered the edge; set
`CPA_ORIGIN_HOSTNAME` in `.env` when an explicit stable identity is preferred.
