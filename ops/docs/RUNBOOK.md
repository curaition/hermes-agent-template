# Hermes Memory Architecture — Two-Tier (GBrain + Hindsight)

Supersedes `docs/ops/hermes-hindsight/` and `docs/ops/hermes-gbrain/` (both
2026-08-15, both in `docs/ops/_to_delete/`). This is the final consolidation of
a same-day design evolution — decision log in §1.

```
Railway project "peaceful-rejoicing" (europe-west4)
├── Hermes Agent   (curaition/hermes-agent-template fork, /data volume)
│     ├─ MCP → GBrain (private net)          — knowledge tier
│     ├─ hindsight plugin → Hetzner (HTTPS)  — agent-memory tier
│     ├─ MCP → Linear (hosted, OAuth)        — output: issues
│     └─ read-only clone of curaition-xyz/curaition
├── GBrain         (Bun, :3131, private endpoint `gbrain`)
└── Postgres       (GBrain's DB)

Hetzner box (Coolify)                        ← long-term home for everything
└── Hindsight stack: pgvector Postgres + hindsight
      API+MCP :8888 behind Coolify HTTPS proxy, ApiKeyTenantExtension auth
```

## 0. Handover: execution order, preflight, open items

### 0.1 Human-only preflight (Rick — nothing below proceeds without these)

- [ ] Choose the Hindsight subdomain and replace `hindsight.<domain>` throughout
- [ ] Decide Coolify dashboard access: FQDN (recommended — also needed for the Coolify MCP endpoint, §3.1) or SSH tunnel
- [ ] Create DNS A record(s) → box IP
- [ ] GCS: create HMAC key on a bucket-scoped service account (§3.3), note access key/secret
- [ ] GitHub: create machine account + fine-grained PAT (`curaition-xyz/curaition`, Contents: Read + Metadata: Read only); audit/rotate the existing `GH_TOKEN` on Railway down to this
- [x] Linear: create the `hermes` label in team CUR (done — created as `hermes-proposed`, renamed to `hermes` 2026-08-16 alongside 11 new area labels); decide whether Hermes gets a dedicated Linear identity; be available for the OAuth paste-back during phase 7
- [ ] Confirm Gemini AI Studio key available for Hindsight extraction

### 0.2 Execution phases (in order; each gate must pass before the next)

| # | Phase | Script / action | Acceptance |
|---|---|---|---|
| 1 | Firewall + swap | `hetzner_firewall.sh`; `ssh root@box 'bash -s' < box_prep.sh` | `verify.sh` firewall PASS; `swapon --show` 2G |
| 2 | DNS + Coolify FQDN + S3 storage (UI) | A records; Coolify Settings → Instance FQDN; Storages → add GCS | `https://coolify.<zone>` login page; storage saved |
| 3 | Deploy DB + stack | `coolify_apply.sh` | service `running`; logs clean |
| 4 | Auth gate | `verify.sh` (auth lines) | 401/200 — HARD GATE |
| 5 | Bootstrap bank | `bootstrap_hindsight.sh` → tunnel check → `--lockdown` | `verify.sh` all PASS (models may WARN) |
| 6 | Backups | `coolify_backup.sh` + one manual restore | dump in bucket AND restore proven |
| 7 | Hermes wiring | set Railway env per `ops/hermes/env.example` (`HINDSIGHT_API_URL`, `HINDSIGHT_API_KEY`, `HERMES_MEMORY_PROVIDER=hindsight`, `HERMES_HINDSIGHT_CONFIG_JSON`, `HERMES_MCP_SERVERS_YAML`, `HERMES_SOUL_MD`, `LINEAR_API_KEY`, read-only `GH_TOKEN`); redeploy | `hermes memory status` shows hindsight; round-trip fact |
| 8 | Cron | `cron_install.sh` + manual run | compliant test issue + Telegram summary |
| 9 | Full checklist | spec §8 | all boxes |
| 10 | Observation | 2 weeks Mon/Wed/Fri | judged before scaling |

Phases 1–6 are agent-executable given SSH/Coolify access (or Rick-executable
from this doc). Phase 7's OAuth step and any Railway env changes need Rick.

### 0.3 Secrets manifest

| Secret | Minted where | Set where |
|---|---|---|
| `HINDSIGHT_DB_PASSWORD` | `openssl rand -hex 32` | Coolify stack env |
| `HINDSIGHT_TENANT_API_KEY` | `openssl rand -hex 32` | Coolify stack env AND Hermes Railway env (`HINDSIGHT_API_KEY`) |
| `GEMINI_API_KEY` | AI Studio | Coolify stack env |
| `OPENAI_API_KEY` | existing (on GBrain service) | Coolify stack env |
| GCS HMAC key/secret | GCS console (§3.3) | Coolify → Storages |
| `GH_TOKEN` (read-only, machine acct) | GitHub | Hermes Railway env (replace current) |
| Linear OAuth tokens | interactive paste-back | Hermes `/data/.hermes` (automatic) |
| `HERMES_GBRAIN_TOKEN` | existing | already on Railway |

### 0.4 Known unknowns (verify at point of use — flagged inline)

Gemini model id accepted by Hindsight (§4) · Hermes hindsight plugin config key
names (§6.1 — wizard's file is canonical) · `hermes cron` CLI syntax (§6.3) ·
GBrain's MCP path on :3131 (§6.2) · exact OpenAI embeddings env var name (§4).
None blocks starting; each is resolvable in under five minutes at its phase.

Resolved 2026-08-15: env var names verified against Hindsight docs; plugin
keys `mode/api_url/bank_id/memory_mode`; `hermes cron create <sched> <prompt>
--name --deliver --workdir`; GBrain MCP path `/mcp`.

## 1. Decision log (2026-08-15)

1. Memory provider evaluation → Hindsight picked over Mem0/Honcho/etc.
2. Hindsight-on-Hetzner plan drafted (draft-PR agent) → superseded.
3. Hermes found to be on Railway with GBrain colocated → Hindsight dropped,
   GBrain-only; Hermes role changed to **Linear issue scout, no code writes**;
   sequencing: wire on Railway now, port to Hetzner later (cost + OSS driver).
4. **Correction:** self-hosted Hindsight DOES have built-in inbound auth
   (`ApiKeyTenantExtension`) — the earlier "no auth, external only" claim was
   wrong. Its MCP server (27–30 tools) also includes **directives** and
   **auto-refreshing mental models**, which have no GBrain equivalent.
5. Final: **two-tier memory.** GBrain = knowledge; Hindsight = Hermes's own
   agent memory, hosted on Hetzner/Coolify (fixed cost, OSS, already at the
   migration destination). Strict content boundary — nothing double-written.

## 2. The tier boundary (the rule that prevents split-brain)

The stores never hold the same kind of content. **Amended 2026-09-03: this is now
THREE stores, not two.** Claude Code seeded a Hindsight bank of codebase *rationale*
(`coding-agent::curaition`) and Hermes reads it — see §6.5. The original two-column table
said Hindsight "never contains codebase documentation", which that bank plainly does, so
the boundary is restated by the QUESTION each store answers rather than by product:

| | **GBrain** (Railway, knowledge) | **Hindsight `hermes-agent`** (agent memory) | **Hindsight `coding-agent::curaition`** (codebase rationale) |
|---|---|---|---|
| Holds | Codebase intelligence (code graph), entities, curated pages, facts about the world/product | Hermes's run learnings, proposal outcomes, review-feedback patterns, standing directives, mental models of its own work | Decisions and their rationale, conventions, architecture choices, in-flight initiatives — extracted from Claude Code sessions and commit messages |
| Question it answers | "**Where** is it, and what is structurally true?" | "What have **I** done, learned, and been told?" | "**Why** is it this way?" |
| Hermes reads via | `query`, `recall`, `get_page`, `code_*`, `think` | auto_recall (plugin), `reflect`, mental models | `codebase_memory` MCP server — `recall`, `reflect`, mental models |
| Hermes writes via | `put_page` / `extract_facts` — curated knowledge only | `retain` (auto + deliberate) — experiences only | **NEVER.** Read-only, enforced server-side |
| Written by | Hermes | Hermes | Claude Code only |
| Never contains | Hermes's diary | Codebase documentation | Code structure ("where"), or Hermes's own inferences |

If a piece of content could go to more than one, it goes to the one matching its
*kind*, never both.

**Why the third store is read-only to Hermes.** Not caution — a correctness rail. If
Hermes could `retain` there, its own inferences would consolidate into observations and it
would read them back as codebase fact: a self-confirming loop in which speculation hardens
into ground truth. The "why" store is only trustworthy while its sole writer is the agent
actually making the changes. Enforced in two places (client allowlist in
`ops/hermes/mcp_servers.yaml`, server-side `mcp_enabled_tools` via
`ops/hindsight/lockdown_coding_bank.sh`), because the tenant bearer is shared.

## 3. Environment prerequisites (the actual box — captured 2026-08-15)

**Server:** Hetzner, x86_64, **2 cores / 3.7GB RAM**, Ubuntu 26.04 LTS, Coolify
installed. Consequences of the spec:

- **Embeddings run remotely, not locally.** Hindsight's default local
  BAAI/bge-small model would hold ~0.5–1GB resident next to Coolify's own
  containers (~1GB) and Postgres — on 3.7GB that invites the OOM killer. The
  compose below uses OpenAI embeddings instead (`text-embedding-3-small`-class;
  you already hold an `OPENAI_API_KEY` on the GBrain service). Cost is
  negligible at this bank's write volume.
- **Add 2GB swap** before deploying (safety margin, not a performance plan):
  `fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile`
  (+ `/etc/fstab` entry).
- **This box cannot absorb the full Railway migration** (§8). Hindsight alone
  fits; GBrain + Hermes + their Postgres on top will not. When migration day
  comes, resize (Hetzner cloud volumes/rescale) or add a second box — factor
  that into the cost comparison now so the "port later" plan stays honest.

**3.1 Firewall — do this before anything is deployed** (currently: nothing
configured). Use a Hetzner Cloud Firewall (applied at the network edge, can't
be wiped by a bad ufw rule; ufw equivalent is fine on a dedicated box):

- Allow in: **22** (restrict source to your IP if it's stable), **80**, **443**.
- Deny everything else — explicitly including **8000/6001/6002** (Coolify's
  dashboard + realtime ports) and **8888/9999** (Hindsight, which must only
  ever be reached through the proxy).
- Coolify dashboard access after closing 8000: either set an instance FQDN in
  Coolify settings (e.g. `coolify.<domain>`) so it's served via the proxy with
  TLS + login, or SSH-tunnel (`ssh -L 8000:127.0.0.1:8000 <box>`). Pick one now;
  an Internet-exposed Coolify dashboard is a bigger risk than anything else in
  this document. Note: Coolify's read-only MCP server (Settings → Advanced)
  lives at `/mcp` on the same domain — connecting AI clients (Claude Desktop
  via mcp-remote bridge, Claude Code via `claude mcp add --transport http`)
  needs the FQDN too, which tips the choice toward FQDN over tunnel.
- Verify from outside when done: `nmap -Pn <box-ip>` from your Mac should show
  only 22/80/443.

**3.2 DNS.** Create an A record for the chosen subdomain (placeholder
`hindsight.<domain>` throughout — you said a spare subdomain/wildcard is
available; substitute the real one) → box IP, before attaching the domain in
Coolify so Let's Encrypt issuance succeeds on first try.

**3.3 Backups → your GCS bucket.** Coolify's scheduled backups speak S3; GCS
supports that via interoperability mode:

1. GCS console → Settings → Interoperability → create an **HMAC key** for a
   service account scoped to the bucket (Storage Object Admin on that bucket
   only).
2. Coolify → Storages → add S3 storage: endpoint `https://storage.googleapis.com`,
   bucket name, HMAC access key/secret, region as configured on the bucket.
3. After the Hindsight stack exists, enable a scheduled backup on the `db`
   service (daily is fine) targeting that storage — and restore one dump once
   to prove the path works before the bank holds anything you'd mind losing.

## 4. Hindsight on Coolify (Hetzner)

Compose is `ops/hindsight/docker-compose.yaml` (app only). Postgres is a
Coolify **database resource** `hindsight-db` (`pgvector/pgvector:pg17`) so
`POST /databases/{uuid}/backups` applies; `coolify_apply.sh` creates both
resources (project → database → Docker Compose service) via the Coolify API
and connects the stack to the predefined network.

Secrets (Coolify env, marked secret): `HINDSIGHT_DB_PASSWORD` and
`HINDSIGHT_TENANT_API_KEY` (both `openssl rand -hex 32`), `GEMINI_API_KEY`
(AI Studio key — Gemini API path, not Vertex), `OPENAI_API_KEY` (embeddings —
same key already on the GBrain Railway service). If the Gemini model id is
rejected, fall back to `gemini-2.5-flash`.

Networking:
- Attach a Coolify domain with HTTPS to the `hindsight` service → port **8888**,
  e.g. `https://hindsight.<zone>`. The API, SDK, and MCP endpoint
  (`/mcp/{bank_id}/`, enabled by default) all live on 8888.
- Do NOT expose the control-plane UI (**9999**) — no documented auth of its own.
  Use it via SSH tunnel: `ssh -L 9999:<hindsight-container-ip>:9999 <hetzner>`
  (or temporarily publish `127.0.0.1:9999:9999` and tunnel to that).
- Verify auth is actually on before wiring anything:
  `curl -s -o /dev/null -w '%{http_code}' https://hindsight.<domain>/mcp/ -X POST -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","method":"tools/list","id":1}'`
  → must be **401** without the bearer, 200 with it.

Backups: wire the `db` service to the GCS storage per §3.3 before this bank
accumulates anything you'd mind losing.

## 5. Bootstrap the bank

Run `bootstrap_hindsight.sh` (alongside this runbook) after deploy — it uses
the documented MCP JSON-RPC surface to create bank **`hermes-agent`** and seed
it. What it sets and why:

- **Bank mission + `retain_mission`** — steers extraction toward run learnings,
  proposal outcomes, and feedback patterns (and away from re-memorizing code).
- **`disposition_skepticism: 4`** — reflect() should critically evaluate its
  own past conclusions, not compound them.
- **Directives** (standing rules stored IN memory, loaded into every reflect —
  tunable later via MCP without redeploying Hermes):
  1. Never re-propose a candidate that was rejected unless the cited code has
     materially changed; say so explicitly when it has.
  2. Weight human review feedback above your own priors when they conflict.
  3. Anything touching Celery signatures, DB schema, billing, or the video
     pipeline's time-limit machinery is [NEEDS HUMAN DRIVER] — analysis only.
- **Mental models** (auto-refreshing, `trigger_refresh_after_consolidation: true`):
  - `refactor-landscape` — "What areas of the codebase have open proposals,
    recent findings, or known debt, and what is their status?"
  - `proposal-outcomes` — "Which proposals were implemented, which rejected,
    and what patterns distinguish them?"
  - ⚠ Both created with `tags_match: "any"` — tagged models default to
    `all_strict`, which silently yields EMPTY content unless every memory
    carries every model tag (documented footgun).

Hermes then reads both mental models at the start of each run — one call each,
instead of re-synthesizing its history nightly.

## 6. Hermes wiring (Railway side)

**Env is the source of truth and is re-applied every boot.** `start.sh` sources
`bootstrap/hindsight_wiring.sh` and calls `materialize_hindsight_wiring /data`
unconditionally on every start, which (re)writes `/data/.hermes/hindsight/config.json`
and patches `/data/.hermes/config.yaml`'s `memory.provider` and `mcp_servers.*`
from the env vars below. **Any manual `hermes memory setup` wizard run or
hand-run `hermes mcp configure gbrain` edit on the box is overwritten on the
next boot** — treat those CLI tools as read-only inspection here, not as the
way to change wiring. To change wiring, change the env var and redeploy.

### 6.1 Hindsight (agent-memory tier)

Generate the config from the committed template (substituting the real zone)
and set it, plus the URL/key/provider vars, on the Railway service:

```bash
HERMES_HINDSIGHT_CONFIG_JSON=$(sed 's/<zone>/curaition.xyz/' ops/hermes/hindsight.config.json | base64 | tr -d '\n')
railway variables --service "Hermes Agent" --set HERMES_HINDSIGHT_CONFIG_JSON="$HERMES_HINDSIGHT_CONFIG_JSON"
railway variables --service "Hermes Agent" --set HINDSIGHT_API_URL=https://hindsight.curaition.xyz
railway variables --service "Hermes Agent" --set HINDSIGHT_API_KEY=<tenant key>
railway variables --service "Hermes Agent" --set HERMES_MEMORY_PROVIDER=hindsight
```

`ops/hermes/hindsight.config.json` bakes in `mode: local_external`,
`bank_id: hermes-agent`, `memory_mode: hybrid`, `auto_recall: true`,
`auto_retain: true`, `recall_budget: mid`. `hybrid` + auto_recall/auto_retain
is the point of this tier: Hermes's experiences accrue without tool-call
discipline, and recalled context injects every turn. Latency note: Hetzner
(DE) ↔ Railway europe-west4 (NL) is single-digit ms — auto_recall per turn is
fine.

### 6.2 GBrain (knowledge tier)

Also env-driven, via the same materialization — the allowlist lives in
`ops/hermes/mcp_servers.yaml` (committed) and ships to Railway as one base64
env var:

```bash
HERMES_MCP_SERVERS_YAML=$(base64 < ops/hermes/mcp_servers.yaml | tr -d '\n')
railway variables --service "Hermes Agent" --set HERMES_MCP_SERVERS_YAML="$HERMES_MCP_SERVERS_YAML"
```

`ops/hermes/mcp_servers.yaml` trims the ~90 available GBrain tools down to a
named allowlist. The trim removes ONLY destructive/admin surface — **Hermes
keeps full write access for adding knowledge**:

- Read/recall: `query`, `search`, `recall`, `get_page`, `get_chunks`,
  `get_backlinks`, `get_links`, `get_timeline`, `volunteer_context`
- Code intelligence: `code_def`, `code_refs`, `code_callers`, `code_callees`,
  `code_flow`, `code_blast`
- Writes (kept): `put_page`, `extract_facts`, `add_timeline_entry`, `add_tag`,
  `add_link`
- Synthesis: `think`

Excluded: `delete_page`, `forget_fact`, `revert_version`, `restore_page`,
`schema_apply_mutations`, `reload_schema_pack`, job-control tools, `run_skillopt`,
`sources_remove`. The agent must not be *able* to destroy memory, regardless of
prompt. (On the Hindsight side the same principle applies server-side: set the
bank's `mcp_enabled_tools` to exclude `delete_bank`, `clear_memories`,
`delete_document`, `delete_directive`, `delete_mental_model` — Hermes's own
directives/models are managed by you, not by it.)

### 6.3 Linear, repo, guardrails, cron

Unchanged from the previous iteration:

- **Linear:** verify `HERMES_MCP_LINEAR_JSON` → `https://mcp.linear.app/mcp`
  (OAuth, headless paste-back, tokens on `/data`). Create the `hermes`
  label in team CUR once. Trim to: `list_issues`/`search`, `get_issue`,
  `save_issue`, `list_issue_labels`, `save_comment`. Consider a dedicated
  Linear identity for attribution/revocation.
- **Repo:** `GH_TOKEN` must be a fine-grained PAT, `curaition-xyz/curaition`
  only, **Contents: Read + Metadata: Read** — rotate down if it has write.
  Add **Pull requests: Read** too — the scout runs `gh pr list` for in-flight
  overlap and a Contents-only PAT gets `Resource not accessible by personal
  access token`. ⚠️ **Hermes strips `GH_TOKEN` from every terminal/execute_code
  subprocess** (provider blocklist, not overridable by `terminal.env_passthrough`)
  and the agent's shell runs with `HOME=/data/.hermes/home`, so git/gh inside
  the agent authenticate ONLY via `/data/.hermes/home/.git-credentials` +
  `/data/.hermes/home/.config/gh/hosts.yml`. `start.sh` rewrites both from
  `GH_TOKEN` at every boot (env is the truth). A stale store there = silent
  anonymous 403s in the scout with an "ok" run status (2026-08-16).
  Clone to `/data/work/curaition`; each run starts
  `git fetch origin && git reset --hard origin/staging`; issues cite the SHA.
- **Guardrails:** `ops/GUARDRAILS.md` is delivered as the tail of Hermes's
  **`SOUL.md`** (system persona), env-declared and re-applied every boot:
  `railway variables --service "Hermes Agent" --set "HERMES_SOUL_MD=$(bash ops/hermes/render_soul.sh | base64 | tr -d '\n')"`.
  `render_soul.sh` = `ops/hermes/soul_prefix.md` (stock persona paragraph) +
  `GUARDRAILS.md`. Editing the env var and redeploying IS the change path
  (a bad paste is ignored with a WARN and the previous file kept).
  Why not `USER.md` (the spec's original choice): `memories/USER.md` is the
  agent-written user profile — the live volume holds real profile memory there,
  `HERMES_USER_MD` seeds a real profile on fresh volumes, and Hermes caps it at
  `user_char_limit` 1,375 chars vs the ~6 KB guardrails. Leave `HERMES_USER_MD`
  and `USER.md` alone. (Found live 2026-08-16.)
- **Cron memory tier:** Hermes hard-codes `skip_memory=True` for cron jobs
  (`cron/scheduler.py`), so the Hindsight *plugin* (auto-recall/retain) is
  active only in chat sessions. Cron sessions get the same bank through the
  `hindsight` entry in `ops/hermes/mcp_servers.yaml` (bank-scoped MCP endpoint,
  bearer `HINDSIGHT_API_KEY`, include ⊆ the 15-tool lockdown) and the prompts
  call `mcp_hindsight_reflect` / `_retain` / `_get_mental_model` explicitly.
  Also: paused jobs are NOT fired by `hermes cron run` — for a manual pass do
  `resume` → `run` → (wait until `last_run_at` moves) → `pause`. And **`hermes cron
  list` hides paused jobs** — always `--all` when checking what exists, or the
  installed-and-paused jobs look absent (this blinded `cron_install.sh`'s duplicate
  guard until 2026-08-16; it now queries `--all`).
- **Cron:** `ops/hermes/cron_install.sh` creates all three jobs and leaves them
  PAUSED — scout `0 2 * * 1,3,5`, hygiene `0 3 * * 0`, atlas `0 4 * * *`, all
  `--deliver telegram --workdir /data/work/curaition`. Run a manual pass
  (`hermes cron run <id>`) and judge the output before enabling the schedule
  with `hermes cron resume <id>`. Scale only after ~2 weeks of judging issue
  quality — triage attention is the binding resource.

### 6.4 The atlas sweep (`hermes-atlas`)

A daily walk through the codebase that produces **dossiers**, with tickets as a
by-product — the scout finds defects, the sweep builds the map the scout reads.

- **Split:** code ships in the image (`bootstrap/atlas/{atlas.sh,seed_coverage.sh}`
  → `/app/bootstrap/atlas/`, refreshed by every deploy), state lives on the volume
  (`/data/work/atlas/coverage.tsv`, created by `start.sh`). Never copy the scripts
  to `/data` — that is how you get stale bookkeeping logic surviving a redeploy.
  Nothing here is an env var, so unlike `HERMES_MCP_SERVERS_YAML` / `HERMES_SOUL_MD`
  a merge + deploy IS the whole change path.
- **Queue:** `seed_coverage.sh` derives sweep units from the tree — directories
  under `src/crypto_newsletter` (depth 1-2) with at least one `.py` **at that
  level**, ordered by LOC descending. 90 units at `7bc282e76`. Re-running it is
  safe and expected (the prompt does it every run): done rows keep their history,
  new modules append as `pending`, vanished ones flip to `gone`.
- **Handout:** `atlas.sh next --count 3` gives pending modules in queue order;
  once the lap is done it switches to revisit mode, offering only modules with
  commits **after the SHA their dossier was written at** (SHA range, not
  `--since`: `git log --since` is inclusive at second granularity and re-offers a
  module you just finished). Empty output = queue clean = the run replies `[SILENT]`.
- **Recording:** `atlas.sh done <module> --sha … --page … --evidence path:line
  [--tickets CUR-n,CUR-m]`. All four validations are enforced in the script, not
  the prompt — a run cannot mark a module read without naming the dossier it wrote
  and a line it read. Tickets accumulate across visits.
- **Pace:** 3 modules/run daily → first lap ≈ 30 days, then steady-state revisit.
  Inspect any time with `atlas.sh stats` (`modules N | pending | done | gone | lap %`).
- **First run:** same dance as the scout — `resume` → `run` → wait → `pause`, then
  read the dossiers it wrote (`get_page code/<slug>`) before trusting the schedule.
  Judge the dossiers, not the ticket count.

### 6.5 Codebase-rationale bank (`codebase_memory`) — read-only

Wires Hermes to the Hindsight bank Claude Code writes, so backlog work is grounded in the
recorded *reason* for a convention rather than re-derived from the diff. Bank
`coding-agent::curaition`, seeded 2026-09-03; provenance and the applied config live in
the main repo at `docs/ops/hindsight/HANDOVER-coding-agents.md` §11.

**Order matters: lock the bank down BEFORE handing Hermes the URL.**

**1. Server-side read-only allowlist.** The Claude Code integration does not set
`mcp_enabled_tools`, so the bank's `/mcp/` endpoint exposes 29 tools including
`delete_bank`, `clear_memories` and `delete_document` (measured 2026-09-03;
`hermes-agent` exposes 15 and nothing destructive). The bearer is shared, so this must be
closed server-side, not just in the client allowlist:

```bash
export HINDSIGHT_URL=https://hindsight.curaition.xyz
export HINDSIGHT_TENANT_API_KEY=<tenant key>
./ops/hindsight/lockdown_coding_bank.sh --dry-run   # prints before/after, changes nothing
./ops/hindsight/lockdown_coding_bank.sh             # applies + verifies exact read-back
```

Expect `lockdown verified: 11 read-only tools`. The script aborts unless an
unauthenticated `initialize` returns 401, and fails loudly on a partial apply — note
`update_bank` is itself excluded by the new allowlist, so it cannot re-run to repair one.
Recovery is REST: `PATCH $HINDSIGHT_URL/v1/default/banks/coding-agent::curaition/config`
with `{"updates":{...}}` and bearer auth.

**2. Ship the MCP server entry.** WARNING: **merging this PR does not deploy it.**
`railway.toml` `watchPatterns` deliberately excludes `ops/**`, and
`HERMES_MCP_SERVERS_YAML` is a declarative env var built from the file **by hand**. After
PR #8 the deploy was green while the live config still had no `hindsight` server at all.

```bash
railway variables --service "Hermes Agent" \
  --set HERMES_MCP_SERVERS_YAML="$(base64 < ops/hermes/mcp_servers.yaml | tr -d '\n')"
railway redeploy --service "Hermes Agent" -y
```

**3. Verify live, not from the deploy's exit code.** Diff live-vs-repo before trusting a
run — the failure mode here is a green deploy with stale config:

```bash
railway ssh -p 5a884f8f-dd5a-4bc3-829f-090e16b7a194 -s ebd1445c-d175-44e9-a662-b3041fe3dae3 \
  -e b8daa185-8abb-487f-93aa-232980b06415 -- hermes mcp list      # codebase_memory present?
railway ssh ... -- hermes mcp test codebase_memory                 # handshake + tool count
```

Want: `codebase_memory` listed, and exactly the five allowlisted tools (`recall`,
`reflect`, `list_mental_models`, `get_mental_model`, `get_bank`) — no `retain`.

**4. Name it in the prompts.** MCP tools do load in cron, but the agent only uses what the
prompt tells it to (the reason §6.1's plugin tier needed this server at all). For the scout
to benefit, `ops/hermes/prompts/*.md` must instruct it to consult `codebase_memory` —
mental models first (the five curated pages are the distilled "why"), `reflect` only when
those are too shallow. **Not done in this PR** — prompt changes are a separate, reviewable
concern.

**Does this affect Claude Code?** No. Its `hindsight_*` tools are served by a local Node
MCP server that calls the REST API (`/v1/...`), not the `/mcp/` endpoint that
`mcp_enabled_tools` gates. Confirm after step 1 anyway: a session in the repo should still
print its bank banner and answer `hindsight_sync_status`.

## 7. Verification checklist

- [x] 2026-08-16 — From outside (your Mac): `nmap -Pn <box-ip>` shows only 22/80/443 — Coolify dashboard (8000/6001/6002) and Hindsight (8888/9999) unreachable (Hetzner firewall `hermes-memory`, id 11472086; `verify.sh` firewall PASS)
- [x] 2026-08-16 — `free -h` on the box after the stack is up: swap present (2.0 GiB), no OOM kills in `dmesg`
- [x] 2026-08-16 — Hindsight unauthenticated request → 401; with bearer → initialize mints a session and tools/list returns the 15-tool locked-down set on `/mcp/hermes-agent/` (`verify.sh` all PASS)
- [x] 2026-08-16 — Bank `hermes-agent` exists; 3 directives listed; both mental models present with `trigger.tags_match=any` and non-empty (`verify.sh` PASS)
- [x] 2026-08-16 — From a Hermes chat (Telegram): TANGERINE-42 retained into bank `hermes-agent` (doc `20260816_132658_9ba35e86`) and recalled; server log shows Hermes auto-recall + auto-retain on both turns. NB: `hermes -z` one-shots do NOT exercise the plugin (background retain/prefetch, no shutdown) — test via the gateway only
- [x] 2026-08-16 — GBrain: `code_callers` returns real call sites (via Hermes: `_compute_smart_limit` → 13 callers, `code_def _select_due_sources` → `social_tasks.py:119`). Built by **laptop-driven import into the production brain** (CUR-1406 option 1): `gbrain sources add curaition --path ~/Projects/gbrain-src/curaition --federated` (clean `staging` clone) → `gbrain sync --source curaition --repo … --strategy code --no-pull --workers 4` (4,575 files, ~$0.02 embed) → `gbrain extract --stale` → `gbrain edges-backfill --source curaition` looped until `0 chunks walked` (~36k chunks). Two permanent caveats, both written into GUARDRAILS: remote clients must pass `source_id: "curaition"` (bearer tokens default to `default`), and the tree-sitter chunker in gbrain 0.42.53 skips `decorated_definition` (Celery tasks, routes, fixtures) — "no callers" is never dead-code evidence. **Re-sync (before scout runs / weekly):** `cd ~/Projects/gbrain-src/curaition && git pull && GBRAIN_DATABASE_URL=… gbrain sync --source curaition --repo "$PWD" --strategy code --no-pull && gbrain edges-backfill --source curaition` (repeat backfill until 0 walked)
- [x] Hermes files a test issue: `hermes` + area label, file:line + SHA evidence, no dupe — DONE 2026-08-16 (CUR-1407..1411 filed by the atlas sweep; label renamed `hermes-proposed` → `hermes` and 11 area labels added the same day). Cron jobs: atlas `e88814e07b7a` LIVE `0 4 * * *`; scout `f95d0dc87999`, hygiene `ce07cb27de73` still paused
- [x] 2026-08-16 — Push attempt from the Hermes box fails: `git push origin hermes-push-probe` → 403 "Write access to repository not granted" (fine-grained PAT, Contents:R + Metadata:R); fetch works; clone at `/data/work/curaition`
- [x] 2026-08-16 — Hermes lists exactly the 21 allowlisted GBrain tools + `hindsight_retain/recall/reflect` + built-in `memory`; no `delete_*`, `forget_fact`, `revert_version`, `restore_page`, `schema_apply_mutations`, `clear_memories`, `update_bank`
- [x] 2026-08-16 — Redeploy Hermes (GH_TOKEN rotation redeploy): provider, 4 MCP servers, Linear tokens, `/data/work/curaition`, SOUL.md all survived
- [x] 2026-08-16 — Coolify scheduled backup ran at least once (daily, config `9npip7f8yohk2rkpjaj3znj3`; target = **Hetzner Object Storage** bucket `curaition-hermes-backups` in hel1, Coolify storage `hetzner-hermes-backups` — GCS was replaced by Rick's decision) — and the first dump (125,735 B) was downloaded from the bucket and `pg_restore`d into a scratch DB on the box: rc=0, 23 tables, bank/3 directives/2 mental models present; scratch DB dropped afterwards

## 8. Migration path (the rest of Railway → Hetzner, later)

Hindsight is already at the destination. The migration model is **one box per
service (or small cluster), not one big box**: the current 2c/3.7GB server
stays Hindsight's home, and GBrain + Hermes each land on their own Hetzner
server when they move. How that works:

- **One Coolify, many servers.** The existing Coolify instance manages
  additional servers over SSH — it becomes the control plane; new boxes are
  deploy destinations, not new Coolify installs.
- **Hetzner Cloud private network from day one.** Put every box in one private
  network (same location, e.g. Falkenstein): internal hostnames, free unmetered
  inter-service traffic — the direct `railway.internal` equivalent, which is
  why every inter-service URL is an env var. Migration per connection = one
  variable swap; inter-service traffic never touches the public edge.
- **Terminology — "project" means different things in the two consoles.**
  A *Hetzner* project is the container servers, networks, and firewalls live
  in — and a private network can only attach servers in the SAME Hetzner
  project, so all future servers go in the existing one (a separate Hetzner
  project would break private networking). A *Coolify* project is a dashboard
  grouping with no infrastructure meaning — organize per taste. The private
  network itself is created in the Hetzner console/API, not Coolify; sequence:
  create network → attach the existing Hindsight box → create new servers
  already attached → add them to Coolify under Servers via SSH.
- **Isolation preserved.** Per-service boxes restore the failure-domain
  isolation Railway currently provides — a wedged Hermes box can't take the
  memory stores down. The price is per-box firewall rules and OS patching
  (Coolify centralizes deploys and backups; apply §3.1's firewall pattern to
  each new box).

When the time comes: GBrain + its Postgres (`pg_dump`/restore) and Hermes (`/data` volume tar)
come over; `gbrain.railway.internal:3131` becomes a Docker-network hostname;
Hindsight's URL in Hermes config doesn't change at all — or flips to an internal
hostname for less latency. Prerequisites to do early: **checked-in Dockerfiles
for GBrain and the Hermes fork** (both currently Railpack-built — the one
Railway-proprietary dependency), env-var-only URLs, no state outside
Postgres//data. What you take on at full migration: backups, monitoring,
patching, single failure domain — budget an external uptime check before the
box is the only home of agent + memory.
