#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
port=$(( 20000 + RANDOM % 20000 ))
python3 "$here/fake_hindsight_server.py" "$port" & srv=$!; trap 'kill $srv 2>/dev/null' EXIT
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$port/__state" && break; sleep 0.1; done
export HINDSIGHT_URL="http://127.0.0.1:$port" HINDSIGHT_TENANT_API_KEY=tk
fail() { echo "FAIL: $*" >&2; exit 1; }
S="$here/../ops/hindsight/bootstrap_hindsight.sh"
state() { curl -s "http://127.0.0.1:$port/__state"; }

bash "$S" >/dev/null || fail "first run failed"
state | jq -e '.banks["hermes-agent"].directives|length==3' >/dev/null || fail "3 directives"
state | jq -e '.banks["hermes-agent"].mental_models|length==2 and all(.[]; .trigger.tags_match=="any")' >/dev/null || fail "2 models any"
state | jq -e '.banks["hermes-agent"].config.disposition_skepticism==4 and (.banks["hermes-agent"].config.retain_mission|length>20)' >/dev/null || fail "config"
state | jq -e '.banks["hermes-agent"].config.mcp_enabled_tools==null' >/dev/null || fail "locked down without flag"

bash "$S" >/dev/null || fail "second run failed"
state | jq -e '.banks["hermes-agent"].directives|length==3' >/dev/null || fail "idempotent directives"
state | jq -e '.banks["hermes-agent"].mental_models|length==2' >/dev/null || fail "idempotent models"

lockdown_out="$(bash "$S" --lockdown)" || fail "lockdown run failed"
printf '%s\n' "$lockdown_out" | grep -q 'lockdown verified' || fail "lockdown verify banner missing"
state | jq -e '.banks["hermes-agent"].config.mcp_enabled_tools|index("retain")!=null and index("delete_directive")==null and index("update_bank")==null' >/dev/null || fail "allowlist"

# after lockdown, seeding tools are gone: a plain re-run must fail loudly, not silently
if bash "$S" >/dev/null 2>&1; then fail "post-lockdown seed should fail"; fi

# SSE coverage: a second fake server that speaks event-stream for its 200 JSON-RPC responses,
# exercising bootstrap_hindsight.sh's _unwrap SSE branch (untested by the first server, which
# only ever emits plain JSON).
port2=$(( 40000 + RANDOM % 20000 ))
FAKE_HINDSIGHT_SSE=1 python3 "$here/fake_hindsight_server.py" "$port2" & srv2=$!
trap 'kill $srv 2>/dev/null; kill $srv2 2>/dev/null' EXIT
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$port2/__state" && break; sleep 0.1; done
export HINDSIGHT_URL="http://127.0.0.1:$port2"
state2() { curl -s "http://127.0.0.1:$port2/__state"; }

bash "$S" >/dev/null || fail "sse: first run failed"
bash "$S" --lockdown >/dev/null || fail "sse: lockdown run failed"
state2 | jq -e '.banks["hermes-agent"].directives|length==3' >/dev/null || fail "sse: 3 directives"
state2 | jq -e '.banks["hermes-agent"].mental_models|length==2' >/dev/null || fail "sse: 2 mental models"
state2 | jq -e '.banks["hermes-agent"].config.mcp_enabled_tools!=null' >/dev/null || fail "sse: mcp_enabled_tools set"

# auth gate: a server that does not 401 → abort before doing anything
export HINDSIGHT_URL="http://127.0.0.1:$port/nope"   # 404 path → not 401
if bash "$S" >/dev/null 2>&1; then fail "auth gate did not abort"; fi
echo "PASS test_bootstrap_hindsight"
