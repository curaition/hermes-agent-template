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
  "cron pause") echo "paused";;
esac
EOF
chmod +x "$tmp/bin/hermes"; export PATH="$tmp/bin:$PATH" FAKE_HERMES_LOG="$tmp/log" FAKE_HERMES_LIST="$tmp/list"
: > "$FAKE_HERMES_LOG"; : > "$FAKE_HERMES_LIST"
PROMPTS_DIR="$here/../ops/hermes/prompts" bash "$here/../ops/hermes/cron_install.sh" >/dev/null
grep -q '^cron create 0 2 \* \* 1,3,5 .*--name hermes-scout --deliver telegram --workdir /data/work/curaition' "$FAKE_HERMES_LOG" || { echo "FAIL scout create"; cat "$FAKE_HERMES_LOG"; exit 1; }
grep -q '^cron create 0 3 \* \* 0 .*--name hermes-hygiene --deliver telegram --workdir /data/work/curaition' "$FAKE_HERMES_LOG" || { echo "FAIL hygiene create"; exit 1; }
[ "$(grep -c '^cron pause job_' "$FAKE_HERMES_LOG")" = 2 ] || { echo "FAIL pause count"; cat "$FAKE_HERMES_LOG"; exit 1; }
grep -q 'MEMORY TIER UNAVAILABLE' "$FAKE_HERMES_LOG" || { echo "FAIL prompt content not passed"; exit 1; }
# idempotent
printf 'hermes-scout\nhermes-hygiene\n' > "$FAKE_HERMES_LIST"; : > "$FAKE_HERMES_LOG"
PROMPTS_DIR="$here/../ops/hermes/prompts" bash "$here/../ops/hermes/cron_install.sh" >/dev/null
grep -q 'cron create' "$FAKE_HERMES_LOG" && { echo "FAIL not idempotent"; exit 1; }
echo "PASS test_cron_install"
