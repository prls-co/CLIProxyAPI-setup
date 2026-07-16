# Scripts

Operational scripts never enable shell tracing and read credentials from
mode-restricted files rather than command arguments. The public dashboard
renderer mirrors CPAMP's native admin key into the ignored mode-`0600` `.env`;
its generated Caddy configuration remains ignored and mode `0600`.
