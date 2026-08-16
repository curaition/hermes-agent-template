#!/usr/bin/env bash
# Bookkeeping for the hermes-atlas codebase sweep. The QUEUE IS THE FILE, not the
# agent's memory: the agent asks this script what to read next and reports back what
# it produced. Every mutation is validated and lock-guarded here, so a confused run
# can neither corrupt the queue nor mark a module read without evidence.
#
#   atlas.sh next  [--count N] [--repo DIR] [--file TSV]
#   atlas.sh done  MODULE --sha SHA --page SLUG --evidence path:line [--tickets CUR-1,CUR-2]
#   atlas.sh stats [--file TSV]
#
# `next` hands out `pending` modules in queue order (biggest first). Once the lap is
# complete it switches to REVISIT mode: modules whose files have commits since the
# visit that produced their dossier, most-changed first. Silence means the queue is
# clean — nothing new, nothing changed.
set -euo pipefail

FILE="${ATLAS_FILE:-/data/work/atlas/coverage.tsv}"
REPO="${ATLAS_REPO:-/data/work/curaition}"

die() { echo "atlas: $*" >&2; exit 1; }

cmd="${1:-}"; [ -n "$cmd" ] || { sed -n '2,16p' "$0"; exit 2; }
shift || true

COUNT=3 MODULE="" SHA="" PAGE="" EVIDENCE="" TICKETS=""
case "$cmd" in
  done)
    MODULE="${1:-}"
    [ -n "$MODULE" ] || die "done needs a MODULE"
    shift
    ;;
  next|stats|-h|--help) ;;
  *) die "unknown command: $cmd" ;;
esac

while [ $# -gt 0 ]; do
  case "$1" in
    --count)    COUNT="${2:?--count needs a value}"; shift 2 ;;
    --file)     FILE="${2:?--file needs a value}"; shift 2 ;;
    --repo)     REPO="${2:?--repo needs a value}"; shift 2 ;;
    --sha)      SHA="${2:?--sha needs a value}"; shift 2 ;;
    --page)     PAGE="${2:?--page needs a value}"; shift 2 ;;
    --evidence) EVIDENCE="${2:?--evidence needs a value}"; shift 2 ;;
    --tickets)  TICKETS="${2:?--tickets needs a value}"; shift 2 ;;
    -h|--help)  sed -n '2,16p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

case "$cmd" in -h|--help) sed -n '2,16p' "$0"; exit 0 ;; esac
[ -f "$FILE" ] || die "no queue at $FILE — run seed_coverage.sh first"

# Serialize mutations. flock is present on the deployed image; if it is missing we
# still run (one cron job is the only writer) rather than block the sweep on a
# missing utility.
take_lock() {
  command -v flock >/dev/null 2>&1 || return 0
  exec 9>"$FILE.lock"
  flock -w 30 9 || die "could not lock $FILE.lock after 30s"
}

rows() { grep -v '^#' "$FILE" | grep -v '^$' || true; }

cmd_next() {
  case "$COUNT" in ''|*[!0-9]*) die "--count must be a whole number" ;; esac
  [ "$COUNT" -gt 0 ] || die "--count must be > 0"

  local pending
  pending="$(rows | awk -F'\t' -v n="$COUNT" '$2=="pending" { print $1 "\tnew"; if (++c==n) exit }')"
  if [ -n "$pending" ]; then printf '%s\n' "$pending"; return 0; fi

  # Lap complete → revisit only what actually moved. Compare against the SHA the
  # dossier was written at, NOT the visit timestamp: `git log --since` is inclusive
  # at second granularity and silently re-offers a module you just finished.
  [ -d "$REPO/.git" ] || { echo "atlas: lap complete; no repo at $REPO for revisit scan" >&2; return 0; }
  rows | awk -F'\t' '$2=="done" && $3!="-" { print $1 "\t" $3 }' | while IFS=$'\t' read -r mod sha; do
    local n reason
    if git -C "$REPO" cat-file -e "${sha}^{commit}" 2>/dev/null; then
      n="$(git -C "$REPO" rev-list --count "${sha}..HEAD" -- "$mod" 2>/dev/null || echo 0)"
      reason="commits since ${sha}"
    else
      # The dossier's SHA is not in this history (force-push, or a clone reset past
      # it). We cannot know what changed, so the honest answer is: read it again.
      n=1
      reason="dossier SHA ${sha} not in history"
    fi
    [ "${n:-0}" -gt 0 ] && printf '%s\t%s\t%s\n' "$n" "$mod" "$reason"
    true
  done | sort -rn -k1,1 | awk -F'\t' -v n="$COUNT" '{ print $2 "\trevisit(" $1 " " $3 ")"; if (NR==n) exit }'
}

cmd_done() {
  [ -n "$SHA" ]      || die "done needs --sha (the SHA you read the module at)"
  [ -n "$PAGE" ]     || die "done needs --page (the dossier slug you wrote)"
  [ -n "$EVIDENCE" ] || die "done needs --evidence path:line (something you actually read)"
  printf '%s' "$SHA" | grep -Eq '^[0-9a-f]{7,40}$' || die "--sha must be a git SHA, got: $SHA"
  printf '%s' "$EVIDENCE" | grep -Eq '^[^ :]+:[0-9]+$' || die "--evidence must be path:line, got: $EVIDENCE"
  [ -z "$TICKETS" ] || printf '%s' "$TICKETS" | grep -Eq '^CUR-[0-9]+(,CUR-[0-9]+)*$' ||
    die "--tickets must be CUR-nnn[,CUR-nnn], got: $TICKETS"
  rows | cut -f1 | grep -Fxq "$MODULE" || die "module not in queue: $MODULE"

  local now; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local tmp; tmp="$(mktemp)"
  awk -F'\t' -v OFS='\t' -v m="$MODULE" -v sha="$SHA" -v now="$now" -v page="$PAGE" -v tk="$TICKETS" '
    $0 ~ /^#/ || $0 == "" { print; next }
    $1 != m { print; next }
    {
      merged = ($6 == "-" || $6 == "") ? tk : (tk == "" ? $6 : $6 "," tk)
      if (merged == "") merged = "-"
      print $1, "done", sha, now, page, merged
    }
  ' "$FILE" > "$tmp" && mv "$tmp" "$FILE"
  rows | awk -F'\t' -v m="$MODULE" '$1==m'
}

cmd_stats() {
  rows | awk -F'\t' '
    { n++; c[$2]++; if ($2=="done" && $4!="-" && (oldest=="" || $4<oldest)) oldest=$4 }
    END {
      done_n = c["done"] + 0
      printf "modules %d | pending %d | done %d | gone %d | lap %.0f%%\n",
             n, c["pending"]+0, done_n, c["gone"]+0, (n ? 100*done_n/n : 0)
      if (oldest != "") printf "oldest dossier: %s\n", oldest
    }'
}

case "$cmd" in
  next)  cmd_next ;;
  done)  take_lock; cmd_done ;;
  stats) cmd_stats ;;
esac
