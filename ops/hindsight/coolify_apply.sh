#!/usr/bin/env bash
# Coolify API driver for the Hindsight stack. Idempotent (get-or-create by name).
# Inputs: see ops/hindsight/env.example. Outputs: STATE_FILE (default ops/hindsight/.state.env)
# with SERVICE_UUID / DB_UUID / PROJECT_UUID for coolify_backup.sh and verify.sh.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for v in COOLIFY_URL COOLIFY_TOKEN HINDSIGHT_FQDN HINDSIGHT_VERSION HINDSIGHT_DB_PASSWORD HINDSIGHT_TENANT_API_KEY GEMINI_API_KEY OPENAI_API_KEY; do
  [ -n "${!v:-}" ] || { echo "set $v" >&2; exit 1; }
done
[ "$HINDSIGHT_VERSION" != "latest" ] || { echo "HINDSIGHT_VERSION must be a pinned tag, not 'latest'" >&2; exit 1; }
HINDSIGHT_LLM_MODEL="${HINDSIGHT_LLM_MODEL:-gemini-3-flash-preview}"
STATE_FILE="${STATE_FILE:-$here/.state.env}"
POLL_INTERVAL="${POLL_INTERVAL:-5}"; POLL_MAX="${POLL_MAX:-60}"
API="${COOLIFY_URL%/}/api/v1"
PROJECT_NAME="hermes-memory"; DB_NAME="hindsight-db"; SVC_NAME="hindsight"
DB_USER="hindsight_user"; DB_DBNAME="hindsight_db"

co() { curl -sS --fail-with-body -H "Authorization: Bearer ${COOLIFY_TOKEN}" -H 'Content-Type: application/json' -H 'Accept: application/json' "$@"; }
co_try() { curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${COOLIFY_TOKEN}" -H 'Content-Type: application/json' -H 'Accept: application/json' "$@"; }

# 1. server (single-server Coolify: first entry; override with COOLIFY_SERVER_NAME)
if [ -n "${COOLIFY_SERVER_NAME:-}" ]; then
  server_uuid="$(co "$API/servers" | jq -r --arg n "$COOLIFY_SERVER_NAME" '.[]|select(.name==$n)|.uuid' | head -1)"
else
  server_uuid="$(co "$API/servers" | jq -r '.[0].uuid // empty')"
fi
[ -n "$server_uuid" ] || { echo "no Coolify server found" >&2; exit 1; }

# 2. project + environment
project_uuid="$(co "$API/projects" | jq -r --arg n "$PROJECT_NAME" '.[]?|select(.name==$n)|.uuid' | head -1)"
if [ -z "$project_uuid" ]; then
  project_uuid="$(co -X POST "$API/projects" -d "$(jq -cn --arg n "$PROJECT_NAME" '{name:$n,description:"Hermes agent memory tier (Hindsight)"}')" | jq -r '.uuid')"
  echo "created project ${PROJECT_NAME} (${project_uuid})"
fi
env_uuid="$(co "$API/projects/${project_uuid}/environments" | jq -r '.[]|select(.name=="production")|.uuid' | head -1)"
[ -n "$env_uuid" ] || { echo "project has no 'production' environment" >&2; exit 1; }

# 3. database (first-class Coolify resource → API-managed backups)
db_uuid="$(co "$API/databases" | jq -r --arg n "$DB_NAME" '.[]?|select(.name==$n)|.uuid' | head -1)"
if [ -z "$db_uuid" ]; then
  db_uuid="$(co -X POST "$API/databases/postgresql" -d "$(jq -cn \
      --arg s "$server_uuid" --arg p "$project_uuid" --arg e "$env_uuid" --arg n "$DB_NAME" \
      --arg u "$DB_USER" --arg pw "$HINDSIGHT_DB_PASSWORD" --arg d "$DB_DBNAME" \
      '{server_uuid:$s, project_uuid:$p, environment_uuid:$e, environment_name:"production", name:$n,
        image:"pgvector/pgvector:pg17", postgres_user:$u, postgres_password:$pw, postgres_db:$d,
        is_public:false, instant_deploy:true}')" | jq -r '.uuid')"
  echo "created database ${DB_NAME} (${db_uuid}) — pgvector/pgvector:pg17"
fi
# wait for internal URL + running
db_url=""; i=0
while [ $i -lt "$POLL_MAX" ]; do
  j="$(co "$API/databases/${db_uuid}")"
  db_url="$(jq -r '.internal_db_url // empty' <<<"$j")"
  st="$(jq -r '.status // ""' <<<"$j")"
  if [ -n "$db_url" ] && [[ "$st" == running* ]]; then break; fi
  i=$((i+1)); sleep "$POLL_INTERVAL"
done
[ -n "$db_url" ] || { echo "database ${db_uuid} never reported internal_db_url/running" >&2; exit 1; }
# Hindsight wants postgresql:// ; Coolify reports postgres://
db_url="${db_url/#postgres:\/\//postgresql://}"

# 4. compose service
svc_uuid="$(co "$API/services" | jq -r --arg n "$SVC_NAME" '.[]?|select(.name==$n)|.uuid' | head -1)"
compose_b64="$(base64 < "$here/docker-compose.yaml" | tr -d '\n')"
created_service=0
if [ -z "$svc_uuid" ]; then
  svc_uuid="$(co -X POST "$API/services" -d "$(jq -cn \
      --arg s "$server_uuid" --arg p "$project_uuid" --arg e "$env_uuid" --arg n "$SVC_NAME" \
      --arg c "$compose_b64" --arg url "https://${HINDSIGHT_FQDN}:8888" \
      '{server_uuid:$s, project_uuid:$p, environment_uuid:$e, environment_name:"production", name:$n,
        description:"Hindsight agent memory (API+MCP :8888)", docker_compose_raw:$c, instant_deploy:false,
        urls:[{name:"hindsight", url:$url}]}')" | jq -r '.uuid')"
  created_service=1
  echo "created service ${SVC_NAME} (${svc_uuid}) → https://${HINDSIGHT_FQDN}"
fi
# join the coolify network so the app can reach the DB resource
code="$(co_try -X PATCH "$API/services/${svc_uuid}" -d '{"connect_to_docker_network":true}')"
case "$code" in 2*) echo "connect_to_docker_network=true";;
  *) echo "WARN: PATCH connect_to_docker_network returned $code — toggle 'Connect To Predefined Network' in Coolify UI (Service → Settings) before starting" >&2;; esac

# 5. env vars (create; on conflict update)
set_env() { # set_env KEY VALUE
  local body; body="$(jq -cn --arg k "$1" --arg v "$2" '{key:$k, value:$v, is_preview:false, is_literal:true, is_multiline:false, is_shown_once:false}')"
  local c; c="$(co_try -X POST "$API/services/${svc_uuid}/envs" -d "$body")"
  case "$c" in 2*) ;;
    409|422|400) co -X PATCH "$API/services/${svc_uuid}/envs" -d "$body" >/dev/null;;
    *) echo "env $1: HTTP $c" >&2; return 1;; esac
}
set_env HINDSIGHT_VERSION "$HINDSIGHT_VERSION"
set_env HINDSIGHT_API_DATABASE_URL "$db_url"
set_env GEMINI_API_KEY "$GEMINI_API_KEY"
set_env HINDSIGHT_LLM_MODEL "$HINDSIGHT_LLM_MODEL"
set_env HINDSIGHT_TENANT_API_KEY "$HINDSIGHT_TENANT_API_KEY"
set_env OPENAI_API_KEY "$OPENAI_API_KEY"

# 6. start / restart, then poll
if [ "$created_service" = 1 ]; then co "$API/services/${svc_uuid}/start" >/dev/null; else co "$API/services/${svc_uuid}/restart" >/dev/null; fi
i=0; st=""
while [ $i -lt "$POLL_MAX" ]; do
  st="$(co "$API/services/${svc_uuid}" | jq -r '.status // ""')"
  [[ "$st" == running* ]] && break
  i=$((i+1)); sleep "$POLL_INTERVAL"
done
echo "service status: ${st:-unknown}"

printf 'PROJECT_UUID=%s\nDB_UUID=%s\nSERVICE_UUID=%s\nHINDSIGHT_URL=https://%s\n' "$project_uuid" "$db_uuid" "$svc_uuid" "$HINDSIGHT_FQDN" > "$STATE_FILE"
echo "state → $STATE_FILE"
echo "next: ops/hindsight/verify.sh (auth gate) then bootstrap_hindsight.sh"
