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

# Bootstrap custom skills from env var (base64-encoded tar.gz).
# Export your local skills:
#   HERMES_SKILLS_TARGZ=$(tar -czf - -C ~/.hermes/skills . | base64)
# Set HERMES_SKILLS_TARGZ as a Railway env var.
# Only runs if skills directory is empty (no existing skills).
if [ -z "$(ls -A /data/.hermes/skills 2>/dev/null)" ] && [ -n "${HERMES_SKILLS_TARGZ}" ]; then
  printf '%s' "${HERMES_SKILLS_TARGZ}" | base64 -d | tar -xzf - -C /data/.hermes/skills
fi

# Clear any stale gateway PID file left over from the previous container.
# `hermes gateway` writes /data/.hermes/gateway.pid on start but does not
# remove it on SIGTERM. Since /data is a persistent volume, the file
# survives container restarts and causes every subsequent boot to exit with
# "ERROR gateway.run: PID file race lost to another gateway instance".
# No hermes process can be running at this point (we're pre-exec in a fresh
# container), so removing the file unconditionally is safe.
rm -f /data/.hermes/gateway.pid

exec python /app/server.py
