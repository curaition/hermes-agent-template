#!/usr/bin/env bash
# Behavioural tests for the atlas coverage queue: seeding, idempotent merge, the
# handout order, the evidence gate on `done`, and revisit mode after a full lap.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEED="$here/../bootstrap/atlas/seed_coverage.sh"
ATLAS="$here/../bootstrap/atlas/atlas.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
repo="$tmp/repo"; file="$tmp/coverage.tsv"

fail() { echo "FAIL $*"; exit 1; }

# A fake checkout: three units of decreasing size, plus a sub-package that must be
# counted as its OWN unit rather than folded into its parent.
mk() { mkdir -p "$(dirname "$1")"; printf 'x\n%.0s' $(seq "$2") > "$1"; }
mk "$repo/src/crypto_newsletter/big/a.py" 300
mk "$repo/src/crypto_newsletter/mid/a.py" 200
mk "$repo/src/crypto_newsletter/big/sub/a.py" 100
mkdir -p "$repo/src/crypto_newsletter/nopython/docs"   # no .py at this level -> not a unit

bash "$SEED" --repo "$repo" --file "$file" >/dev/null
[ "$(grep -vc '^#' "$file")" = 3 ] || fail "expected 3 units, got $(grep -vc '^#' "$file")"
grep -q 'nopython' "$file" && fail "directory without .py became a unit"
# biggest first, and the sub-package is separate from its parent
[ "$(grep -v '^#' "$file" | head -1 | cut -f1)" = "src/crypto_newsletter/big" ] || fail "queue not LOC-ordered"
grep -q '^src/crypto_newsletter/big/sub' "$file" || fail "sub-package missing as its own unit"

# next hands out pending modules in queue order, honouring --count
got="$(bash "$ATLAS" next --count 2 --file "$file" | cut -f1 | tr '\n' ' ')"
[ "$got" = "src/crypto_newsletter/big src/crypto_newsletter/mid " ] || fail "next order: $got"
[ "$(bash "$ATLAS" next --count 2 --file "$file" | awk -F'\t' '{print $2}' | sort -u)" = "new" ] || fail "mode should be new"

# done demands evidence: a SHA, a dossier page, and a path:line you actually read.
# (`done` is held in a variable because shellcheck reads a bare `done` word as a
# loop terminator.)
D="done"
rejects() {
  if bash "$ATLAS" "$D" "$@" --file "$file" 2>/dev/null; then fail "done accepted: $*"; fi
}
rejects src/crypto_newsletter/big --sha deadbee --page code/big                              # no --evidence
rejects src/crypto_newsletter/big --sha nothex! --page code/big --evidence a.py:1            # not a SHA
rejects src/crypto_newsletter/big --sha deadbee --page code/big --evidence "a sentence"      # not path:line
rejects src/crypto_newsletter/big --sha deadbee --evidence a.py:1                            # no dossier page
rejects src/crypto_newsletter/ghost --sha deadbee --page code/g --evidence a.py:1            # not in the queue
rejects src/crypto_newsletter/big --sha deadbee --page code/big --evidence a.py:1 --tickets PR-1
grep -q '^src/crypto_newsletter/big	pending' "$file" || fail "rejected calls must not mutate the row"

bash "$ATLAS" "$D" src/crypto_newsletter/big --sha deadbee --page code/big \
     --evidence 'src/crypto_newsletter/big/a.py:12' --tickets CUR-1 --file "$file" >/dev/null
row="$(grep '^src/crypto_newsletter/big	' "$file")"
printf '%s' "$row" | grep -q 'done	deadbee' || fail "row not marked done: $row"
printf '%s' "$row" | grep -q 'code/big	CUR-1' || fail "dossier/tickets not recorded: $row"
# a second visit appends tickets rather than dropping the earlier ones
bash "$ATLAS" "$D" src/crypto_newsletter/big --sha deadbee --page code/big \
     --evidence 'src/crypto_newsletter/big/a.py:12' --tickets CUR-2 --file "$file" >/dev/null
grep '^src/crypto_newsletter/big	' "$file" | grep -q 'CUR-1,CUR-2' || fail "tickets not appended"
[ "$(bash "$ATLAS" next --count 1 --file "$file" | cut -f1)" = "src/crypto_newsletter/mid" ] || fail "done module still handed out"

# reseeding preserves history and marks vanished modules gone rather than deleting them
rm -rf "$repo/src/crypto_newsletter/mid"
mk "$repo/src/crypto_newsletter/newbie/a.py" 10
bash "$SEED" --repo "$repo" --file "$file" >/dev/null
grep '^src/crypto_newsletter/big	' "$file" | grep -q 'done	deadbee' || fail "reseed lost the done row"
grep '^src/crypto_newsletter/mid	' "$file" | grep -q '	gone	' || fail "vanished module not marked gone"
grep '^src/crypto_newsletter/newbie	' "$file" | grep -q '	pending	' || fail "new module not appended as pending"
bash "$ATLAS" next --count 5 --file "$file" | grep -q 'mid' && fail "gone module handed out"

# stats reports the lap honestly
bash "$ATLAS" stats --file "$file" | grep -qE 'modules 4 \| pending 2 \| done 1 \| gone 1' || {
  bash "$ATLAS" stats --file "$file"; fail "stats line"; }

# revisit mode: once nothing is pending, only modules with commits AFTER the SHA the
# dossier was written at come back, and silence means the queue is genuinely clean.
rfile="$tmp/revisit.tsv"; rrepo="$tmp/rrepo"
mk "$rrepo/src/crypto_newsletter/one/a.py" 20
mk "$rrepo/src/crypto_newsletter/two/a.py" 10
git -C "$rrepo" init -q
git -C "$rrepo" -c user.email=t@t -c user.name=t add -A
git -C "$rrepo" -c user.email=t@t -c user.name=t commit -qm init
head_sha="$(git -C "$rrepo" rev-parse --short HEAD)"
bash "$SEED" --repo "$rrepo" --file "$rfile" >/dev/null
for m in one two; do
  bash "$ATLAS" "$D" "src/crypto_newsletter/$m" --sha "$head_sha" --page "code/$m" \
       --evidence "src/crypto_newsletter/$m/a.py:1" --file "$rfile" >/dev/null
done
[ -z "$(bash "$ATLAS" next --count 3 --file "$rfile" --repo "$rrepo")" ] || fail "clean queue should hand out nothing"

echo "y" >> "$rrepo/src/crypto_newsletter/one/a.py"
git -C "$rrepo" -c user.email=t@t -c user.name=t commit -qam change
out="$(bash "$ATLAS" next --count 3 --file "$rfile" --repo "$rrepo")"
printf '%s\n' "$out" | grep -q "^src/crypto_newsletter/one	revisit(1 commits since $head_sha)" ||
  fail "changed module not offered for revisit: $out"
printf '%s\n' "$out" | grep -q 'two' && fail "unchanged module offered for revisit"

# a dossier SHA that is no longer in history (force-push) must re-offer the module
# rather than silently treat it as current
sed -i.bak "s/	$head_sha	/	0000000	/" "$rfile"
bash "$ATLAS" next --count 3 --file "$rfile" --repo "$rrepo" | grep -q 'not in history' ||
  fail "unknown dossier SHA did not force a revisit"

echo "PASS test_atlas_queue"
