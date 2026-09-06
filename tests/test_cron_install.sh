#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"; cat > "$tmp/bin/hermes" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" | tr '\n' ' ' >> "$FAKE_HERMES_LOG"; echo >> "$FAKE_HERMES_LOG"
case "$1 $2" in
  # The real CLI hides PAUSED jobs unless --all is passed. FAKE_HERMES_LIST is the
  # full roster (--all); FAKE_HERMES_LIST_ACTIVE is the active-only subset.
  "cron list") if [ "${3:-}" = "--all" ]; then cat "${FAKE_HERMES_LIST:-/dev/null}"; else cat "${FAKE_HERMES_LIST_ACTIVE:-/dev/null}"; fi;;
  "cron create") n=$(( $(wc -l < "$FAKE_HERMES_LOG") )); echo "Created job: job_$n"; echo "  Name: x";;
  "cron pause") if [ "${FAKE_HERMES_PAUSE_FAIL:-0}" = "1" ]; then exit 7; fi; echo "paused";;
esac
EOF
chmod +x "$tmp/bin/hermes"; export PATH="$tmp/bin:$PATH" FAKE_HERMES_LOG="$tmp/log" \
  FAKE_HERMES_LIST="$tmp/list" FAKE_HERMES_LIST_ACTIVE="$tmp/list_active"
: > "$FAKE_HERMES_LOG"; : > "$FAKE_HERMES_LIST"; : > "$FAKE_HERMES_LIST_ACTIVE"
PROMPTS_DIR="$here/../ops/hermes/prompts" bash "$here/../ops/hermes/cron_install.sh" >/dev/null
grep -q '^cron create 0 2 \* \* 1,3,5 .*--name hermes-scout --deliver telegram --workdir /data/work/curaition' "$FAKE_HERMES_LOG" || { echo "FAIL scout create"; cat "$FAKE_HERMES_LOG"; exit 1; }
grep -q '^cron create 0 3 \* \* 0 .*--name hermes-hygiene --deliver telegram --workdir /data/work/curaition' "$FAKE_HERMES_LOG" || { echo "FAIL hygiene create"; exit 1; }
grep -q '^cron create 0 4 \* \* \* .*--name hermes-atlas --deliver telegram --workdir /data/work/curaition' "$FAKE_HERMES_LOG" || { echo "FAIL atlas create"; cat "$FAKE_HERMES_LOG"; exit 1; }
grep -q '^cron create 0 6,18 \* \* \* .*--name hermes-implement --deliver telegram --workdir /data/work/curaition' "$FAKE_HERMES_LOG" || { echo "FAIL implement create"; cat "$FAKE_HERMES_LOG"; exit 1; }
# owner swarm Step 1: two pilot owners (rendered per owner, dry-run, continuity, workdir) + release (no workdir)
# shellcheck disable=SC2016  # the backticks are literal prompt text, not expansions
grep -q '^cron create 0 0 \* \* \* You are the CurAItion package OWNER for `patterns`.*Mode for this run: \*\*dry-run\*\*.*--name hermes-owner-patterns --deliver telegram --continuity --workdir /data/work/curaition' "$FAKE_HERMES_LOG" || { echo "FAIL owner-patterns create"; cat "$FAKE_HERMES_LOG"; exit 1; }
# shellcheck disable=SC2016
grep -q '^cron create 0 1 \* \* \* You are the CurAItion package OWNER for `video_pipeline`.*labels `hermes` + `video-pipeline`.*--name hermes-owner-video_pipeline --deliver telegram --continuity --workdir /data/work/curaition' "$FAKE_HERMES_LOG" || { echo "FAIL owner-video_pipeline create"; cat "$FAKE_HERMES_LOG"; exit 1; }
# shellcheck disable=SC2016
grep -q '^cron create 0 9-17 \* \* \* You are the CurAItion RELEASE cron.*Mode for this run: \*\*dry-run\*\*.*--name hermes-release --deliver telegram --continuity $' "$FAKE_HERMES_LOG" || { echo "FAIL release create (must have no --workdir)"; cat "$FAKE_HERMES_LOG"; exit 1; }
grep -q '{{' "$FAKE_HERMES_LOG" && { echo "FAIL unrendered placeholder reached hermes"; exit 1; }
[ "$(grep -c '^cron pause job_' "$FAKE_HERMES_LOG")" = 7 ] || { echo "FAIL pause count"; cat "$FAKE_HERMES_LOG"; exit 1; }
grep -q 'atlas.sh next --count 5' "$FAKE_HERMES_LOG" || { echo "FAIL atlas prompt not passed"; exit 1; }
grep -q 'MEMORY TIER UNAVAILABLE' "$FAKE_HERMES_LOG" || { echo "FAIL prompt content not passed"; exit 1; }
# idempotent — jobs already present and ACTIVE
printf 'hermes-scout\nhermes-hygiene\nhermes-atlas\nhermes-implement\nhermes-owner-patterns\nhermes-owner-video_pipeline\nhermes-release\n' | tee "$FAKE_HERMES_LIST" > "$FAKE_HERMES_LIST_ACTIVE"; : > "$FAKE_HERMES_LOG"
PROMPTS_DIR="$here/../ops/hermes/prompts" bash "$here/../ops/hermes/cron_install.sh" >/dev/null
grep -q 'cron create' "$FAKE_HERMES_LOG" && { echo "FAIL not idempotent"; exit 1; }

# the guard must see PAUSED jobs too: every job this installer creates is paused, so a
# guard reading the active-only list re-creates all three on the next run
printf 'hermes-scout\nhermes-hygiene\nhermes-atlas\nhermes-implement\nhermes-owner-patterns\nhermes-owner-video_pipeline\nhermes-release\n' > "$FAKE_HERMES_LIST"; : > "$FAKE_HERMES_LIST_ACTIVE"; : > "$FAKE_HERMES_LOG"
PROMPTS_DIR="$here/../ops/hermes/prompts" bash "$here/../ops/hermes/cron_install.sh" >/dev/null
grep -q '^cron list --all' "$FAKE_HERMES_LOG" || { echo "FAIL guard did not query --all"; cat "$FAKE_HERMES_LOG"; exit 1; }
[ "$(grep -c '^cron create' "$FAKE_HERMES_LOG")" = 0 ] || { echo "FAIL duplicated paused jobs"; cat "$FAKE_HERMES_LOG"; exit 1; }

# idempotency must be an exact-name (token) match, not a substring
printf 'hermes-scout-old\n' > "$FAKE_HERMES_LIST"; : > "$FAKE_HERMES_LOG"
PROMPTS_DIR="$here/../ops/hermes/prompts" bash "$here/../ops/hermes/cron_install.sh" >/dev/null
[ "$(grep -c '^cron create' "$FAKE_HERMES_LOG")" = 7 ] || { echo "FAIL substring-match idempotency false positive"; cat "$FAKE_HERMES_LOG"; exit 1; }

# pause failure must abort loudly, not silently succeed
: > "$FAKE_HERMES_LIST"; : > "$FAKE_HERMES_LOG"
err="$tmp/err"
set +e
FAKE_HERMES_PAUSE_FAIL=1 PROMPTS_DIR="$here/../ops/hermes/prompts" bash "$here/../ops/hermes/cron_install.sh" >/dev/null 2>"$err"
rc=$?
set -e
[ "$rc" != 0 ] || { echo "FAIL pause failure did not abort installer"; exit 1; }
grep -q 'pause FAILED' "$err" || { echo "FAIL pause failure warning not on stderr"; cat "$err"; exit 1; }

# missing/empty prompts must be validated BEFORE any job is created
empty_prompts="$tmp/empty_prompts"; mkdir -p "$empty_prompts"
: > "$FAKE_HERMES_LIST"; : > "$FAKE_HERMES_LOG"
err2="$tmp/err2"
set +e
PROMPTS_DIR="$empty_prompts" bash "$here/../ops/hermes/cron_install.sh" >/dev/null 2>"$err2"
rc=$?
set -e
[ "$rc" != 0 ] || { echo "FAIL empty prompts dir did not abort installer"; exit 1; }
grep -q 'missing/empty prompt' "$err2" || { echo "FAIL missing/empty prompt message not on stderr"; cat "$err2"; exit 1; }
[ "$(grep -c '^cron create' "$FAKE_HERMES_LOG")" = 0 ] || { echo "FAIL cron create ran despite missing prompts"; cat "$FAKE_HERMES_LOG"; exit 1; }

echo "PASS test_cron_install"
