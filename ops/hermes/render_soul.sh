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
# ops/hermes/rules.md is GENERATED from the product repo's canonical rules section
# (`python -m scripts.ops.apply_agent_rules --target hermes --out ops/hermes/rules.md`, CUR-1539)
# and appended last so the universal rules close the persona. Never hand-edit it; the product
# repo's `check_agent_rules_parity --hermes` proves it current.
cat "$here/soul_prefix.md"; printf '\n'; cat "$here/../GUARDRAILS.md"; printf '\n'; cat "$here/rules.md"
