#!/usr/bin/env bash
# Refresh the atlas coverage queue from the repo tree. IDEMPOTENT and non-destructive:
# existing rows keep their status and history, modules new to the tree are appended as
# `pending`, and modules that vanished are marked `gone` (never deleted — their dossier
# slug and ticket history stay readable). Rows are written in LOC-descending order, so
# the queue always walks the biggest modules first.
#
#   seed_coverage.sh [--repo /data/work/curaition] [--file /data/work/atlas/coverage.tsv]
#
# A sweep unit is a directory under src/crypto_newsletter (depth 1-2) holding at least
# one .py file AT THAT LEVEL — a package and its sub-packages are separate units, which
# is what keeps a 21k-LOC tree like core/scheduling from being "one module".
set -euo pipefail

REPO="${ATLAS_REPO:-/data/work/curaition}"
FILE="${ATLAS_FILE:-/data/work/atlas/coverage.tsv}"
HEADER=$'# module\tstatus\tlast_sha\tlast_visit\tdossier\ttickets'

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:?--repo needs a value}"; shift 2 ;;
    --file) FILE="${2:?--file needs a value}"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "seed_coverage.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -d "$REPO/src/crypto_newsletter" ] || {
  echo "seed_coverage.sh: not a curaition checkout: $REPO" >&2; exit 1; }

mkdir -p "$(dirname "$FILE")"
[ -f "$FILE" ] || printf '%s\n' "$HEADER" > "$FILE"

tmpdir="$(mktemp -d)"; trap 'rm -rf "$tmpdir"' EXIT
scan="$tmpdir/scan"; : > "$scan"

while IFS= read -r d; do
  # -maxdepth 1: files directly in this directory, so a parent package is not
  # credited with its children's lines (they are their own units).
  count="$(find "$REPO/$d" -maxdepth 1 -name '*.py' -type f | wc -l | tr -d ' ')"
  [ "$count" -gt 0 ] || continue
  loc="$(find "$REPO/$d" -maxdepth 1 -name '*.py' -type f -exec cat {} + | wc -l | tr -d ' ')"
  printf '%s\t%s\n' "$loc" "$d" >> "$scan"
done < <(cd "$REPO" && find src/crypto_newsletter -mindepth 1 -maxdepth 2 -type d \
           -not -path '*__pycache__*' | LC_ALL=C sort)

sort -rn -k1,1 -o "$scan" "$scan"

merged="$tmpdir/merged"
awk -F'\t' -v OFS='\t' '
  FNR==NR {                                   # pass 1: the existing queue
    if ($0 ~ /^#/ || $0 == "") next
    st[$1]=$2; sha[$1]=$3; vis[$1]=$4; doss[$1]=$5; tick[$1]=$6; known[$1]=1
    next
  }
  {                                           # pass 2: what the tree holds now
    m=$2; live[m]=1
    print m, (m in known ? st[m] : "pending"), (m in known ? sha[m] : "-"), \
             (m in known ? vis[m] : "-"),      (m in known ? doss[m] : "-"), \
             (m in known ? tick[m] : "-")
  }
  END {                                       # rows whose directory is gone
    for (m in known) if (!(m in live)) print m, "gone", sha[m], vis[m], doss[m], tick[m]
  }
' "$FILE" "$scan" > "$merged"

{ printf '%s\n' "$HEADER"; cat "$merged"; } > "$FILE.tmp" && mv "$FILE.tmp" "$FILE"

awk -F'\t' '
  $0 ~ /^#/ || $0 == "" { next }
  { n++; c[$2]++ }
  END { printf "atlas queue: %d modules (pending %d, done %d, gone %d) -> %s\n",
               n, c["pending"], c["done"], c["gone"], FILENAME }
' "$FILE"
