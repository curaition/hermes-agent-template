#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export PATH="$here/fakebin:$PATH" FAKE_CURL_LOG="$tmp/log" FAKE_CURL_RESPONSES="$tmp/resp"
mkdir -p "$FAKE_CURL_RESPONSES"
export HCLOUD_TOKEN=t HCLOUD_SERVER_NAME=box ADMIN_CIDR=203.0.113.7/32
fail() { echo "FAIL: $*" >&2; exit 1; }

# Case 1: server exists, no firewall yet → POST /firewalls with rules + apply_to
echo '{"servers":[{"id":42,"name":"box"}]}' > "$FAKE_CURL_RESPONSES/https___api_hetzner_cloud_v1_servers_name_box"
echo '{"firewalls":[]}' > "$FAKE_CURL_RESPONSES/https___api_hetzner_cloud_v1_firewalls_name_hermes_memory"
echo '{"firewall":{"id":7}}' > "$FAKE_CURL_RESPONSES/https___api_hetzner_cloud_v1_firewalls.POST"
: > "$FAKE_CURL_LOG"
bash "$here/../ops/hindsight/hetzner_firewall.sh" >/dev/null
grep -q '^POST https://api.hetzner.cloud/v1/firewalls ' "$FAKE_CURL_LOG" || fail "no create"
body="$(grep '^POST https://api.hetzner.cloud/v1/firewalls ' "$FAKE_CURL_LOG" | cut -d' ' -f3-)"
echo "$body" | jq -e '.name=="hermes-memory"' >/dev/null || fail "name"
echo "$body" | jq -e '[.rules[]|select(.direction=="in" and .protocol=="tcp")|.port]|sort==["22","443","80"]' >/dev/null || fail "ports $body"
echo "$body" | jq -e '.rules[]|select(.port=="22")|.source_ips==["203.0.113.7/32"]' >/dev/null || fail "ssh cidr"
echo "$body" | jq -e '.rules[]|select(.port=="443")|.source_ips==["0.0.0.0/0","::/0"]' >/dev/null || fail "https any"
echo "$body" | jq -e '.apply_to==[{"type":"server","server":{"id":42}}]' >/dev/null || fail "apply_to"

# Case 2: firewall exists but not applied → set_rules + apply_to_resources
echo '{"firewalls":[{"id":7,"name":"hermes-memory","applied_to":[]}]}' > "$FAKE_CURL_RESPONSES/https___api_hetzner_cloud_v1_firewalls_name_hermes_memory"
: > "$FAKE_CURL_LOG"
bash "$here/../ops/hindsight/hetzner_firewall.sh" >/dev/null
grep -q '^POST https://api.hetzner.cloud/v1/firewalls/7/actions/set_rules ' "$FAKE_CURL_LOG" || fail "no set_rules"
grep -q '^POST https://api.hetzner.cloud/v1/firewalls/7/actions/apply_to_resources ' "$FAKE_CURL_LOG" || fail "no apply"

# Case 3: already applied → set_rules only (idempotent)
echo '{"firewalls":[{"id":7,"name":"hermes-memory","applied_to":[{"type":"server","server":{"id":42}}]}]}' > "$FAKE_CURL_RESPONSES/https___api_hetzner_cloud_v1_firewalls_name_hermes_memory"
: > "$FAKE_CURL_LOG"
bash "$here/../ops/hindsight/hetzner_firewall.sh" >/dev/null
grep -q 'apply_to_resources' "$FAKE_CURL_LOG" && fail "re-applied"

# Case 4: unknown server → non-zero
echo '{"servers":[]}' > "$FAKE_CURL_RESPONSES/https___api_hetzner_cloud_v1_servers_name_box"
if bash "$here/../ops/hindsight/hetzner_firewall.sh" >/dev/null 2>&1; then fail "missing server accepted"; fi
echo "PASS test_hetzner_firewall"
