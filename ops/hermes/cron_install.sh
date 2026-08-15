#!/usr/bin/env bash
# Create the two Hermes cron jobs, PAUSED (spec D8). Run INSIDE the Hermes container:
#   scp -r ops/hermes/prompts railway-hermes-agent:/data/work/prompts   (or paste)
#   ssh railway-hermes-agent 'PROMPTS_DIR=/data/work/prompts bash -s' < ops/hermes/cron_install.sh
# Unpause when ready: hermes cron resume <id>. Manual run: hermes cron run <id>.
set -euo pipefail
PROMPTS_DIR="${PROMPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/prompts}"
WORKDIR="${WORKDIR:-/data/work/curaition}"
for f in scout.md hygiene.md; do
  [ -s "$PROMPTS_DIR/$f" ] || { echo "missing/empty prompt: $PROMPTS_DIR/$f" >&2; exit 1; }
done
existing="$(hermes cron list 2>/dev/null || true)"
mk() { # mk NAME SCHEDULE PROMPTFILE
  if grep -qE "(^|[^A-Za-z0-9_-])$1([^A-Za-z0-9_-]|$)" <<<"$existing"; then echo "= $1 already exists; skipping"; return; fi
  local out id
  out="$(hermes cron create "$2" "$(cat "$PROMPTS_DIR/$3")" --name "$1" --deliver telegram --workdir "$WORKDIR")"
  echo "$out"
  id="$(sed -n 's/^Created job: *//p' <<<"$out" | head -1)"
  [ -n "$id" ] || { echo "could not parse job id for $1 — job was created but NOT paused (may be LIVE); run: hermes cron list && hermes cron pause <id>" >&2; return 1; }
  hermes cron pause "$id" >/dev/null || { echo "WARNING: $1 created as $id but pause FAILED — job may be LIVE; run: hermes cron pause $id" >&2; return 1; }
  echo "+ $1 created as $id and PAUSED"
}
mk hermes-scout   "0 2 * * 1,3,5" scout.md
mk hermes-hygiene "0 3 * * 0"     hygiene.md
echo "next: hermes cron run <scout-id> for a manual pass; hermes cron resume <id> when trusted."
