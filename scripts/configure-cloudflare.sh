#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
umask 077

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

: "${CLOUDFLARE_API_TOKEN:?CLOUDFLARE_API_TOKEN is required}"
: "${CLOUDFLARE_ZONE_NAME:=prls.co}"
: "${CPA_TUNNEL_NAME:=shaman-cpa}"
: "${CPA_PUBLIC_HOSTNAME:=cpa.prls.co}"
: "${CPA_TUNNEL_ORIGIN:=http://cpa-edge:4000}"

api=https://api.cloudflare.com/client/v4

cf_get() {
  curl -sS -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" "$api/$1"
}

cf_write() {
  local method="$1" path="$2" payload="$3"
  curl -sS -X "$method" \
    -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
    -H 'Content-Type: application/json' \
    --data "$payload" \
    "$api/$path"
}

require_success() {
  local operation="$1" response="$2"
  if ! jq -e '.success == true' <<<"$response" >/dev/null; then
    printf 'Cloudflare operation failed: %s\n' "$operation" >&2
    jq -r '.errors[]? | "error " + (.code|tostring) + ": " + .message' <<<"$response" >&2
    exit 1
  fi
}

zone_response="$(cf_get "zones?name=$CLOUDFLARE_ZONE_NAME")"
require_success 'resolve zone' "$zone_response"
[[ "$(jq '.result | length' <<<"$zone_response")" == 1 ]] || {
  printf 'expected exactly one Cloudflare zone named %s\n' "$CLOUDFLARE_ZONE_NAME" >&2
  exit 1
}
zone_id="$(jq -r '.result[0].id' <<<"$zone_response")"
account_id="$(jq -r '.result[0].account.id' <<<"$zone_response")"

tunnels_response="$(cf_get "accounts/$account_id/cfd_tunnel?is_deleted=false&name=$CPA_TUNNEL_NAME")"
require_success 'list CPA tunnels' "$tunnels_response"
tunnel_count="$(jq '[.result[] | select(.name == $name)] | length' --arg name "$CPA_TUNNEL_NAME" <<<"$tunnels_response")"
if [[ "$tunnel_count" == 0 ]]; then
  tunnel_response="$(cf_write POST "accounts/$account_id/cfd_tunnel" "$(jq -nc --arg name "$CPA_TUNNEL_NAME" '{name:$name,config_src:"cloudflare"}')")"
  require_success 'create CPA tunnel' "$tunnel_response"
  tunnel_id="$(jq -r '.result.id' <<<"$tunnel_response")"
elif [[ "$tunnel_count" == 1 ]]; then
  tunnel_id="$(jq -r --arg name "$CPA_TUNNEL_NAME" '.result[] | select(.name == $name) | .id' <<<"$tunnels_response")"
  config_source="$(jq -r --arg name "$CPA_TUNNEL_NAME" '.result[] | select(.name == $name) | .config_src' <<<"$tunnels_response")"
  [[ "$config_source" == cloudflare ]] || {
    printf 'existing tunnel %s is not remotely managed\n' "$CPA_TUNNEL_NAME" >&2
    exit 1
  }
else
  printf 'multiple active tunnels are named %s\n' "$CPA_TUNNEL_NAME" >&2
  exit 1
fi

config_payload="$(jq -nc \
  --arg hostname "$CPA_PUBLIC_HOSTNAME" \
  --arg service "$CPA_TUNNEL_ORIGIN" \
  '{config:{ingress:[{hostname:$hostname,service:$service},{service:"http_status:404"}]}}')"
config_response="$(cf_write PUT "accounts/$account_id/cfd_tunnel/$tunnel_id/configurations" "$config_payload")"
require_success 'configure CPA tunnel ingress' "$config_response"

dns_response="$(cf_get "zones/$zone_id/dns_records?name=$CPA_PUBLIC_HOSTNAME")"
require_success 'read CPA DNS record' "$dns_response"
dns_count="$(jq '.result | length' <<<"$dns_response")"
dns_target="$tunnel_id.cfargotunnel.com"
dns_payload="$(jq -nc \
  --arg name "$CPA_PUBLIC_HOSTNAME" \
  --arg content "$dns_target" \
  '{type:"CNAME",name:$name,content:$content,ttl:1,proxied:true}')"
if [[ "$dns_count" == 0 ]]; then
  dns_write_response="$(cf_write POST "zones/$zone_id/dns_records" "$dns_payload")"
elif [[ "$dns_count" == 1 && "$(jq -r '.result[0].type' <<<"$dns_response")" == CNAME ]]; then
  dns_id="$(jq -r '.result[0].id' <<<"$dns_response")"
  dns_write_response="$(cf_write PUT "zones/$zone_id/dns_records/$dns_id" "$dns_payload")"
else
  printf 'refusing to replace an unexpected DNS record for %s\n' "$CPA_PUBLIC_HOSTNAME" >&2
  exit 1
fi
require_success 'write CPA DNS record' "$dns_write_response"

token_response="$(cf_get "accounts/$account_id/cfd_tunnel/$tunnel_id/token")"
require_success 'get CPA tunnel token' "$token_response"
tunnel_token="$(jq -r '.result' <<<"$token_response")"
[[ "$tunnel_token" != null && ${#tunnel_token} -ge 100 ]] || {
  printf 'Cloudflare returned an invalid CPA tunnel token\n' >&2
  exit 1
}

token_path=state/secrets/tunnel-token
mkdir -p "$(dirname "$token_path")"
temporary="$(mktemp "$token_path.tmp.XXXXXX")"
trap 'rm -f "$temporary"' EXIT
printf '%s' "$tunnel_token" >"$temporary"
chmod 600 "$temporary"
mv -f "$temporary" "$token_path"
trap - EXIT

printf 'configured tunnel %s (%s) for https://%s\n' "$CPA_TUNNEL_NAME" "$tunnel_id" "$CPA_PUBLIC_HOSTNAME"
