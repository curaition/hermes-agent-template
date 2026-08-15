#!/usr/bin/env bash
# On-box prep for the 2c/3.7GB Hetzner server: 2G swapfile (+fstab, swappiness=10).
# Run as root over SSH:  ssh root@<box> 'bash -s' < ops/hindsight/box_prep.sh
# DRY_RUN=1 prints commands. SWAP_PRESENT overrides detection (tests only).
set -euo pipefail
# shellcheck disable=SC2294  # Commands are passed as single quoted strings on purpose so DRY_RUN can echo them verbatim
run() { if [ "${DRY_RUN:-0}" = "1" ]; then echo "+ $*"; else eval "$@"; fi; }
present="${SWAP_PRESENT:-}"
if [ -z "$present" ]; then
  if swapon --show=NAME --noheadings 2>/dev/null | grep -q '^/swapfile$'; then present=1; else present=0; fi
fi
if [ "$present" = "1" ]; then
  echo "swap already present: /swapfile"
else
  run "fallocate -l 2G /swapfile"
  run "chmod 600 /swapfile"
  run "mkswap /swapfile"
  run "swapon /swapfile"
  run "grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab"
fi
run "sysctl -w vm.swappiness=10 >/dev/null"
run "grep -q '^vm.swappiness=' /etc/sysctl.d/99-hermes-memory.conf 2>/dev/null || echo 'vm.swappiness=10' > /etc/sysctl.d/99-hermes-memory.conf"
if [ "${DRY_RUN:-0}" != "1" ]; then swapon --show; free -h; fi
