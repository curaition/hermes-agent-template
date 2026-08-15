#!/usr/bin/env bash
# Daily backup of the Hindsight DB resource to the GCS (S3-interop) storage registered in Coolify.
#   COOLIFY_URL COOLIFY_TOKEN COOLIFY_S3_STORAGE_UUID [STATE_FILE] ./coolify_backup.sh
# Prereq (UI, one-time): Coolify → Storages → + Add: endpoint https://storage.googleapis.com,
# bucket curaition-hermes-backups, region as configured, HMAC key/secret. Copy the storage uuid from the URL.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${COOLIFY_URL:?}"; : "${COOLIFY_TOKEN:?}"; : "${COOLIFY_S3_STORAGE_UUID:?}"
STATE_FILE="${STATE_FILE:-$here/.state.env}"; [ -f "$STATE_FILE" ] || { echo "run coolify_apply.sh first ($STATE_FILE missing)" >&2; exit 1; }
# shellcheck disable=SC1090
. "$STATE_FILE"
API="${COOLIFY_URL%/}/api/v1"
co() { curl -sS --fail-with-body -H "Authorization: Bearer ${COOLIFY_TOKEN}" -H 'Content-Type: application/json' -H 'Accept: application/json' "$@"; }
existing="$(co "$API/databases/${DB_UUID}/backups" 2>/dev/null | jq -r '.[]?|.uuid' | head -1 || true)"
if [ -n "$existing" ]; then echo "backup config already exists (${existing}); leaving as-is"; exit 0; fi
co -X POST "$API/databases/${DB_UUID}/backups" -d "$(jq -cn --arg s "$COOLIFY_S3_STORAGE_UUID" \
  '{frequency:"daily", enabled:true, save_s3:true, s3_storage_uuid:$s, backup_now:true,
    database_backup_retention_amount_locally:2, database_backup_retention_days_s3:30}')"
echo
echo "backup scheduled daily → S3 storage ${COOLIFY_S3_STORAGE_UUID}; a backup_now run was triggered."
echo "PROVE RESTORE (once): download the newest dump from the bucket, then on the box:"
echo "  docker exec -i \$(docker ps -qf name=${DB_UUID}) pg_restore -U hindsight_user -d postgres --create --clean --no-owner --verbose < dump.dmp"
echo "  (restores into a fresh 'hindsight_db' on the same server; or point at a scratch DB with -d)"
