# Scripts

Operational scripts never enable shell tracing or pass credentials through
command arguments. The ignored mode-`0600` `.env.local` is the canonical source
for manually managed secrets. `init-state.sh` creates missing CPA secrets there
and maintains protected runtime mirrors under `state/secrets/` for Compose,
tests, and backup/restore. The generated Caddy configuration remains ignored
and mode `0600`.

`configure-cloudflare.sh` idempotently creates or updates the independently
managed `shaman-cpa` tunnel, routes `cpa.prls.co` to the `cpa-edge` sidecar,
updates the proxied DNS record, and stores only the connector token in ignored
state. Its API token needs Zone Read, DNS Edit, and Cloudflare Tunnel Write.
