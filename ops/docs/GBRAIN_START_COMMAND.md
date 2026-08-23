# GBrain Railway Service — Start Command & Worker Lifecycle

**Status:** Operational fix in place (2026-08-23) · Durable fix pending upstream
**Linear:** CUR-1447 (this document) · CUR-1445 (incident, resolved) · CUR-1433 (historical context)
**Applies to:** the `GBrain` service in Railway project `peaceful-rejoicing`

---

## 1. Why the start command looks the way it does

The GBrain container runs everything through Bun from source (`bun run src/cli.ts …`)
— there is **no `gbrain` binary on `$PATH`** inside the image. This has a
non-obvious consequence documented here so nobody "simplifies" the start
command back into a wedge.

### The structural bug (`resolveGbrainCliPath`)

`src/commands/autopilot.ts:204-252` (gbrain v0.46.25.0) resolves the CLI path
for any *child-process spawn* — supervisor → worker, autopilot → worker — via:

1. `which gbrain` on `$PATH`, or
2. `process.execPath` ending in `/gbrain`, or
3. `process.argv[1]` ending in `/gbrain`

On this deployment none hold: `execPath` is `…/bin/bun` and `argv[1]` is
`/app/src/cli.ts`. Every attempt to run `jobs supervisor` or `autopilot`
therefore throws *"Could not resolve the gbrain CLI path"* **~90–360 s after
boot**, exactly when its delayed worker spawn fires. Confirmed verbatim in
Railway deploy logs on 2026-08-23.

This was the root cause of the original queue wedge (CUR-1445): the supervisor
was structurally non-viable on this image, not merely stalled.

### The working pattern (Option A)

```bash
sh -c 'bun run src/cli.ts config set search.reranker.enabled false; \
( sleep 90 && bun run src/cli.ts jobs work --concurrency 2 ) & \
exec bun run src/cli.ts serve --http --port 3131 --bind 0.0.0.0 \
  --public-url https://gbrain-production-97af.up.railway.app'
```

Key properties:

| Element | Why |
|---|---|
| `sleep 90` before the worker | lets `serve` win the DB-migration race; do not reduce below ~60 s |
| `( … ) &` subshell | backgrounds the worker without a long-lived shell parent |
| `jobs work` (not `jobs supervisor`) | runs the worker **in-process** — no child-spawn, no CLI-path resolution |
| `exec bun … serve` | server becomes PID 1 so Railway healthcheck/restart semantics track it |

**Trade-off accepted:** no auto-restart if the worker crashes. Mitigation: the
daily `gbrain_check.py` suite carries a `C5.queue-wedge` probe that reads
`get_job_stats.wedged` directly (doctor's depth/stall-based `queue_health`
cannot detect this failure shape) and alerts Telegram on failure. A silent
re-wedge can no longer hide.

## 2. Env-var contract

| Variable | Value | Role |
|---|---|---|
| `GBRAIN_CHAT_MODEL` | `openrouter:anthropic/claude-sonnet-4.6` | pins chat lane to OpenRouter |
| `GBRAIN_EXPANSION_MODEL` | `openrouter:google/gemini-3-flash-preview` | pins query-expansion lane |
| `OPENROUTER_API_KEY` | (secret) | credential for both lanes above |
| `GBRAIN_EMBEDDING_MODEL` | `openai:text-embedding-3-small` | **never change** — sizes the vector column |
| `GBRAIN_EMBEDDING_DIMENSIONS` | `1536` | **never change** — see CUR-1433 |
| `OPENAI_API_KEY` | (secret) | embedding-lane credential only |

⚠️ Removing `OPENAI_API_KEY` breaks the **embedding** backfill too (embed jobs
die with "requires OPENAI_API_KEY") even though all LLM lanes are pinned to
OpenRouter. Embeddings cannot route through OpenRouter. Because chat/expansion
are env-pinned, keeping the OpenAI key does not reopen model tier
auto-discovery (`refreshLatestOpenAIModels()`) on those lanes — env pins outrank it.
Residual discovery surface: auxiliary passes (enrich/dream-style); watch the
OpenAI Responses log after future cycles.

⚠️ Never repoint `GBRAIN_EMBEDDING_MODEL` at Voyage despite `VOYAGE_API_KEY`
being present — changing embedding models strands all ~38,800 existing chunks.

## 3. Verification procedure (after any redeploy)

Wait ≥4 min post-boot (90 s delay + first poll), then check via MCP with an
admin-scoped token:

```
get_job_stats   → wedged == false, queue_health.waiting draining
list_jobs       → new jobs show attempts_started >= 1
get_health      → missing_embeddings trending to 0 after sync events
```

Full regression: run the daily check suite
(`hermes-agent` cron `d500d6809dac`, script `/data/.hermes/scripts/gbrain_check.py`).
Expected clean result: 16 passed / 0 failed.

Known-benign finding: dead-letter entries older than the current fix window
(e.g. zembed-era jobs from the CUR-1433 incident). `dead` is a terminal status;
`cancel_job` correctly refuses them. Ignore unless count grows.

## 4. Durable upstream fix (pending)

File against `garrytan/gbrain`: build a real entrypoint binary in the Dockerfile
so child-spawning code paths work out of the box:

```dockerfile
RUN bun build ./src/cli.ts --compile --outfile /usr/local/bin/gbrain
```

(or minimally: `ln -s` / shim script onto PATH during image build). Once
`which gbrain` succeeds, the supported topology returns:

- `jobs supervisor` regains crash-restart/backoff semantics (max 10 restarts)
- `autopilot` becomes viable again (worker supervision + full dream/sync cycles)

Until then, treat any start-command revision as suspect if it introduces
supervisor/autopilot, and re-run the §3 verification.
