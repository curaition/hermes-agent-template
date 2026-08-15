#!/usr/bin/env bash
# Hetzner Cloud Firewall "hermes-memory": inbound 22 (ADMIN_CIDR), 80, 443, ICMP; everything else denied
# (Coolify 8000/6001/6002 and Hindsight 8888/9999 included). Idempotent: get-or-create,
# always re-asserts rules, applies to the server if not already applied.
#   HCLOUD_TOKEN=... HCLOUD_SERVER_NAME=... [ADMIN_CIDR=1.2.3.4/32] ./hetzner_firewall.sh
set -euo pipefail
: "${HCLOUD_TOKEN:?set HCLOUD_TOKEN}"; : "${HCLOUD_SERVER_NAME:?set HCLOUD_SERVER_NAME}"
ADMIN_CIDR="${ADMIN_CIDR:-0.0.0.0/0}"
FW_NAME="hermes-memory"; API="https://api.hetzner.cloud/v1"

hz() { curl -sS --fail-with-body -H "Authorization: Bearer ${HCLOUD_TOKEN}" -H 'Content-Type: application/json' "$@"; }

server_id="$(hz "$API/servers?name=${HCLOUD_SERVER_NAME}" | jq -r '.servers[0].id // empty')"
[ -n "$server_id" ] || { echo "server '${HCLOUD_SERVER_NAME}' not found" >&2; exit 1; }

# SSH source: the admin CIDR; if wide-open IPv4 was requested, also allow IPv6.
if [ "$ADMIN_CIDR" = "0.0.0.0/0" ]; then ssh_src='["0.0.0.0/0","::/0"]'; else ssh_src="$(jq -cn --arg c "$ADMIN_CIDR" '[$c]')"; fi
rules="$(jq -cn --argjson ssh "$ssh_src" '[
  {direction:"in", protocol:"tcp",  port:"22",  source_ips:$ssh,                description:"ssh (admin)"},
  {direction:"in", protocol:"tcp",  port:"80",  source_ips:["0.0.0.0/0","::/0"], description:"http (proxy/ACME)"},
  {direction:"in", protocol:"tcp",  port:"443", source_ips:["0.0.0.0/0","::/0"], description:"https (proxy)"},
  {direction:"in", protocol:"icmp",             source_ips:["0.0.0.0/0","::/0"], description:"ping"}
]')"
apply_to="$(jq -cn --argjson s "$server_id" '[{type:"server",server:{id:$s}}]')"

fw="$(hz "$API/firewalls?name=${FW_NAME}" | jq -c '.firewalls[0] // empty')"
if [ -z "$fw" ]; then
  fw_id="$(hz -X POST "$API/firewalls" -d "$(jq -cn --arg n "$FW_NAME" --argjson r "$rules" --argjson a "$apply_to" '{name:$n,rules:$r,apply_to:$a}')" | jq -r '.firewall.id')"
  echo "created firewall ${FW_NAME} (id ${fw_id}) and applied to server ${server_id}"
else
  fw_id="$(jq -r '.id' <<<"$fw")"
  hz -X POST "$API/firewalls/${fw_id}/actions/set_rules" -d "$(jq -cn --argjson r "$rules" '{rules:$r}')" >/dev/null
  echo "firewall ${FW_NAME} (id ${fw_id}): rules re-asserted"
  if jq -e --argjson s "$server_id" '.applied_to[]? | select(.type=="server" and .server.id==$s)' <<<"$fw" >/dev/null; then
    echo "already applied to server ${server_id}"
  else
    hz -X POST "$API/firewalls/${fw_id}/actions/apply_to_resources" -d "$(jq -cn --argjson a "$apply_to" '{apply_to:$a}')" >/dev/null
    echo "applied to server ${server_id}"
  fi
fi
echo "verify from outside: nmap -Pn -p 22,80,443,8000,6001,6002,8888,9999 <box-ip>  → only 22/80/443 open"
