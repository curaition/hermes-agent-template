#!/usr/bin/env bash
# Automated acceptance checks for the Hindsight tier (spec §8, gates 1,2,4,5).
#   BOX_IP=… HINDSIGHT_URL=https://hindsight.<zone> HINDSIGHT_TENANT_API_KEY=… ./verify.sh   [SKIP_NMAP=1]
# shellcheck disable=SC2015  # `A && B || C` used throughout as a pass/fail/warn reporter; B is
# always a plain echo (pass/warn) that cannot fail, so the "C may run when A is true" case is moot.
set -uo pipefail
: "${HINDSIGHT_URL:?}"; : "${HINDSIGHT_TENANT_API_KEY:?}"
URL="${HINDSIGHT_URL%/}"; BANK="hermes-agent"; rc=0
pass() { echo "PASS  $*"; }; fail() { echo "FAIL  $*"; rc=1; }; warn() { echo "WARN  $*"; }
hdr=(-H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream')
auth=(-H "Authorization: Bearer ${HINDSIGHT_TENANT_API_KEY}")
LIST='{"jsonrpc":"2.0","method":"tools/list","id":1}'
unwrap() { local raw; raw="$(cat)"; if grep -q '^data:' <<<"$raw"; then sed -n 's/^data: *//p' <<<"$raw" | tail -1; else printf '%s' "$raw"; fi; }
call() { local a="${2:-}"; [ -n "$a" ] || a='{}'; curl -sS -X POST "${URL}/mcp/${BANK}/" "${hdr[@]}" "${auth[@]}" -d "$(jq -cn --arg t "$1" --argjson a "$a" '{jsonrpc:"2.0",id:1,method:"tools/call",params:{name:$t,arguments:$a}}')" | unwrap | jq -r '.result.content[0].text // empty'; }

# 1. firewall
if [ "${SKIP_NMAP:-0}" = 1 ]; then warn "firewall: nmap skipped"; else
  if [ -z "${BOX_IP:-}" ]; then fail "firewall: BOX_IP unset"; else
    open="$(nmap -Pn -p 22,80,443,8000,6001,6002,8888,9999 "$BOX_IP" 2>/dev/null | awk '/^[0-9]+\/tcp/ && $2=="open" {sub(/\/tcp/,"",$1); print $1}' | sort -n | tr '\n' ' ' | sed 's/ $//')"
    if [ "$open" = "22 80 443" ]; then pass "firewall: only 22/80/443 open"; else fail "firewall: open ports = '${open}' (want '22 80 443')"; fi
  fi
fi
# 2. TLS
case "$URL" in https://*)
  if curl -sS -o /dev/null --max-time 15 "$URL/" ; then pass "tls: certificate valid for $URL"; else fail "tls: handshake/cert failed for $URL"; fi;;
  *) warn "tls: non-https URL, skipped";; esac
# 3. auth gate
c="$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$URL/mcp/" "${hdr[@]}" -d "$LIST")"
[ "$c" = 401 ] && pass "auth: unauthenticated tools/list → 401" || fail "auth: unauthenticated tools/list → $c (want 401)"
c="$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$URL/mcp/" "${hdr[@]}" "${auth[@]}" -d "$LIST")"
[ "$c" = 200 ] && pass "auth: bearer tools/list → 200" || fail "auth: bearer tools/list → $c"
# 4-6. bank shape
b="$(call get_bank)"; if [ -n "$b" ] && ! grep -qi 'no such bank\|not found' <<<"$b"; then pass "bank: ${BANK} exists"; else fail "bank: ${BANK} missing"; fi
n="$(call list_directives | jq -r '(.directives // .items // .)|length' 2>/dev/null || echo 0)"; [ "$n" = 3 ] && pass "directives: 3" || fail "directives: $n (want 3)"
m="$(call list_mental_models)"; mn="$(jq -r '(.mental_models // .items // .)|length' <<<"$m" 2>/dev/null || echo 0)"; [ "$mn" = 2 ] && pass "mental models: 2" || fail "mental models: $mn (want 2)"
# 7. non-empty models (content appears after first refresh/consolidation)
for id in refactor-landscape proposal-outcomes; do
  len="$(call get_mental_model "$(jq -cn --arg id "$id" '{mental_model_id:$id}')" | jq -r '(.content // .observations // "")|tostring|length' 2>/dev/null || echo 0)"
  [ "${len:-0}" -gt 0 ] && pass "mental model $id: non-empty" || warn "mental model $id: empty (expected before first consolidation; re-check after Hermes has retained + consolidated)"
done
# 8. lockdown
tools="$(curl -sS -X POST "$URL/mcp/${BANK}/" "${hdr[@]}" "${auth[@]}" -d "$LIST" | unwrap | jq -r '.result.tools[].name' 2>/dev/null | tr '\n' ' ')"
if grep -qw retain <<<"$tools" && ! grep -qw delete_directive <<<"$tools" && ! grep -qw update_bank <<<"$tools"; then pass "lockdown: bank tool surface has no delete/admin tools"; else fail "lockdown: tool surface = [$tools]"; fi
exit $rc
