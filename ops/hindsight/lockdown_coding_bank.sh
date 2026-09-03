#!/usr/bin/env bash
# Apply a READ-ONLY `mcp_enabled_tools` allowlist to the codebase-rationale bank.
#   HINDSIGHT_URL=https://hindsight.<zone> HINDSIGHT_TENANT_API_KEY=... ./lockdown_coding_bank.sh [--dry-run]
#
# WHY THIS EXISTS. `coding-agent::curaition` is created by the Claude Code integration
# (@vectorize-io/hindsight-coding-agents), which does NOT set mcp_enabled_tools. Measured
# 2026-09-03 on Hindsight 0.9.1: the bank's /mcp/ endpoint exposed 29 tools including
# delete_bank, clear_memories, delete_document, delete_directive, delete_mental_model and
# update_bank, where `hermes-agent` exposed 15 and no destructive surface. The tenant bearer
# is shared (it is already on Railway as HINDSIGHT_API_KEY), so a client-side allowlist in
# mcp_servers.yaml is a filter, not a boundary. This closes it server-side — the same
# principle RUNBOOK §6.2 states for GBrain.
#
# Read-ONLY, deliberately: Hermes must never `retain` into this bank. Its inferences would
# consolidate into observations and be read back as codebase fact. Claude Code is the only
# writer; it writes over REST (the local plugin MCP server hits /v1/..., not /mcp/), so this
# lockdown does not affect it. Verify that after running: a Claude Code session in the repo
# should still show its bank banner and `hindsight_sync_status` should still answer.
set -euo pipefail
: "${HINDSIGHT_URL:?set HINDSIGHT_URL}"; : "${HINDSIGHT_TENANT_API_KEY:?set HINDSIGHT_TENANT_API_KEY}"
BANK="${BANK:-coding-agent::curaition}"
DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1
URL="${HINDSIGHT_URL%/}"

# Read-only surface. No retain/sync_retain (Hermes must not write here) and nothing that
# creates, updates, deletes or clears. Superset of the mcp_servers.yaml include list, so the
# client filter stays meaningful while this is the hard ceiling.
READONLY_TOOLS='["recall","reflect","list_memories","get_memory","list_mental_models","get_mental_model","list_directives","list_tags","get_bank","list_documents","get_document"]'

# Hindsight's MCP endpoint is stateful Streamable HTTP: `initialize` mints an Mcp-Session-Id
# that every later request on that path must carry, else 400 "Missing session ID". Responses
# are SSE-framed, so the last `data:` line is the payload. (Same handling as
# bootstrap_hindsight.sh; see that script's note, verified live on 0.9.1.)
_INIT='{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"lockdown_coding_bank.sh","version":"1"}}}'
_SID=""
_sid() {
  if [ -z "$_SID" ]; then
    _SID="$(curl -sS -D - -o /dev/null -X POST "${URL}/mcp/${BANK}/" \
      -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
      -H "Authorization: Bearer ${HINDSIGHT_TENANT_API_KEY}" -d "$_INIT" \
      | awk 'tolower($1)=="mcp-session-id:"{print $2}' | tr -d '\r')"
    [ -n "$_SID" ] || { echo "initialize on /mcp/${BANK}/ returned no Mcp-Session-Id" >&2; return 1; }
    curl -sS -o /dev/null -X POST "${URL}/mcp/${BANK}/" \
      -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
      -H "Authorization: Bearer ${HINDSIGHT_TENANT_API_KEY}" -H "Mcp-Session-Id: ${_SID}" \
      -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  fi
  echo "$_SID"
}
_rpc() { # _rpc METHOD PARAMS_JSON → last SSE data line
  local sid; sid="$(_sid)"
  curl -sS -X POST "${URL}/mcp/${BANK}/" \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -H "Authorization: Bearer ${HINDSIGHT_TENANT_API_KEY}" -H "Mcp-Session-Id: ${sid}" \
    -d "$(jq -cn --arg m "$1" --argjson p "$2" '{jsonrpc:"2.0",id:1,method:$m,params:$p}')" \
    | grep '^data:' | tail -1 | sed 's/^data: //'
}
_tools() { _rpc tools/list '{}' | jq -r '.result.tools[].name' | sort; }

# --- auth gate first (same rule as bootstrap_hindsight.sh): an endpoint that answers
# --- unauthenticated is an open memory bank on the public internet.
code="$(curl -sS -o /dev/null -w '%{http_code}' -X POST "${URL}/mcp/${BANK}/" \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -d "$_INIT")"
[ "$code" = 401 ] || { echo "ABORT: unauthenticated initialize returned HTTP $code, want 401" >&2; exit 1; }
echo "auth gate: unauthenticated → 401 ok"

echo "== before =="; _tools | tr '\n' ' '; echo
if [ "$DRY" = 1 ]; then
  echo "(dry run) would set mcp_enabled_tools to:"; jq -r '.[]' <<<"$READONLY_TOOLS" | tr '\n' ' '; echo
  exit 0
fi

_rpc tools/call "$(jq -cn --argjson t "$READONLY_TOOLS" \
  '{name:"update_bank",arguments:{config_updates:{mcp_enabled_tools:$t}}}')" >/dev/null

# Read the live surface back and require an exact match — a silently-ignored update is the
# failure mode that matters here, and update_bank is itself excluded by the new allowlist,
# so this script cannot re-run to fix a partial apply (edit via REST:
# PATCH $URL/v1/default/banks/<bank>/config {"updates":{...}} with bearer auth).
_SID=""   # tool surface changed: take a fresh session
echo "== after =="; got="$(_tools)"; echo "$got" | tr '\n' ' '; echo
want="$(jq -r '.[]' <<<"$READONLY_TOOLS" | sort)"
if [ "$got" = "$want" ]; then
  echo "lockdown verified: $(wc -l <<<"$want" | tr -d ' ') read-only tools on ${BANK}"
else
  echo "MISMATCH — live surface is not the allowlist" >&2
  diff <(echo "$want") <(echo "$got") >&2 || true
  exit 1
fi
