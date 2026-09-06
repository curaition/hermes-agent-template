#!/usr/bin/env bash
# Render ops/hermes/prompts/owner.md (or release.md) for one owner: substitutes {{OWNER}},
# {{AREA_LABEL}} and {{MODE}}. Used by cron_install.sh and by the tests.
#   render_owner_prompt.sh <owner> [dry-run|live]      # owner prompt
#   render_owner_prompt.sh release [dry-run|live]      # release prompt
# Owner names and their Linear area labels are the preflight's OWNER_PATHS keys
# (product repo scripts/ops/preflight.py) — the label must EXIST in Linear (never invented).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
owner="${1:?owner name or 'release'}"; mode="${2:-dry-run}"
case "$mode" in dry-run|live) ;; *) echo "mode must be dry-run or live, got: $mode" >&2; exit 2 ;; esac
if [ "$owner" = "release" ]; then
  sed -e "s/{{MODE}}/$mode/g" "$here/prompts/release.md"; exit 0
fi
case "$owner" in
  video_pipeline)       label="video-pipeline" ;;
  ingestion)            label="ingestion" ;;
  patterns)             label="patterns" ;;
  channel_intelligence) label="channel-intel" ;;
  entities)             label="entities" ;;
  newsletter)           label="newsletter" ;;
  web)                  label="web-api" ;;
  admin-dashboard)      label="admin-ui" ;;
  mcp-server)           label="mcp" ;;
  *) echo "unknown owner: $owner (see OWNER_PATHS in scripts/ops/preflight.py)" >&2; exit 2 ;;
esac
sed -e "s/{{OWNER}}/$owner/g" -e "s/{{AREA_LABEL}}/$label/g" -e "s/{{MODE}}/$mode/g" "$here/prompts/owner.md"
