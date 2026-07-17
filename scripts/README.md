# Scripts

Operational scripts never enable shell tracing and read credentials from
mode-restricted files rather than command arguments. The public dashboard
renderer mirrors CPAMP's native admin key into the ignored mode-`0600` `.env`;
its generated Caddy configuration remains ignored and mode `0600`.

`configure-cloudflare.sh` idempotently creates or updates the independently
managed `shaman-cpa` tunnel, routes `cpa.prls.co` to the `cpa-edge` sidecar,
updates the proxied DNS record, and stores only the connector token in ignored
state. Its API token needs Zone Read, DNS Edit, and Cloudflare Tunnel Write.
