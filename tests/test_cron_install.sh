#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"; cat > "$tmp/bin/hermes" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" | tr '\n' ' ' >> "$FAKE_HERMES_LOG"; echo >> "$FAKE_HERMES_LOG"
case "$1 $2" in
  "cron list") cat "${FAKE_HERMES_LIST:-/dev/null}";;
  "cron create") n=$(( $(wc -l < "$FAKE_HERMES_LOG") )); echo "Created job: job_$n"; echo "  Name: x";;
  "cron pause") if [ "${FAKE_HERMES_PAUSE_FAIL:-0}" = "1" ]; then exit 7; fi; echo "paused";;
esac
EOF
chmod +x "$tmp/bin/hermes"; export PATH="$tmp/bin:$PATH" FAKE_HERMES_LOG="$tmp/log" FAKE_HERMES_LIST="$tmp/list"
: > "$FAKE_HERMES_LOG"; : > "$FAKE_HERMES_LIST"
PROMPTS_DIR="$here/../ops/hermes/prompts" bash "$here/../ops/hermes/cron_install.sh" >/dev/null
grep -q '^cron create 0 2 \* \* 1,3,5 .*--name hermes-scout --deliver telegram --workdir /data/work/curaition' "$FAKE_HERMES_LOG" || { echo "FAIL scout create"; cat "$FAKE_HERMES_LOG"; exit 1; }
grep -q '^cron create 0 3 \* \* 0 .*--name hermes-hygiene --deliver telegram --workdir /data/work/curaition' "$FAKE_HERMES_LOG" || { echo "FAIL hygiene create"; exit 1; }
grep -q '^cron create 0 4 \* \* \* .*--name hermes-atlas --deliver telegram --workdir /data/work/curaition' "$FAKE_HERMES_LOG" || { echo "FAIL atlas create"; cat "$FAKE_HERMES_LOG"; exit 1; }
[ "$(grep -c '^cron pause job_' "$FAKE_HERMES_LOG")" = 3 ] || { echo "FAIL pause count"; cat "$FAKE_HERMES_LOG"; exit 1; }
grep -q 'atlas.sh next --count 3' "$FAKE_HERMES_LOG" || { echo "FAIL atlas prompt not passed"; exit 1; }
grep -q 'MEMORY TIER UNAVAILABLE' "$FAKE_HERMES_LOG" || { echo "FAIL prompt content not passed"; exit 1; }
# idempotent
printf 'hermes-scout\nhermes-hygiene\nhermes-atlas\n' > "$FAKE_HERMES_LIST"; : > "$FAKE_HERMES_LOG"
PROMPTS_DIR="$here/../ops/hermes/prompts" bash "$here/../ops/hermes/cron_install.sh" >/dev/null
grep -q 'cron create' "$FAKE_HERMES_LOG" && { echo "FAIL not idempotent"; exit 1; }

# idempotency must be an exact-name (token) match, not a substring
printf 'hermes-scout-old\n' > "$FAKE_HERMES_LIST"; : > "$FAKE_HERMES_LOG"
PROMPTS_DIR="$here/../ops/hermes/prompts" bash "$here/../ops/hermes/cron_install.sh" >/dev/null
[ "$(grep -c '^cron create' "$FAKE_HERMES_LOG")" = 3 ] || { echo "FAIL substring-match idempotency false positive"; cat "$FAKE_HERMES_LOG"; exit 1; }

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
