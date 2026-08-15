# Scripts

Operational scripts never enable shell tracing or pass credentials through
command arguments. The ignored mode-`0600` `.env.local` is the canonical source
for manually managed secrets. `init-state.sh` creates missing CPA secrets there
and maintains protected runtime mirrors under `state/secrets/` for Compose,
tests, and backup/restore. The generated Caddy configuration remains ignored
and contains no credentials. It is mode `0644` so the fixed uid-1000 edge
container can read it when the checkout owner has a different uid.

`configure-cloudflare.sh` idempotently creates or updates the independently
managed `shaman-cpa` tunnel, routes `cpa.prls.co` to the `cpa-edge` sidecar,
updates the proxied DNS record, stores only the connector token in ignored
state, and records non-secret tunnel context for cutover automation. Its API
token needs Zone Read, DNS Edit, and Cloudflare Tunnel Write.

`switch-current-machine.sh` is the canonical repeated-machine cutover. It
brings up and health-checks this machine's CPA origin and public edge,
reconciles the tunnel/DNS configuration, starts a fresh `cloudflared` replica,
waits for Cloudflare to report that replica, and removes the connector IDs that
were registered before the switch. It never probes `cpa.prls.co`; a live old
machine can reconnect after cleanup, so stop the old machine when moving the
repo.

The generated public edge adds `X-CPA-Origin-Hostname` to API responses. It
defaults to the hostname of the machine that rendered the edge; set
`CPA_ORIGIN_HOSTNAME` in `.env.local` when an explicit stable identity is
preferred.
