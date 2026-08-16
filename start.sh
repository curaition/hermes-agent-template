#!/bin/bash
set -e

# Mirror dashboard-ref-only's startup: create every directory hermes expects
# and seed a default config.yaml if the volume is empty. Without these,
# `hermes dashboard` endpoints that hit logs/, sessions/, cron/, etc. can fail
# with opaque errors even though no auth is actually involved.
mkdir -p /data/.hermes/cron /data/.hermes/sessions /data/.hermes/logs \
         /data/.hermes/memories /data/.hermes/skills /data/.hermes/pairing \
         /data/.hermes/hooks /data/.hermes/image_cache /data/.hermes/audio_cache \
         /data/.hermes/workspace /data/.hermes/skins /data/.hermes/plans \
         /data/.hermes/home

# Stamp the install method as "docker" so hermes treats this as an immutable
# container image, not a pip checkout. hermes's detect_install_method() reads
# $HERMES_HOME/.install_method FIRST (before any .git / pip fallback). Without
# this stamp the template falls through to "pip" — because the Dockerfile strips
# /opt/hermes-agent/.git — and the dashboard's "Update Hermes" button then runs
# a real `hermes update` (PyPI pip-upgrade) INSIDE the running container. That
# upgrade is ephemeral (reverts on the next redeploy) and can desync the Python
# package from the image's pre-built web_dist/ui-tui bundles. Stamping "docker"
# makes that button correctly refuse with "pull a fresh image / redeploy", which
# matches the real upgrade path here (bump HERMES_REF in Railway + redeploy).
# Written unconditionally each boot so it stays correct and self-heals.
printf 'docker\n' > /data/.hermes/.install_method

if [ ! -f /data/.hermes/config.yaml ] && [ -f /opt/hermes-agent/cli-config.yaml.example ]; then
  cp /opt/hermes-agent/cli-config.yaml.example /data/.hermes/config.yaml
fi

[ ! -f /data/.hermes/.env ] && touch /data/.hermes/.env

# Bootstrap OAuth tokens from env var (e.g. xAI Grok SuperGrok).
# Set HERMES_AUTH_JSON_BOOTSTRAP to the contents of a locally-generated
# ~/.hermes/auth.json. Written only once — subsequent token refreshes update
# the file in place on the persistent volume.
if [ ! -f /data/.hermes/auth.json ] && [ -n "${HERMES_AUTH_JSON_BOOTSTRAP}" ]; then
  printf '%s' "${HERMES_AUTH_JSON_BOOTSTRAP}" > /data/.hermes/auth.json
  chmod 600 /data/.hermes/auth.json
fi

# Bootstrap Google OAuth credentials from env vars.
# Export your local credentials:
#   HERMES_GOOGLE_TOKEN_JSON=$(cat ~/.hermes/google_token.json | base64)
#   HERMES_GOOGLE_CLIENT_SECRET_JSON=$(cat ~/.hermes/google_client_secret.json | base64)
# Set these as Railway env vars on the Hermes Agent service.
# Written only once — if the file exists on the volume, it won't be overwritten.
if [ ! -f /data/.hermes/google_token.json ] && [ -n "${HERMES_GOOGLE_TOKEN_JSON}" ]; then
  printf '%s' "${HERMES_GOOGLE_TOKEN_JSON}" | base64 -d > /data/.hermes/google_token.json
  chmod 600 /data/.hermes/google_token.json
fi
if [ ! -f /data/.hermes/google_client_secret.json ] && [ -n "${HERMES_GOOGLE_CLIENT_SECRET_JSON}" ]; then
  printf '%s' "${HERMES_GOOGLE_CLIENT_SECRET_JSON}" | base64 -d > /data/.hermes/google_client_secret.json
  chmod 600 /data/.hermes/google_client_secret.json
fi

# Bootstrap GBrain bearer token from env var.
# Get your token from ~/.config/gbrain/token on your local machine.
# Set HERMES_GBRAIN_TOKEN as a Railway env var.
# Stored in two locations for compatibility with different script patterns.
if [ -n "${HERMES_GBRAIN_TOKEN}" ]; then
  mkdir -p /data/.config/gbrain
  printf '%s' "${HERMES_GBRAIN_TOKEN}" > /data/.config/gbrain/token
  chmod 600 /data/.config/gbrain/token
  # Also write to .hermes home for scripts that use HERMES_HOME
  printf '%s' "${HERMES_GBRAIN_TOKEN}" > /data/.hermes/.gbrain_token
  chmod 600 /data/.hermes/.gbrain_token
fi

# Bootstrap Hermes memories from env vars.
# Export your local memories:
#   HERMES_MEMORY_MD=$(cat ~/.hermes/memories/MEMORY.md | base64)
#   HERMES_USER_MD=$(cat ~/.hermes/memories/USER.md | base64)
# Written only once — manual edits made in Railway won't be overwritten on redeploy.
if [ ! -f /data/.hermes/memories/MEMORY.md ] && [ -n "${HERMES_MEMORY_MD}" ]; then
  printf '%s' "${HERMES_MEMORY_MD}" | base64 -d > /data/.hermes/memories/MEMORY.md
fi
if [ ! -f /data/.hermes/memories/USER.md ] && [ -n "${HERMES_USER_MD}" ]; then
  printf '%s' "${HERMES_USER_MD}" | base64 -d > /data/.hermes/memories/USER.md
fi

# SOUL.md (Hermes's system persona) is env-declared and RE-APPLIED every boot — env is the
# truth, like the Hindsight wiring below. Content: `bash ops/hermes/render_soul.sh | base64`.
# Decode failures leave the existing file untouched (a bad paste must not brick the gateway).
if [ -n "${HERMES_SOUL_MD:-}" ]; then
  if printf '%s' "${HERMES_SOUL_MD}" | tr -d ' \n\r' | base64 -d > /data/.hermes/SOUL.md.tmp 2>/dev/null \
     && [ -s /data/.hermes/SOUL.md.tmp ]; then
    mv /data/.hermes/SOUL.md.tmp /data/.hermes/SOUL.md
  else
    echo "WARN: HERMES_SOUL_MD is not valid base64 (or empty) — keeping existing /data/.hermes/SOUL.md" >&2
    rm -f /data/.hermes/SOUL.md.tmp
  fi
fi

# Bootstrap custom skills from env var (base64-encoded tar.gz).
# Export your local skills:
#   HERMES_SKILLS_TARGZ=$(tar -czf - -C ~/.hermes/skills . | base64)
# Set HERMES_SKILLS_TARGZ as a Railway env var.
# Only runs if skills directory is empty (no existing skills).
if [ -z "$(ls -A /data/.hermes/skills 2>/dev/null)" ] && [ -n "${HERMES_SKILLS_TARGZ}" ]; then
  printf '%s' "${HERMES_SKILLS_TARGZ}" | base64 -d | tar -xzf - -C /data/.hermes/skills
fi

# Bootstrap MCP OAuth tokens from env vars.
# After completing `hermes mcp login <server>` locally, export token files:
#   HERMES_MCP_LINEAR_JSON=$(cat ~/.hermes/mcp-tokens/linear.json | base64)
# Written every boot so rotated tokens propagate on redeploy.
mkdir -p /data/.hermes/mcp-tokens
if [ -n "${HERMES_MCP_LINEAR_JSON}" ]; then
  printf '%s' "${HERMES_MCP_LINEAR_JSON}" | base64 -d > /data/.hermes/mcp-tokens/linear.json
  chmod 600 /data/.hermes/mcp-tokens/linear.json
fi

# Two-tier memory wiring (Hindsight plugin config, memory.provider, declarative
# mcp_servers allowlists). See ops/docs/DESIGN.md §4.5. Env is the source of
# truth and is re-applied every boot. Fails the boot loudly on malformed input
# rather than starting a gateway with half-applied wiring.
# shellcheck source=bootstrap/hindsight_wiring.sh
source /app/bootstrap/hindsight_wiring.sh
# Fail OPEN: a bad env paste must degrade to "memory tier unavailable" (GUARDRAILS rule 7),
# never crash-loop the gateway. start.sh runs under `set -e`, so the guard is required.
materialize_hindsight_wiring /data || echo "WARN: hindsight wiring failed (rc=$?) — gateway starts without the memory-tier changes" >&2

# Clear any stale gateway PID file left over from the previous container.
# `hermes gateway` writes /data/.hermes/gateway.pid on start but does not
# remove it on SIGTERM. Since /data is a persistent volume, the file
# survives container restarts and causes every subsequent boot to exit with
# "ERROR gateway.run: PID file race lost to another gateway instance".
# No hermes process can be running at this point (we're pre-exec in a fresh
# container), so removing the file unconditionally is safe.
rm -f /data/.hermes/gateway.pid

# Explicitly export GH_TOKEN so all hermes-spawned terminal sessions,
# delegations, and cron jobs reliably inherit it. Railway sets this as an
# env var on PID 1, but it doesn't always propagate to shell child processes.
# This is a safety net — if the var is already inherited, export is a no-op.
export GH_TOKEN

# Also write GH_TOKEN to .hermes/.env so all hermes-spawned terminal sessions,
# cron jobs, and delegations inherit it via the env file (more reliable than
# shell export alone, which does not propagate to ephemeral bash snapshots).
if [ -n "${GH_TOKEN}" ]; then
  if grep -q "^GH_TOKEN=" /data/.hermes/.env 2>/dev/null; then
    sed -i "s|^GH_TOKEN=.*|GH_TOKEN=${GH_TOKEN}|" /data/.hermes/.env
  else
    echo "GH_TOKEN=${GH_TOKEN}" >> /data/.hermes/.env
  fi
fi

# Hermes STRIPS GH_TOKEN from every terminal/execute_code subprocess by design
# (tools/environments/local.py provider blocklist; passthrough refuses it), and the
# terminal shell runs with HOME=/data/.hermes/home. So git/gh inside the agent's
# shell authenticate ONLY via that HOME's stored credentials. Keep them in sync
# with GH_TOKEN on every boot — a stale store here produced silent anonymous 403s
# in the scout (found live 2026-08-16). Env is the truth; the store is derived.
TERM_HOME=/data/.hermes/home
if [ -n "${GH_TOKEN}" ]; then
  mkdir -p "${TERM_HOME}/.config/gh"
  ( umask 077; printf 'https://x-access-token:%s@github.com\n' "${GH_TOKEN}" > "${TERM_HOME}/.git-credentials" )
  if ! grep -q 'helper = store --file=/data/.hermes/home/.git-credentials' "${TERM_HOME}/.gitconfig" 2>/dev/null; then
    printf '[user]\n\tname = Hermes Agent\n\temail = info@curaition.xyz\n[credential]\n\thelper = store --file=/data/.hermes/home/.git-credentials\n' > "${TERM_HOME}/.gitconfig"
  fi
  # gh (for `gh pr list` etc.) needs its own stored login; must run WITHOUT GH_TOKEN in env or it refuses to store.
  if command -v gh >/dev/null 2>&1; then
    printf '%s' "${GH_TOKEN}" | env -u GH_TOKEN HOME="${TERM_HOME}" gh auth login --with-token >/dev/null 2>&1 \
      || echo "WARN: gh auth login (terminal HOME) failed — gh commands in the agent shell will be unauthenticated" >&2
  fi
fi

exec python /app/server.py
