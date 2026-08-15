#!/usr/bin/env bash
# Runs materialize_hindsight_wiring against a temp DATA_ROOT and asserts outputs.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(mktemp -d)"; trap 'rm -rf "$root"' EXIT
mkdir -p "$root/.hermes"
printf 'memory:\n  provider: ""\nmcp_servers:\n  youcom:\n    url: https://api.you.com/mcp\n' > "$root/.hermes/config.yaml"
touch "$root/.hermes/.env"; echo "GH_TOKEN=abc" >> "$root/.hermes/.env"

export HERMES_HINDSIGHT_CONFIG_JSON
HERMES_HINDSIGHT_CONFIG_JSON="$(printf '{"mode":"local_external","api_url":"https://hindsight.example","bank_id":"hermes-agent","memory_mode":"hybrid","auto_recall":true,"auto_retain":true,"recall_budget":"mid"}' | base64)"
export HINDSIGHT_API_KEY="k1" HINDSIGHT_API_URL="https://hindsight.example" HERMES_MEMORY_PROVIDER="hindsight"
export HERMES_MCP_SERVERS_YAML
HERMES_MCP_SERVERS_YAML="$(printf 'gbrain:\n  url: http://gbrain.railway.internal:3131/mcp\n  tools:\n    include: [query]\n' | base64)"

fail() { echo "FAIL: $*" >&2; exit 1; }

# shellcheck source=../bootstrap/hindsight_wiring.sh
source "$here/../bootstrap/hindsight_wiring.sh"
before="$(umask)"
materialize_hindsight_wiring "$root"
[ "$(umask)" = "$before" ] || fail "umask leaked from materialize_hindsight_wiring"

[ -f "$root/.hermes/hindsight/config.json" ] || fail "config.json missing"
[ "$(stat -c '%a' "$root/.hermes/hindsight/config.json" 2>/dev/null || stat -f '%Lp' "$root/.hermes/hindsight/config.json")" = "600" ] || fail "config.json mode"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["mode"]=="local_external" and d["bank_id"]=="hermes-agent"' "$root/.hermes/hindsight/config.json" || fail "config.json content"
grep -q '^HINDSIGHT_API_KEY=k1$' "$root/.hermes/.env" || fail ".env key"
grep -q '^HINDSIGHT_API_URL=https://hindsight.example$' "$root/.hermes/.env" || fail ".env url"
grep -q '^GH_TOKEN=abc$' "$root/.hermes/.env" || fail ".env preserved"
python3 - "$root/.hermes/config.yaml" <<'PY' || fail "config.yaml"
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
assert d["memory"]["provider"] == "hindsight", d
assert d["mcp_servers"]["gbrain"]["tools"]["include"] == ["query"], d
assert d["mcp_servers"]["youcom"]["url"] == "https://api.you.com/mcp", d
PY

# second run: key rotation upserts, no duplicate lines
export HINDSIGHT_API_KEY="k2"
materialize_hindsight_wiring "$root"
[ "$(grep -c '^HINDSIGHT_API_KEY=' "$root/.hermes/.env")" = "1" ] || fail "duplicate key line"
grep -q '^HINDSIGHT_API_KEY=k2$' "$root/.hermes/.env" || fail "key not rotated"

# third run: rotate with values containing sed/grep metacharacters (&, #, \, ?)
# — must survive verbatim, not be interpreted as a sed replacement or regex.
export HINDSIGHT_API_KEY='sk-a&b#c\d'
export HINDSIGHT_API_URL='https://h.example/mcp?a=1&b=2'
materialize_hindsight_wiring "$root"
[ "$(grep -c '^HINDSIGHT_API_KEY=' "$root/.hermes/.env")" = "1" ] || fail "duplicate key line (metachar rotation)"
[ "$(grep -c '^HINDSIGHT_API_URL=' "$root/.hermes/.env")" = "1" ] || fail "duplicate url line (metachar rotation)"
grep -qF 'HINDSIGHT_API_KEY=sk-a&b#c\d' "$root/.hermes/.env" || fail "key not rotated verbatim (metachars)"
grep -qF 'HINDSIGHT_API_URL=https://h.example/mcp?a=1&b=2' "$root/.hermes/.env" || fail "url not rotated verbatim (metachars)"
grep -q '^GH_TOKEN=abc$' "$root/.hermes/.env" || fail ".env preserved after metachar rotation"
[ "$(stat -c '%a' "$root/.hermes/.env" 2>/dev/null || stat -f '%Lp' "$root/.hermes/.env")" = "600" ] || fail ".env mode"

# invalid JSON must not clobber the existing file
export HERMES_HINDSIGHT_CONFIG_JSON
HERMES_HINDSIGHT_CONFIG_JSON="$(printf 'not json' | base64)"
if materialize_hindsight_wiring "$root" 2>/dev/null; then fail "invalid JSON accepted"; fi
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$root/.hermes/hindsight/config.json" || fail "config.json clobbered"

# config containing the unsubstituted <zone> placeholder must be rejected,
# leaving the previous config.json intact
export HERMES_HINDSIGHT_CONFIG_JSON
HERMES_HINDSIGHT_CONFIG_JSON="$(printf '{"mode":"local_external","api_url":"https://hindsight.<zone>","bank_id":"hermes-agent","memory_mode":"hybrid","auto_recall":true,"auto_retain":true,"recall_budget":"mid"}' | base64)"
if materialize_hindsight_wiring "$root" 2>/dev/null; then fail "<zone> placeholder accepted"; fi
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["api_url"]=="https://hindsight.example", d' "$root/.hermes/hindsight/config.json" || fail "config.json clobbered by <zone> placeholder"

# unset env → no-op, no error
unset HERMES_HINDSIGHT_CONFIG_JSON HINDSIGHT_API_KEY HINDSIGHT_API_URL HERMES_MEMORY_PROVIDER HERMES_MCP_SERVERS_YAML
materialize_hindsight_wiring "$root"

# start.sh must actually wire this in — source it and call it unconditionally
# on every boot, not just leave the function defined and unused.
grep -q '^materialize_hindsight_wiring /data$' "$here/../start.sh" || fail "start.sh does not call materialize_hindsight_wiring /data"
grep -q '^source /app/bootstrap/hindsight_wiring.sh$' "$here/../start.sh" || fail "start.sh does not source hindsight_wiring.sh"

echo "PASS test_hindsight_wiring"
