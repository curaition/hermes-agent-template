#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [ -f .venv/bin/activate ]; then
  # shellcheck source=/dev/null
  . .venv/bin/activate
fi

pytest -q tests/

for t in tests/test_*.sh; do
  out="$(bash "$t")"
  printf '%s\n' "$out" | grep -q '^PASS ' || { echo "NO PASS LINE: $t"; printf '%s\n' "$out"; exit 1; }
done

bash -n start.sh bootstrap/*.sh ops/hindsight/*.sh ops/hermes/*.sh tests/*.sh tests/fakebin/curl

shellcheck -x -P SCRIPTDIR start.sh bootstrap/*.sh ops/hindsight/*.sh ops/hermes/*.sh tests/*.sh tests/fakebin/curl

echo "ALL GREEN"
