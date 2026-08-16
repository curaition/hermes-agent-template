#!/usr/bin/env bash
# Prints the SOUL.md that Hermes should run with: the stock persona paragraph followed by
# ops/GUARDRAILS.md. Pipe through base64 for HERMES_SOUL_MD:
#   railway variables --service "Hermes Agent" --set "HERMES_SOUL_MD=$(bash ops/hermes/render_soul.sh | base64 | tr -d '\n')"
# Why SOUL.md and not USER.md: SOUL.md is Hermes's system persona (no size cap, applies to
# every session incl. cron); USER.md is the agent-written user profile with a 1,375-char
# limit that the 6 KB guardrails would blow through — and it already holds real profile
# memory on the live volume (found live 2026-08-16, Part B).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cat "$here/soul_prefix.md"; printf '\n'; cat "$here/../GUARDRAILS.md"
