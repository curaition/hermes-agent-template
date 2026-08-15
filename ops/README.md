# ops/ — Hermes two-tier memory (GBrain + Hindsight)

Design: `docs/DESIGN.md`. Runbook (phase order, secrets manifest, verification): `docs/RUNBOOK.md`.

| Path | Purpose |
|---|---|
| `GUARDRAILS.md` | Content of `HERMES_USER_MD` — Hermes's standing instructions as issue scout. **Write-once:** `start.sh` only seeds `/data/.hermes/memories/USER.md` from this env var if the file doesn't already exist — see RUNBOOK §6.3 to push a change |
| `hindsight/docker-compose.yaml` | Hindsight app container (DB is a separate Coolify database resource) |
| `hindsight/hetzner_firewall.sh` | Hetzner Cloud Firewall: inbound 22/80/443 only, idempotent |
| `hindsight/box_prep.sh` | On-box: 2G swap (run as root over SSH) |
| `hindsight/coolify_apply.sh` | Coolify API: project → Postgres DB → compose service → env → domain → start |
| `hindsight/coolify_backup.sh` | Coolify API: daily S3 (GCS) backup on the DB resource |
| `hindsight/bootstrap_hindsight.sh` | Bank `hermes-agent`: config, directives, mental models, `--lockdown` |
| `hindsight/verify.sh` | Automated acceptance checks (firewall, TLS, auth gate, bank shape) |
| `hermes/env.example` | Railway env vars for the Hermes service (names only) |
| `hermes/mcp_servers.yaml` | Declarative `mcp_servers` (GBrain + Linear allowlists) — base64 → `HERMES_MCP_SERVERS_YAML` |
| `hermes/hindsight.config.json` | Plugin config — base64 → `HERMES_HINDSIGHT_CONFIG_JSON` |
| `hermes/prompts/*.md` | Cron job prompts |
| `hermes/cron_install.sh` | Creates + pauses the two cron jobs (run inside the container) |

Pushes that touch only `ops/**` or `*.md` do NOT redeploy Hermes (`railway.toml` watchPatterns).
