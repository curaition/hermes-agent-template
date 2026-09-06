# ops/ — Hermes two-tier memory (GBrain + Hindsight)

Design: `docs/DESIGN.md`. Runbook (phase order, secrets manifest, verification): `docs/RUNBOOK.md`.

| Path | Purpose |
|---|---|
| `GUARDRAILS.md` | Hermes's standing instructions as issue scout. Delivered as the tail of `SOUL.md` (system persona) via `HERMES_SOUL_MD=$(bash ops/hermes/render_soul.sh \| base64)`, **re-applied every boot** — see RUNBOOK §6.3. (Not `USER.md`: that is the agent-written profile with a 1,375-char cap.) |
| `hermes/soul_prefix.md`, `hermes/render_soul.sh` | Stock persona paragraph + renderer that appends `GUARDRAILS.md` → `HERMES_SOUL_MD` |
| `hindsight/docker-compose.yaml` | Hindsight app container (DB is a separate Coolify database resource) |
| `hindsight/hetzner_firewall.sh` | Hetzner Cloud Firewall: inbound 22/80/443 only, idempotent |
| `hindsight/box_prep.sh` | On-box: 2G swap (run as root over SSH) |
| `hindsight/coolify_apply.sh` | Coolify API: project → Postgres DB → compose service → env → domain → start |
| `hindsight/coolify_backup.sh` | Coolify API: daily S3 (GCS) backup on the DB resource |
| `hindsight/bootstrap_hindsight.sh` | Bank `hermes-agent`: config, directives, mental models, `--lockdown` |
| `hindsight/verify.sh` | Automated acceptance checks (firewall, TLS, auth gate, bank shape) |
| `hindsight/lockdown_coding_bank.sh` | Bank `coding-agent::curaition`: READ-ONLY `mcp_enabled_tools` (the Claude Code integration sets none — 29 tools incl. `delete_bank` were exposed, measured 2026-09-03) |
| `hermes/env.example` | Railway env vars for the Hermes service (names only) |
| `hermes/mcp_servers.yaml` | Declarative `mcp_servers` (GBrain, Linear, Hindsight `hermes-agent`, and read-only `codebase_memory` allowlists) — base64 → `HERMES_MCP_SERVERS_YAML` |
| `hermes/hindsight.config.json` | Plugin config — base64 → `HERMES_HINDSIGHT_CONFIG_JSON` |
| `hermes/prompts/*.md` | Cron job prompts. `owner.md` and `release.md` are templates (`{{OWNER}}`, `{{AREA_LABEL}}`, `{{MODE}}`) for the owner swarm (Step 1) |
| `hermes/render_owner_prompt.sh` | Renders `owner.md` for one of the nine owners (or `release.md`) in `dry-run`/`live` mode; the owner→Linear-label map lives here and must match existing labels |
| `hermes/cron_install.sh` | Creates + pauses the cron jobs (run inside the container): scout/hygiene/atlas/implement, the two pilot owners (`hermes-owner-patterns` 00:00, `hermes-owner-video_pipeline` 01:00 UTC) and `hermes-release` (hourly 09–17 UTC), all dry-run + paused |
| `github-app/manifest.json`, `github-app/create_app.py` | The `curaition-hermes` GitHub App (owner swarm Step 1, CUR-1538): what is registered and the one-click local manifest flow. `bootstrap/gh_app_token.py` mints its installation token at boot and per owner run — `github-app/README.md` |

Pushes that touch only `ops/**` or `*.md` do NOT redeploy Hermes (`railway.toml` watchPatterns).
