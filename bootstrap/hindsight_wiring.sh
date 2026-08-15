#!/usr/bin/env bash
# Sourced by start.sh. Materializes the Hindsight memory tier + declarative
# mcp_servers wiring from env vars into $DATA_ROOT/.hermes. Env is the source
# of truth: values are (re)applied every boot, like HERMES_MCP_LINEAR_JSON.
#
#   HERMES_HINDSIGHT_CONFIG_JSON  base64 JSON  → .hermes/hindsight/config.json (0600)
#   HINDSIGHT_API_KEY / HINDSIGHT_API_URL      → upserted into .hermes/.env (0600; child shells, cron)
#   HERMES_MEMORY_PROVIDER        e.g. hindsight → config.yaml memory.provider
#   HERMES_MCP_SERVERS_YAML       base64 YAML  → config.yaml mcp_servers.<name> (per-server replace)
#
# Requires python3 + PyYAML (present in the image). Returns non-zero only on
# malformed input; unset vars are a no-op.

_hw_upsert_env() { # _hw_upsert_env FILE KEY VALUE
  local file="$1" key="$2" val="$3" tmp
  tmp="${file}.tmp.$$"
  touch "$file"
  grep -v "^${key}=" "$file" > "$tmp" || true
  printf '%s=%s\n' "$key" "$val" >> "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$file"
}

materialize_hindsight_wiring() {
  local root="${1:-/data}" home; home="$root/.hermes"
  local here; here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  mkdir -p "$home"

  if [ -n "${HERMES_HINDSIGHT_CONFIG_JSON:-}" ]; then
    mkdir -p "$home/hindsight"
    local tmp="$home/hindsight/.config.json.tmp"
    if printf '%s' "$HERMES_HINDSIGHT_CONFIG_JSON" | base64 -d > "$tmp" 2>/dev/null \
       && python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$tmp" 2>/dev/null; then
      chmod 600 "$tmp" && mv "$tmp" "$home/hindsight/config.json"
      echo "hindsight_wiring: wrote hindsight/config.json"
    else
      rm -f "$tmp"
      echo "hindsight_wiring: HERMES_HINDSIGHT_CONFIG_JSON is not valid base64 JSON — left existing config untouched" >&2
      return 1
    fi
  fi

  [ -n "${HINDSIGHT_API_KEY:-}" ] && _hw_upsert_env "$home/.env" HINDSIGHT_API_KEY "$HINDSIGHT_API_KEY"
  [ -n "${HINDSIGHT_API_URL:-}" ] && _hw_upsert_env "$home/.env" HINDSIGHT_API_URL "$HINDSIGHT_API_URL"

  if [ -n "${HERMES_MEMORY_PROVIDER:-}" ] || [ -n "${HERMES_MCP_SERVERS_YAML:-}" ]; then
    if [ ! -f "$home/config.yaml" ]; then
      echo "hindsight_wiring: $home/config.yaml missing — cannot patch (config seeding must run first)" >&2
      return 1
    fi
    local args=(--config "$home/config.yaml")
    [ -n "${HERMES_MEMORY_PROVIDER:-}" ] && args+=(--memory-provider "$HERMES_MEMORY_PROVIDER")
    [ -n "${HERMES_MCP_SERVERS_YAML:-}" ] && args+=(--mcp-servers-b64 "$HERMES_MCP_SERVERS_YAML")
    python3 "$here/hermes_config_patch.py" "${args[@]}"
  fi
  return 0
}
