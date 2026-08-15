#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="$(DRY_RUN=1 SWAP_PRESENT=0 bash "$here/../ops/hindsight/box_prep.sh")"
grep -q 'fallocate -l 2G /swapfile' <<<"$out" || { echo "FAIL: no fallocate"; exit 1; }
grep -q 'chmod 600 /swapfile' <<<"$out" || { echo "FAIL: no chmod"; exit 1; }
grep -q '/swapfile none swap sw 0 0' <<<"$out" || { echo "FAIL: no fstab line"; exit 1; }
grep -q 'vm.swappiness=10' <<<"$out" || { echo "FAIL: no swappiness"; exit 1; }
out2="$(DRY_RUN=1 SWAP_PRESENT=1 bash "$here/../ops/hindsight/box_prep.sh")"
grep -q 'fallocate' <<<"$out2" && { echo "FAIL: not idempotent"; exit 1; }
echo "PASS test_box_prep"
