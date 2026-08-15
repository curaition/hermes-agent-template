#!/usr/bin/env bash
# Bootstrap the `hermes-agent` Hindsight bank over the MCP JSON-RPC surface.
#   HINDSIGHT_URL=https://hindsight.<zone> HINDSIGHT_TENANT_API_KEY=... ./bootstrap_hindsight.sh [--lockdown]
# - Aborts unless an UNauthenticated tools/list returns 401 (auth gate first).
# - Idempotent: create_bank is get-or-create; directives/mental models are skipped if present.
# - --lockdown (run LAST, once verified in the UI): sets mcp_enabled_tools to the read/write-only
#   allowlist. After that this script's seeding calls are refused by design; admin edits go via REST:
#   PATCH $HINDSIGHT_URL/v1/default/banks/hermes-agent/config  {"updates": {...}}  (bearer auth).
set -euo pipefail
: "${HINDSIGHT_URL:?set HINDSIGHT_URL}"; : "${HINDSIGHT_TENANT_API_KEY:?set HINDSIGHT_TENANT_API_KEY}"
BANK="hermes-agent"; LOCKDOWN=0
[ "${1:-}" = "--lockdown" ] && LOCKDOWN=1
URL="${HINDSIGHT_URL%/}"

_post() { # _post PATH JSON [auth]
  local path="$1" body="$2" auth="${3:-1}"; local -a hdr=(-H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream')
  [ "$auth" = 1 ] && hdr+=(-H "Authorization: Bearer ${HINDSIGHT_TENANT_API_KEY}")
  curl -sS -X POST "${URL}${path}" "${hdr[@]}" -d "$body"
}
_status() { local path="$1" body="$2" auth="${3:-1}"; local -a hdr=(-H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream')
  [ "$auth" = 1 ] && hdr+=(-H "Authorization: Bearer ${HINDSIGHT_TENANT_API_KEY}")
  curl -sS -o /dev/null -w '%{http_code}' -X POST "${URL}${path}" "${hdr[@]}" -d "$body"; }
_unwrap() { # stdin: JSON or SSE → the JSON-RPC message
  local raw; raw="$(cat)"
  if printf '%s' "$raw" | grep -q '^data:'; then printf '%s' "$raw" | sed -n 's/^data: *//p' | tail -1; else printf '%s' "$raw"; fi
}
mcp() { # mcp PATH TOOL JSON-ARGS → prints tool result text (JSON); non-zero on JSON-RPC error
  local resp; resp="$(_post "$1" "$(jq -cn --arg t "$2" --argjson a "$3" '{jsonrpc:"2.0",id:1,method:"tools/call",params:{name:$t,arguments:$a}}')" | _unwrap)"
  if jq -e '.error' <<<"$resp" >/dev/null 2>&1; then echo "MCP error calling $2: $(jq -c '.error' <<<"$resp")" >&2; return 1; fi
  jq -r '.result.content[0].text // (.result|tostring)' <<<"$resp"
}
LIST='{"jsonrpc":"2.0","method":"tools/list","id":1}'

echo "== auth gate =="
c="$(_status /mcp/ "$LIST" 0)"; [ "$c" = 401 ] || { echo "UNauthenticated tools/list returned $c, expected 401 — auth is NOT enforced; refusing to continue" >&2; exit 1; }
c="$(_status /mcp/ "$LIST" 1)"; [ "$c" = 200 ] || { echo "authenticated tools/list returned $c" >&2; exit 1; }
echo "401 without bearer, 200 with — OK"

echo "== bank =="
mcp /mcp/ create_bank "$(jq -cn --arg id "$BANK" '{bank_id:$id, name:"Hermes Agent Memory",
  mission:"You are the working memory of an autonomous analysis agent that scouts the CurAItion codebase and files Linear issues for others to implement. Remember experiences: what was proposed, what happened to it, review feedback, and lessons learned. You are NOT a codebase knowledge base — that lives in GBrain."}')" >/dev/null
echo "bank ${BANK} present"

echo "== bank config =="
mcp "/mcp/${BANK}/" update_bank '{"config_updates":{
  "retain_mission":"Extract run learnings, proposal outcomes, human feedback, and surprises about process. Do not extract or restate codebase documentation, code contents, or secrets.",
  "disposition_skepticism":4}}' >/dev/null
echo "retain_mission + skepticism=4"

echo "== directives (skip existing) =="
have="$(mcp "/mcp/${BANK}/" list_directives '{}' | jq -r '(.directives // .items // .)[]?.name')"
add_directive() { # name content priority
  if grep -qx "$1" <<<"$have"; then echo "  = $1"; return; fi
  mcp "/mcp/${BANK}/" create_directive "$(jq -cn --arg n "$1" --arg c "$2" --argjson p "$3" '{name:$n,content:$c,priority:$p}')" >/dev/null; echo "  + $1"
}
add_directive no-relitigating-rejections "Never re-propose a candidate that was previously rejected unless the cited code has materially changed since the rejection; when it has, say so explicitly and cite the new SHA." 100
add_directive human-driver-areas "Celery task signatures and beat schedule, database schema and migrations, billing/Stripe paths, and the video pipeline time-limit machinery are [NEEDS HUMAN DRIVER]: analysis and problem statements only, never implementation proposals." 95
add_directive feedback-over-priors "When human review feedback conflicts with your own assessment of a proposal, weight the feedback above your priors and record the delta as a learning." 90

echo "== mental models (tags_match any — tagged models default to all_strict and come back EMPTY) =="
havem="$(mcp "/mcp/${BANK}/" list_mental_models '{}' | jq -r '(.mental_models // .items // .)[]?.mental_model_id // empty')"
add_model() { # id name query tags-json
  if grep -qx "$1" <<<"$havem"; then echo "  = $1"; return; fi
  mcp "/mcp/${BANK}/" create_mental_model "$(jq -cn --arg id "$1" --arg n "$2" --arg q "$3" --argjson t "$4" \
    '{mental_model_id:$id,name:$n,source_query:$q,tags:$t,tags_match:"any",trigger_refresh_after_consolidation:true}')" >/dev/null; echo "  + $1"
}
add_model refactor-landscape "Refactor Landscape" "What areas of the codebase have open proposals, recent findings, or known technical debt, and what is the current status of each?" '["proposals","findings"]'
add_model proposal-outcomes "Proposal Outcomes" "Which proposals were implemented, which were rejected or went stale, and what patterns distinguish accepted proposals from rejected ones?" '["proposals","feedback"]'

if [ "$LOCKDOWN" = 1 ]; then
  echo "== LOCKDOWN: restricting the bank's MCP tool surface (Hermes accrues memory; humans manage the bank) =="
  mcp "/mcp/${BANK}/" update_bank '{"config_updates":{"mcp_enabled_tools":["retain","sync_retain","recall","reflect","list_memories","get_memory","list_mental_models","get_mental_model","list_directives","list_tags","get_bank","list_documents","get_document","list_operations","get_operation"]}}' >/dev/null
  echo "done. Further admin via REST: PATCH ${URL}/v1/default/banks/${BANK}/config"
else
  echo "seeded (no lockdown). Verify in the control-plane UI (SSH tunnel to :9999), then re-run with --lockdown."
fi
