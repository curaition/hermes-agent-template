# Hermes Two-Tier Memory (GBrain + Hindsight) — Design Spec

**Date:** 2026-08-15 · **Status:** approved-in-chat, awaiting written review
**Supersedes:** `docs/ops/hermes-memory/RUNBOOK.md` (uncommitted, 2026-08-15) as the
design of record. The runbook's operational content is carried into the
`curaition/hermes-agent-template` repo under `ops/` by this work.

## 1. Goal

Give the Railway-hosted Hermes agent (Telegram assistant in Railway project
`peaceful-rejoicing`, service built from `curaition/hermes-agent-template`)
a two-tier memory and repurpose it as a **read-only Linear issue scout** for
`curaition-xyz/curaition`:

| Tier | Store | Where | Holds | Hermes access |
|---|---|---|---|---|
| Knowledge | GBrain (existing) | Railway, private net | Codebase graph, entities, curated pages — "what is true" | read + additive write; destructive/admin tools removed |
| Experience | Hindsight (new) | Hetzner box, Coolify, HTTPS | Run learnings, proposal outcomes, feedback, directives, mental models — "what I did/learned/was told" | plugin auto-recall/auto-retain + `reflect`; delete/admin tools removed server-side |

**Boundary rule:** content goes to the store matching its *kind*, never both.
Codebase documentation → GBrain. Hermes's diary → Hindsight. Doesn't fit
either → don't store it.

### Non-goals
- Migrating GBrain or Hermes off Railway (§10 records the path; not built now).
- Hermes writing code, opening PRs, or mutating Linear beyond create/comment.
- A production/staging split for any of these services.
- Ingesting the CurAItion product corpus into either memory tier.

## 2. Decisions and stated assumptions (from brainstorm, 2026-08-15)

| # | Decision | Rationale |
|---|---|---|
| D1 | Artifacts live in `curaition/hermes-agent-template` under `ops/`, not in the product repo | Hermes-specific infra; product repo stays clean; the fork is already the Hermes deployment repo. `docs/*` in the product repo is gitignored → unversioned, which is what we are escaping |
| D2 | `railway.toml` gains `watchPatterns` excluding `ops/**` and `**/*.md` | A docs/ops push must not redeploy Hermes (a redeploy restarts the gateway) |
| D3 | Working domain assumption: `hindsight.curaition.xyz`, `coolify.curaition.xyz`; Coolify dashboard served by **FQDN** (not tunnel) | FQDN needed for Coolify's `/mcp` endpoint; TLS + login instead of open :8000. **Rick may substitute another zone** — every reference is a single variable |
| D4 | Hindsight LLM = `gemini-3-flash-preview` via a **fresh AI Studio key minted in a non-product GCP project**; fallback `gemini-2.5-flash`. Embeddings = OpenAI `text-embedding-3-small` | Cost is <~$3/mo either way at this bank's volume; Gemini 3 Flash is the stronger extractor. Non-product project keeps CUR-1361's "product is Vertex-only" invariant intact. Alternative kept in reserve: `HINDSIGHT_API_LLM_PROVIDER=vertexai` with a bucket-scoped SA — rejected for now because it puts a GCP SA key on the Hetzner box |
| D5 | Railway env, fork pushes, Linear label creation: agent-executed | Rick approved |
| D6 | Hermes gets a **dedicated Linear identity** (paid seat unless free slot); OAuth paste-back done logged in as that identity | Attribution + revocation |
| D7 | Backups → a **new** GCS bucket `curaition-hermes-backups` (same GCP project as product), bucket-scoped SA + HMAC key | HMAC key lives on the box; must not be able to reach product objects |
| D8 | Cadence: cron jobs created **paused**; 3–5 manual runs to tune; then **Mon/Wed/Fri 02:00 UTC** for 2 weeks; Sunday hygiene enabled only after scout output is trusted; nightly only if triage keeps up | Triage attention is the binding resource (nightly ⇒ up to 42 issues in the observation window) |
| D9 | Railway-side wiring is **declarative via `start.sh` env-materialization** (approach A), not hand-run `hermes memory setup` over SSH | Reproducible from env + repo; matches how Google/GBrain/Linear are already wired; survives the future Hetzner port |
| D10 | Hetzner side is API-driven (Coolify API + Hetzner Cloud API) with committed idempotent scripts | Re-runnable; the only SSH-requiring steps are swap and on-box verification |

## 3. Architecture

```
Railway "peaceful-rejoicing" (europe-west4)
├── Hermes Agent  (fork; Dockerfile build; /data volume; start.sh materializes HERMES_* env → /data once)
│     ├─ MCP  → GBrain   http://gbrain.railway.internal:3131/mcp   (bearer HERMES_GBRAIN_TOKEN)   knowledge tier
│     ├─ memory plugin "hindsight" mode=local_external → https://hindsight.<zone>  (bearer HINDSIGHT_API_KEY)  experience tier
│     ├─ MCP  → Linear   https://mcp.linear.app/mcp (OAuth, dedicated identity)                       output: issues
│     ├─ Telegram gateway (run summaries)
│     └─ /data/work/curaition  (read-only clone; fine-grained PAT, Contents:Read + Metadata:Read)
├── GBrain (Bun, :3131) + Postgres                                              (unchanged)

Hetzner box (2c/3.7GB, Ubuntu 26.04, Coolify)  — Hetzner Cloud Firewall: 22/80/443 only
└── Coolify project "hermes-memory" → Docker Compose resource "hindsight"
      ├── db        pgvector/pgvector:pg17   (volume pg_data; daily backup → GCS S3-interop)
      └── hindsight ghcr.io/vectorize-io/hindsight:<pinned>  :8888 API/MCP behind Coolify proxy (TLS)
                    :9999 control-plane UI NOT published (SSH tunnel only)
                    auth: ApiKeyTenantExtension; LLM gemini; embeddings openai
```

Latency Hetzner (DE) ↔ Railway europe-west4 (NL) is single-digit ms; per-turn
auto-recall over HTTPS is acceptable.

## 4. Components

### 4.1 Hindsight stack (Coolify Docker Compose resource)

Two Coolify resources, not one (refined during planning): **Postgres is a
first-class Coolify database resource** `hindsight-db` (`pgvector/pgvector:pg17`
— pg17, not pg18: the pg18 image moved PGDATA off Coolify's
`/var/lib/postgresql/data` volume) because Coolify's scheduled-backup API
(`POST /databases/{uuid}/backups`) applies only to database resources; and the
Hindsight app is a one-container Docker Compose service (`ops/hindsight/docker-compose.yaml`)
connected to the predefined network so it can reach the DB. **Pin**
`HINDSIGHT_VERSION` (no `:latest` on something that holds state); set
`HINDSIGHT_API_EMBEDDINGS_OPENAI_MODEL=text-embedding-3-small` explicitly.
No host port binds; Coolify proxy routes `https://hindsight.<zone>` → `hindsight:8888`.

Env (Coolify, marked secret where noted):

| Var | Value | Secret |
|---|---|---|
| `HINDSIGHT_VERSION` | pinned tag discovered at deploy (`ghcr.io/vectorize-io/hindsight`) | no |
| `HINDSIGHT_API_DATABASE_URL` | from the DB resource's `internal_db_url` (set by `coolify_apply.sh`) | yes |
| `HINDSIGHT_TENANT_API_KEY` | `openssl rand -hex 32` | yes |
| `HINDSIGHT_LLM_MODEL` | `gemini-3-flash-preview` | no |
| `GEMINI_API_KEY` | AI Studio key, non-product GCP project | yes |
| `OPENAI_API_KEY` | existing (same as GBrain service) | yes |

Interface exposed: `POST /mcp/` (multi-bank), `POST /mcp/hermes-agent/`
(single-bank), REST `/v1/default/banks/...` — all bearer-authenticated.

### 4.2 Bank bootstrap (`ops/hindsight/bootstrap_hindsight.sh`)

The existing script, hardened:
- **Idempotent**: before each `create_directive` / `create_mental_model`, list
  and skip if the name/id exists (today's script duplicates on re-run).
- **Auth gate first**: unauthenticated `tools/list` must return 401 or the
  script aborts (`set -e` on a `[ "$code" = 401 ]` check).
- **Lockdown last** and split into `--lockdown` flag so the bank can be
  re-seeded/edited before the MCP allowlist is applied. After lockdown, admin
  edits use REST `PATCH /v1/default/banks/hermes-agent/config` (still bearer
  auth) — documented in the script header.
- Content unchanged: mission, `retain_mission`, `disposition_skepticism: 4`,
  3 directives, 2 mental models with `tags_match: "any"`, allowlist =
  `retain, sync_retain, recall, reflect, list_memories, get_memory,
  list_mental_models, get_mental_model, list_directives, list_tags, get_bank,
  list_documents, get_document, list_operations, get_operation`.

### 4.3 Box provisioning (`ops/hindsight/hetzner_firewall.sh`, `ops/hindsight/box_prep.sh`)

- `hetzner_firewall.sh` — Hetzner Cloud API: create firewall `hermes-memory`
  (in: 22 from `${ADMIN_CIDR:-0.0.0.0/0}`, 80, 443; everything else denied,
  which includes 8000/6001/6002/8888/9999), attach to the server. Idempotent
  (get-or-create by name).
- `box_prep.sh` — run over SSH as root: 2G swapfile + fstab entry (skip if
  `swapon --show` already lists it), print `free -h`.

### 4.4 Coolify wiring (`ops/hindsight/coolify_apply.sh`)

Coolify REST API (`/api/v1`, bearer): create project → create Docker Compose
service from the committed compose → set env vars → attach domain
`https://hindsight.<zone>` to service `hindsight` port 8888 → deploy → poll
until healthy. Storage (GCS S3-interop) and scheduled backup on `db` are
created via API where supported; anything the API version lacks is a
documented click-path in the runbook. Coolify instance FQDN
(`coolify.<zone>`) is set via UI once (one-time, Rick or agent with UI access).

### 4.5 Hermes fork changes (`curaition/hermes-agent-template`)

`start.sh` additions — **env is the source of truth, re-applied every boot**
(the same "written every boot so rotations propagate" rule the fork already
uses for `HERMES_MCP_LINEAR_JSON`; refined from write-once during planning):

```
HERMES_HINDSIGHT_CONFIG_JSON   base64 JSON → /data/.hermes/hindsight/config.json (0600); invalid input fails the boot
HINDSIGHT_API_KEY, HINDSIGHT_API_URL   plain env; also upserted into /data/.hermes/.env for cron/child shells
HERMES_MEMORY_PROVIDER=hindsight       config.yaml memory.provider := value
HERMES_MCP_SERVERS_YAML                base64 YAML; each named server REPLACES mcp_servers.<name>; others untouched
                                       (GBrain with tool allowlist, Linear with tool allowlist)
```
Implemented as `bootstrap/hindsight_wiring.sh` (sourced by `start.sh`) +
`bootstrap/hermes_config_patch.py`.

`config.json` content:
`{"mode":"local_external","api_url":"https://hindsight.<zone>","bank_id":"hermes-agent","memory_mode":"hybrid","auto_recall":true,"auto_retain":true,"recall_budget":"mid"}`
(keys confirmed against `plugins/memory/hindsight/__init__.py` v0.17.0; the
plugin reads `HINDSIGHT_API_KEY` from env for the bearer).

Also: `hindsight-client>=0.6.1` in `requirements.txt` (`_MIN_CLIENT_VERSION` in
the plugin; the Dockerfile's `[hindsight]` extra already installs the client — this pins the floor).

`railway.toml`: `watchPatterns = ["/**", "!ops/**", "!**/*.md"]` (D2).

`ops/GUARDRAILS.md` = current `HERMES_GUARDRAILS.md`, delivered as `HERMES_SOUL_MD` (persona prefix + guardrails → `/data/.hermes/SOUL.md`, re-applied every boot). *Deviation recorded 2026-08-16:* the spec said `HERMES_USER_MD`; live data showed `USER.md` is the agent-written profile (1,375-char cap, real content on the volume), so SOUL.md is the correct surface.

### 4.6 GBrain trim (Hermes MCP config)

Allowlist (kept): `query, search, recall, get_page, get_chunks, get_backlinks,
get_links, get_timeline, volunteer_context, code_def, code_refs, code_callers,
code_callees, code_flow, code_blast, put_page, extract_facts,
add_timeline_entry, add_tag, add_link, think`.
Excluded: `delete_page, forget_fact, revert_version, restore_page,
schema_apply_mutations, reload_schema_pack, run_skillopt, sources_remove`, all
job-control tools, and everything else not listed. Implemented as `mcp_servers.gbrain.tools.include` in Hermes `config.yaml`
(include takes precedence over exclude — `tools/mcp_tool.py:4069-4077`).

### 4.7 Linear

Server `https://mcp.linear.app/mcp`, OAuth as the dedicated identity; tokens
materialize via existing `HERMES_MCP_LINEAR_JSON`. Allowlist: `list_issues,
search_issues, get_issue, save_issue, list_issue_labels, save_comment`. Label
`hermes-proposed` created once in team CUR (agent, via Linear MCP).

### 4.8 Repo clone

`GH_TOKEN` rotated to a fine-grained PAT on a machine account (or Rick's
account if a machine account isn't wanted — flagged), scope
`curaition-xyz/curaition`, Contents:Read + Metadata:Read. Clone at
`/data/work/curaition`; each run: `git fetch origin && git reset --hard
origin/staging`; issues cite the short SHA. Verified read-only by an
intentional push attempt that must fail.

### 4.9 Cron (`hermes cron create`)

Two jobs, created with `hermes cron create <schedule> <prompt> --name … --deliver telegram --workdir /data/work/curaition`
and immediately paused with `hermes cron pause <id>` (the CLI has no `--paused` flag; `--workdir` sets the run cwd):
- `scout` — schedule `0 2 * * 1,3,5`, prompt = the scout run procedure from
  GUARDRAILS (refresh clone → read mental models → reflect → GBrain → verify
  → dedupe → file ≤3 issues → retain outcome → Telegram summary).
- `hygiene` — `0 3 * * 0`, prompt = review open `hermes-proposed` issues,
  comment on staleness (cited SHA no longer matches), consolidate, retain.
Delivery: Telegram to the founders' group (existing `/sethome`).

## 5. Data flow (one scout run)

1. Cron fires → Hermes session starts; hindsight plugin auto-recalls context
   for the prompt (experience tier).
2. Agent reads `refactor-landscape` and `proposal-outcomes` mental models
   (2 calls), then `reflect` on candidate areas — directives apply.
3. Refresh clone; record SHA.
4. GBrain: `query`/`get_page` for the area; `code_callers`/`code_refs` for
   blast radius (knowledge tier).
5. Verify claims against the clone (`path:line`).
6. Linear: search for dupes; `gh pr list` read-only for in-flight overlap.
7. File ≤3 issues (`save_issue`, label `hermes-proposed`, format per
   GUARDRAILS). Cap: ≤15 open `hermes-proposed` at any time.
8. `retain` outcome (what was proposed, why, what was skipped) — deliberate,
   in addition to auto_retain.
9. Telegram summary. Human feedback later lands in Hindsight via chat
   (auto_retain) → next run's `reflect` sees it; mental models refresh after
   consolidation.

## 6. Security model

- Network: box exposes only 22/80/443 (Hetzner Cloud Firewall, edge-applied).
  Hindsight :8888 only via proxy + TLS; :9999 never published.
- Auth: Hindsight bearer (tenant key) — **hard gate**: no Hermes wiring until
  unauthenticated `tools/list` returns 401.
- Capability, not prompt, prevents destruction: GBrain destructive tools not
  in Hermes's allowlist; Hindsight bank `mcp_enabled_tools` excludes all
  delete/admin tools server-side; Linear allowlist has no delete/update-state
  tools; GitHub token cannot write.
- Secrets: never in the repo; Coolify secret env, Railway env, `/data` 0600.
  GUARDRAILS forbids echoing secrets into either memory or Linear.
- Backups: GCS bucket separate from product data; HMAC key scoped to it.

## 7. Failure modes and handling

| Failure | Behaviour | Mitigation |
|---|---|---|
| Hindsight unreachable during a run | plugin degrades: no auto-recall/retain; run proceeds on GBrain + guardrails | acceptable for a scout; run summary must state "memory tier unavailable" (prompt instruction) |
| Gemini model id rejected | Hindsight retain fails at extraction | `HINDSIGHT_LLM_MODEL` env swap to `gemini-2.5-flash`, redeploy |
| Box OOM | Coolify restarts containers | 2G swap; remote embeddings; `restart: always`; verify `dmesg` after first day |
| Mental models empty | agent starts every run "blind" | `tags_match: any` set at creation; §8 check "non-empty after first refresh" |
| Bootstrap re-run | duplicates | idempotent checks (§4.2) |
| Docs push redeploys Hermes | gateway restart mid-run | `watchPatterns` (D2) |
| Coolify dashboard exposed | credential/box takeover | firewall + FQDN behind Coolify login; `nmap` verification |
| Backup never restored | silent data loss | one proven restore is an acceptance criterion |

## 8. Verification (acceptance)

Phase gates, in order — each must pass before the next:

1. Firewall + swap: external `nmap -Pn <ip>` shows only 22/80/443; `swapon --show` lists 2G.
2. DNS + domain: `https://hindsight.<zone>` resolves, cert issued.
3. Stack up: both containers healthy; logs clean of auth/model errors.
4. **Auth gate**: unauthenticated `tools/list` → 401; with bearer → 200. Hard stop on failure.
5. Bank: `hermes-agent` exists; 3 directives; 2 mental models, **non-empty after first refresh**; lockdown applied (a `delete_directive` call via MCP is rejected).
6. Backups: one scheduled run landed in the bucket AND one restore into a scratch DB succeeded.
7. Hermes wiring: `hermes memory status` (over `railway ssh`) shows hindsight/local_external; a fact retained in one chat recalls in a new session; Hermes's tool list has no destructive GBrain/Hindsight tools; `code_callers` on a known function returns real call sites; push from the Hermes box fails.
8. Cron: one manual `hermes cron run scout` produces a compliant test issue (label, `path:line` + SHA, no dupe) and a Telegram summary.
9. Redeploy Hermes: config, OAuth tokens, clone survive on `/data`.
10. Observation: 2 weeks at Mon/Wed/Fri before any cadence increase.

Automated where possible: `ops/hindsight/verify.sh` runs 1 (nmap), 2, 4, 5
(directive/model counts, lockdown probe) and prints PASS/FAIL per check.

## 9. Secrets manifest

| Secret | Minted where | Set where |
|---|---|---|
| `HINDSIGHT_DB_PASSWORD` | `openssl rand -hex 32` | Coolify env |
| `HINDSIGHT_TENANT_API_KEY` | `openssl rand -hex 32` | Coolify env; Railway Hermes as `HINDSIGHT_API_KEY` |
| `GEMINI_API_KEY` | AI Studio, non-product GCP project (Rick) | Coolify env |
| `OPENAI_API_KEY` | existing (GBrain service) | Coolify env |
| GCS HMAC key/secret | GCS console, bucket-scoped SA (Rick or agent with role) | Coolify → Storages |
| `GH_TOKEN` | GitHub fine-grained PAT, read-only | Railway Hermes (replaces current) |
| Linear OAuth tokens | paste-back as dedicated identity (Rick) | `HERMES_MCP_LINEAR_JSON` → `/data` |
| Coolify API token, Hetzner API token | Rick | agent's local env for the run only; never committed |

## 10. Inputs still required from Rick (blocking per phase)

| Needed by | Item |
|---|---|
| Phase 1 | Hetzner API token; Coolify API token; SSH access to the box (or Rick runs `box_prep.sh`) |
| Phase 2 | Final zone/subdomain (default `hindsight.curaition.xyz`) + DNS provider access or two A records pasted |
| Phase 3 | AI Studio key from a non-product GCP project |
| Phase 6 | `curaition-hermes-backups` bucket + HMAC key (or a GCP role so the agent can create both) |
| Phase 7 | Dedicated Linear user created; OAuth paste-back at the keyboard; decision machine-account vs personal PAT for GitHub |

## 11. Migration path (recorded, not built)

One Hetzner box per service; the current box stays Hindsight's home. Later:
Hetzner private network (same Hetzner project) → new boxes for GBrain and
Hermes → added to the existing Coolify as servers over SSH → GBrain
`pg_dump`/restore, Hermes `/data` tar. Every inter-service URL is already an
env var, so each connection is a one-variable swap. Prerequisites to do early:
a checked-in Dockerfile for GBrain (Hermes already has one), external uptime
check before the box is the only home of agent + memory.
