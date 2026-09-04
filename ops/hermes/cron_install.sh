#!/usr/bin/env bash
# Create the four Hermes cron jobs, PAUSED (spec D8). Run INSIDE the Hermes container:
#   scp -r ops/hermes/prompts railway-hermes-agent:/data/work/prompts   (or paste)
#   ssh railway-hermes-agent 'PROMPTS_DIR=/data/work/prompts bash -s' < ops/hermes/cron_install.sh
# Unpause when ready: hermes cron resume <id>. Manual run: hermes cron run <id>.
set -euo pipefail
PROMPTS_DIR="${PROMPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/prompts}"
WORKDIR="${WORKDIR:-/data/work/curaition}"
for f in scout.md hygiene.md atlas.md implement.md; do
  [ -s "$PROMPTS_DIR/$f" ] || { echo "missing/empty prompt: $PROMPTS_DIR/$f" >&2; exit 1; }
done
# --all is load-bearing: `hermes cron list` shows ACTIVE jobs only, and every job this
# script creates is paused immediately after creation. Without it the duplicate guard
# is blind to exactly the jobs it installed, and a re-run silently creates a second
# copy of each (verified on the live box 2026-08-16).
existing="$(hermes cron list --all 2>/dev/null || true)"
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
# atlas walks the module queue daily at 04:00 UTC (after the 02:00 scout, off-peak);
# 3 modules/run covers the 90-unit tree in ~30 days, then flips to revisit mode.
mk hermes-atlas   "0 4 * * *"     atlas.md
# implement pushes branches for Size S issues (06:00/18:00 UTC); captured from the live
# job store 2026-09-04 after drifting ahead of the repo (CUR-1515 follow-up). Created
# PAUSED like the others - a human unpauses it on a fresh box.
mk hermes-implement "0 6,18 * * *" implement.md
echo "next: hermes cron run <scout-id> for a manual pass; hermes cron resume <id> when trusted."
