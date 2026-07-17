#!/usr/bin/env bash
# TEST-002
set -euo pipefail
export LC_ALL=C

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"

for file in compose.yaml .env.example config/cpa/config.yaml.template; do
  [[ -f "$file" ]] || { printf 'missing %s\n' "$file" >&2; exit 1; }
done

rendered="$(mktemp)"
trap 'rm -f "$rendered"' EXIT
COMPOSE_PROJECT_NAME=cliproxyapi-test docker compose --profile public config --format json >"$rendered"

cpa_digest='eceasy/cli-proxy-api@sha256:6f5bcee0c3b8d0536f4a3f0f5cb9fd0b7d2e17196dd40d30f11aec9cc2f5f161'
cpamp_digest='seakee/cpa-manager-plus@sha256:5897b299887dbe7a8fa2e23850fe64949e5a60a94ba5e5aebd3acd810e710351'
cloudflared_digest='cloudflare/cloudflared@sha256:59bab8d3aceec09bf6bdb07d6beca0225ca5cd7ab79436a87ea97978fe1dc4f9'
caddy_digest='caddy@sha256:c3d7ee5d2b11f9dc54f947f68a734c84e9c9666c92c88a7f30b9cba5da182adb'

jq -e --arg v "$cpa_digest" '.services["cli-proxy-api"].image == $v' "$rendered" >/dev/null
jq -e --arg v "$cpamp_digest" '.services["cpa-manager-plus"].image == $v' "$rendered" >/dev/null
jq -e --arg v "$cloudflared_digest" '.services.cloudflared.image == $v' "$rendered" >/dev/null
jq -e --arg v "$caddy_digest" '.services["cpamp-public"].image == $v' "$rendered" >/dev/null
jq -e '.services["cpamp-public"].user == "1000:1000"' "$rendered" >/dev/null
jq -e '.services["cli-proxy-api"].ports[] | select(.host_ip == "127.0.0.1" and .published == "8317" and .target == 4000)' "$rendered" >/dev/null
jq -e '.services["cpa-manager-plus"].ports[] | select(.host_ip == "127.0.0.1" and .published == "18317" and .target == 18317)' "$rendered" >/dev/null
jq -e '.services["cpamp-public"].ports[] | select(.host_ip == "127.0.0.1" and .published == "18417" and .target == 4000)' "$rendered" >/dev/null
jq -e '.services["cpamp-public"].networks.gateway.aliases | index("cpa-edge")' "$rendered" >/dev/null
jq -e '.services["cpamp-public"].networks | has("litellm")' "$rendered" >/dev/null
jq -e '.networks.litellm.external == true and .networks.litellm.name == "shaman-api_default"' "$rendered" >/dev/null
jq -e '.services.cloudflared.profiles | index("public")' "$rendered" >/dev/null
jq -e '.services.cloudflared.user == "65532:65532" and .services.cloudflared.read_only == true' "$rendered" >/dev/null
jq -e '.services.cloudflared.cap_drop | index("ALL")' "$rendered" >/dev/null
jq -e '.services.cloudflared.security_opt | index("no-new-privileges:true")' "$rendered" >/dev/null
jq -e '.services["cpamp-public"].read_only == true and (.services["cpamp-public"].cap_drop | index("ALL"))' "$rendered" >/dev/null
jq -e '.services["cpamp-public"].cap_add | index("NET_BIND_SERVICE")' "$rendered" >/dev/null
jq -e '.services["cpamp-public"].security_opt | index("no-new-privileges:true")' "$rendered" >/dev/null
jq -e '.services["cpamp-public"].depends_on["cpa-manager-plus"].condition == "service_healthy"' "$rendered" >/dev/null
jq -e '.services.cloudflared.depends_on["cpamp-public"].condition == "service_healthy"' "$rendered" >/dev/null
jq -e '.services["cloudflared-token-init"].image == .services["cli-proxy-api"].image' "$rendered" >/dev/null
jq -e '.services["cloudflared-token-init"].network_mode == "none" and .services["cloudflared-token-init"].restart == "no"' "$rendered" >/dev/null
jq -e '.services["cloudflared-token-init"].command[] | contains("chown 65532:65532") and contains("chmod 0400")' "$rendered" >/dev/null
jq -e '.services.cloudflared.depends_on["cloudflared-token-init"].condition == "service_completed_successfully"' "$rendered" >/dev/null
jq -e '.services["cli-proxy-api"].restart == "unless-stopped" and .services["cpa-manager-plus"].restart == "unless-stopped" and .services["cpamp-public"].restart == "unless-stopped"' "$rendered" >/dev/null
jq -e '.services["cpa-manager-plus"].volumes[] | select(.target == "/data")' "$rendered" >/dev/null
jq -e '.services["cpa-manager-plus"].environment.CPA_UPSTREAM_URL == "http://cli-proxy-api:4000"' "$rendered" >/dev/null
jq -e '.services["cpa-manager-plus"].environment.CPA_MANAGEMENT_KEY_FILE == "/run/secrets/cpa_management_key"' "$rendered" >/dev/null
jq -e '.services["cpa-manager-plus"].secrets[] | select(.source == "cpa_management_key" and .target == "/run/secrets/cpa_management_key")' "$rendered" >/dev/null
jq -e '.services["cpa-manager-plus"].depends_on["cli-proxy-api"].condition == "service_healthy"' "$rendered" >/dev/null
jq -e '.services["cli-proxy-api"].healthcheck.test[1] | contains("bash -c")' "$rendered" >/dev/null

grep -Eq '^port: 4000$' config/cpa/config.yaml.template
grep -Eq '^usage-statistics-enabled: true$' config/cpa/config.yaml.template
grep -Eq '^redis-usage-queue-retention-seconds: 3600$' config/cpa/config.yaml.template
grep -Eq '^disable-image-generation: "passthrough"$' config/cpa/config.yaml.template
if grep -Eqi 'openai-api-key|OPENAI_API_KEY' config/cpa/config.yaml.template compose.yaml; then
  printf 'paid OpenAI provider configuration is forbidden\n' >&2
  exit 1
fi

printf 'compose contract: ok\n'
