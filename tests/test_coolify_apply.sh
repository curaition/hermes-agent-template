#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export PATH="$here/fakebin:$PATH" FAKE_CURL_LOG="$tmp/log" FAKE_CURL_RESPONSES="$tmp/resp"
mkdir -p "$FAKE_CURL_RESPONSES"
export COOLIFY_URL=https://coolify.example COOLIFY_TOKEN=t HINDSIGHT_FQDN=hindsight.example \
  HINDSIGHT_VERSION=1.2.3 HINDSIGHT_DB_PASSWORD=dbpw HINDSIGHT_TENANT_API_KEY=tk \
  GEMINI_API_KEY=g OPENAI_API_KEY=o HINDSIGHT_LLM_MODEL=gemini-3-flash-preview \
  STATE_FILE="$tmp/state.env" POLL_INTERVAL=0
fail() { echo "FAIL: $*" >&2; exit 1; }
R="$FAKE_CURL_RESPONSES"
echo '[{"uuid":"srv1","name":"localhost"}]' > "$R/https___coolify_example_api_v1_servers"
echo '[]' > "$R/https___coolify_example_api_v1_projects"
echo '{"uuid":"proj1"}' > "$R/https___coolify_example_api_v1_projects.POST"
echo '[{"uuid":"env1","name":"production"}]' > "$R/https___coolify_example_api_v1_projects_proj1_environments"
echo '[]' > "$R/https___coolify_example_api_v1_databases"
echo '{"uuid":"db1"}' > "$R/https___coolify_example_api_v1_databases_postgresql.POST"
echo '{"uuid":"db1","status":"running:healthy","internal_db_url":"postgres://hindsight_user:dbpw@db1:5432/hindsight_db"}' > "$R/https___coolify_example_api_v1_databases_db1"
echo '[]' > "$R/https___coolify_example_api_v1_services"
echo '{"uuid":"svc1"}' > "$R/https___coolify_example_api_v1_services.POST"
echo '{"uuid":"svc1","status":"running:healthy"}' > "$R/https___coolify_example_api_v1_services_svc1"
echo '{"uuid":"e"}' > "$R/https___coolify_example_api_v1_services_svc1_envs.POST"

bash "$here/../ops/hindsight/coolify_apply.sh" > "$tmp/out"
grep -q '^POST https://coolify.example/api/v1/projects ' "$FAKE_CURL_LOG" || fail "project create"
dbbody="$(grep '^POST https://coolify.example/api/v1/databases/postgresql ' "$FAKE_CURL_LOG" | cut -d' ' -f3-)"
jq -e '.image=="pgvector/pgvector:pg17" and .postgres_db=="hindsight_db" and .postgres_user=="hindsight_user" and .postgres_password=="dbpw" and .instant_deploy==true and .name=="hindsight-db"' <<<"$dbbody" >/dev/null || fail "db body $dbbody"
svcbody="$(grep '^POST https://coolify.example/api/v1/services ' "$FAKE_CURL_LOG" | cut -d' ' -f3-)"
jq -e '.name=="hindsight" and .instant_deploy==false and .urls==[{"name":"hindsight","url":"https://hindsight.example:8888"}]' <<<"$svcbody" >/dev/null || fail "svc body $svcbody"
# shellcheck disable=SC2016 # intentional: matching the literal, unexpanded ${HINDSIGHT_VERSION} placeholder in the compose file
jq -r '.docker_compose_raw' <<<"$svcbody" | base64 -d | grep -q 'ghcr.io/vectorize-io/hindsight:${HINDSIGHT_VERSION}' || fail "compose not embedded"
grep -q '^PATCH https://coolify.example/api/v1/services/svc1 .*connect_to_docker_network' "$FAKE_CURL_LOG" || fail "predefined network"
for k in HINDSIGHT_VERSION HINDSIGHT_API_DATABASE_URL GEMINI_API_KEY HINDSIGHT_LLM_MODEL HINDSIGHT_TENANT_API_KEY OPENAI_API_KEY; do
  grep -q "^POST https://coolify.example/api/v1/services/svc1/envs .*\"key\":\"$k\"" "$FAKE_CURL_LOG" || fail "env $k"
done
# R1: coolify_apply.sh converts postgres:// -> postgresql:// (Hindsight expects postgresql://)
grep '"key":"HINDSIGHT_API_DATABASE_URL"' "$FAKE_CURL_LOG" | grep -q 'postgresql://hindsight_user:dbpw@db1:5432/hindsight_db' || fail "db url from internal_db_url"
grep -q '^GET https://coolify.example/api/v1/services/svc1/start ' "$FAKE_CURL_LOG" || fail "start"
# shellcheck disable=SC2015 # intentional: fail() exits 1, so C only runs when A or B did not match
grep -q '^SERVICE_UUID=svc1$' "$tmp/state.env" && grep -q '^DB_UUID=db1$' "$tmp/state.env" || fail "state file"

# Re-run: everything exists → no creates, still (re)applies envs + restart not start
echo '[{"uuid":"proj1","name":"hermes-memory"}]' > "$R/https___coolify_example_api_v1_projects"
echo '[{"uuid":"db1","name":"hindsight-db"}]' > "$R/https___coolify_example_api_v1_databases"
echo '[{"uuid":"svc1","name":"hindsight"}]' > "$R/https___coolify_example_api_v1_services"
: > "$FAKE_CURL_LOG"
bash "$here/../ops/hindsight/coolify_apply.sh" >/dev/null
grep -q '^POST https://coolify.example/api/v1/projects ' "$FAKE_CURL_LOG" && fail "re-created project"
grep -q '^POST https://coolify.example/api/v1/databases/postgresql ' "$FAKE_CURL_LOG" && fail "re-created db"
grep -q '^POST https://coolify.example/api/v1/services ' "$FAKE_CURL_LOG" && fail "re-created service"
grep -q '/services/svc1/restart ' "$FAKE_CURL_LOG" || fail "restart on re-run"

# 'latest' refused
if HINDSIGHT_VERSION=latest bash "$here/../ops/hindsight/coolify_apply.sh" >/dev/null 2>&1; then fail "latest accepted"; fi
echo "PASS test_coolify_apply"
