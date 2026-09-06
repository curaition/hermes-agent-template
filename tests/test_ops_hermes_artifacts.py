import json
import pathlib
from pathlib import Path
import yaml

OPS = Path(__file__).resolve().parents[1] / "ops" / "hermes"

GBRAIN_ALLOW = {"query","search","recall","get_page","get_chunks","get_backlinks","get_links","get_timeline",
                "volunteer_context","code_def","code_refs","code_callers","code_callees","code_flow","code_blast",
                "put_page","extract_facts","add_timeline_entry","add_tag","add_link","think"}
GBRAIN_DENY = {"delete_page","forget_fact","revert_version","restore_page","schema_apply_mutations",
               "reload_schema_pack","run_skillopt","sources_remove","cancel_job","pause_job","resume_job",
               "retry_job","replay_job","submit_job","submit_agent","send_job_message"}
LINEAR_ALLOW = {"list_issues","search_issues","get_issue","save_issue","list_issue_labels","save_comment"}
# Read-only ceiling applied server-side to `coding-agent::curaition` by
# ops/hindsight/lockdown_coding_bank.sh. Hermes must never be able to WRITE this bank:
# its own inferences would consolidate into observations and be read back as codebase
# fact. `retain`/`sync_retain` are absent here on purpose (contrast the hermes-agent
# lockdown, which is read/WRITE) — see RUNBOOK §2 and §6.5.
CODEBASE_READONLY = {"recall","reflect","list_memories","get_memory","list_mental_models",
                     "get_mental_model","list_directives","list_tags","get_bank",
                     "list_documents","get_document"}

def test_mcp_servers_allowlists():
    d = yaml.safe_load((OPS / "mcp_servers.yaml").read_text())
    g = d["gbrain"]
    assert g["url"] == "http://gbrain.railway.internal:3131/mcp"
    assert g["headers"]["Authorization"] == "Bearer ${HERMES_GBRAIN_TOKEN}"
    assert set(g["tools"]["include"]) == GBRAIN_ALLOW
    assert not (set(g["tools"]["include"]) & GBRAIN_DENY)
    assert "exclude" not in g["tools"]          # include wins; no ambiguity
    l = d["linear"]
    assert l["url"] == "https://mcp.linear.app/mcp"
    assert set(l["tools"]["include"]) == LINEAR_ALLOW
    assert set(d) == {"gbrain", "linear", "hindsight", "codebase_memory"}   # never touch CurAItion/youcom entries
    h = d["hindsight"]
    assert h["url"] == "https://hindsight.curaition.xyz/mcp/hermes-agent/"
    assert h["headers"]["Authorization"] == "Bearer ${HINDSIGHT_API_KEY}"
    LOCKDOWN = {"retain","sync_retain","recall","reflect","list_memories","get_memory","list_mental_models","get_mental_model","list_directives","list_tags","get_bank","list_documents","get_document","list_operations","get_operation"}
    assert set(h["tools"]["include"]) <= LOCKDOWN          # never name a tool the bank lockdown removed
    assert not {t for t in h["tools"]["include"] if t.startswith(("delete","update","clear","create"))}

    c = d["codebase_memory"]
    assert c["url"] == "https://hindsight.curaition.xyz/mcp/coding-agent::curaition/"
    assert c["headers"]["Authorization"] == "Bearer ${HINDSIGHT_API_KEY}"   # same tenant bearer
    assert "exclude" not in c["tools"]
    inc = set(c["tools"]["include"])
    assert inc <= CODEBASE_READONLY        # never name a tool the bank lockdown removed
    # The rail: read-only. Not a style preference — see the constant's note above.
    assert not (inc & {"retain", "sync_retain"}), "Hermes must not write the codebase bank"
    assert not {t for t in inc if t.startswith(("delete", "update", "clear", "create", "refresh", "invalidate", "cancel"))}
    # The two Hindsight banks must stay distinct stores (RUNBOOK §2 boundary).
    assert c["url"] != h["url"]

def test_hindsight_config():
    c = json.loads((OPS / "hindsight.config.json").read_text())
    assert c == {"mode": "local_external", "api_url": "https://hindsight.<zone>", "bank_id": "hermes-agent",
                 "memory_mode": "hybrid", "auto_recall": True, "auto_retain": True, "recall_budget": "mid"}

def test_env_example_has_no_values():
    for line in (OPS / "env.example").read_text().splitlines():
        if line and not line.startswith("#"):
            k, _, v = line.partition("=")
            assert v.strip() in ("", "<set-me>", "<b64 of ops/hermes/mcp_servers.yaml>",
                                 "<b64 of ops/hermes/hindsight.config.json with <zone> substituted>",
                                 "<b64 of `bash ops/hermes/render_soul.sh`>", "hindsight"), line


def test_render_soul_is_persona_plus_guardrails(tmp_path):
    import subprocess
    root = pathlib.Path(__file__).resolve().parents[1]
    out = subprocess.run(["bash", str(root / "ops/hermes/render_soul.sh")], check=True, capture_output=True, text=True).stdout
    prefix = (root / "ops/hermes/soul_prefix.md").read_text()
    guard = (root / "ops/GUARDRAILS.md").read_text()
    assert out.startswith(prefix)
    assert out.endswith(guard)
    assert "Hard rules" in out


def test_start_sh_reapplies_soul_every_boot_and_leaves_user_md_write_once():
    root = pathlib.Path(__file__).resolve().parents[1]
    s = (root / "start.sh").read_text()
    assert 'HERMES_SOUL_MD' in s and 'SOUL.md.tmp' in s and 'mv /data/.hermes/SOUL.md.tmp /data/.hermes/SOUL.md' in s
    # USER.md stays write-once (agent-written profile, 1,375-char cap)
    assert 'if [ ! -f /data/.hermes/memories/USER.md ] && [ -n "${HERMES_USER_MD}" ]' in s


def test_start_sh_syncs_terminal_home_git_credentials_from_gh_token():
    root = pathlib.Path(__file__).resolve().parents[1]
    s = (root / "start.sh").read_text()
    assert 'TERM_HOME=/data/.hermes/home' in s
    assert "> \"${TERM_HOME}/.git-credentials\"" in s and 'umask 077' in s
    assert 'helper = store --file=/data/.hermes/home/.git-credentials' in s
    assert 'env -u GH_TOKEN HOME="${TERM_HOME}" gh auth login --with-token' in s


def test_atlas_prompt_binds_the_agent_to_the_queue_and_the_evidence_gate():
    p = (OPS / "prompts" / "atlas.md").read_text()
    # the queue assigns work; the agent may not pick its own modules
    assert "/app/bootstrap/atlas/seed_coverage.sh" in p
    assert "atlas.sh next --count 5" in p
    assert "never substitute your own picks" in p
    # recording a module requires the evidence the helper enforces
    assert "--sha <SHA> --page <slug> --evidence <path:line>" in p
    assert "do not mark it done" in p
    # the traps we have already paid for once
    assert 'source_id: "curaition"' in p and "not_built" in p
    assert "git grep -n <symbol> -- ." in p
    assert "mcp_hindsight_" in p and "NO memory plugin" in p
    # tickets are capped and deduped, dossiers are the deliverable
    assert "at most **2 for the whole run**" in p
    assert "hermes" in p and "gh pr list" in p


def test_atlas_prompt_gates_absence_claims_and_marks_doc_provenance():
    """Both rules exist because real runs broke them.

    2026-08-16 (baseline): asserted the CUR-1333 drift gate was 'a code comment'
    while a blocking CI job runs it, and sourced whole invariants sections from
    module CLAUDE.md files without saying so — in pages that are durable and read
    later as established fact.

    2026-08-17 (CUR-1408): claimed `run_consolidation` had zero callers off an
    `src/ tests/` grep, then wrote "No CLI, Celery beat, or FastAPI route
    references it" — four trees it never searched. `scripts/` holds the caller.
    The first version of this rule scoped the grep by listing trees, which is what
    let a partial list read as sufficient; it is now a bare `.` everywhere.
    """
    p = (OPS / "prompts" / "atlas.md").read_text()
    # one command, whole repo — a tree list is what failed twice. The live prompt
    # runs it worktree-scoped (git -C "$WT" grep ... -- .) since all analysis happens
    # inside the isolated worktree; the bare `.` is the load-bearing part.
    assert "grep -n <symbol-or-term> -- ." in p
    assert "a bare `.`, never a tree list" in p
    assert "Absence is the hardest claim to make" in p
    assert "it is an Open question, not an assertion" in p
    # deadness is an absence claim, and must be named as one
    assert "unused, no callers, never called, safe to delete" in p
    assert "Never state a conclusion wider than the command you ran" in p
    # an unrun grep and an empty grep are indistinguishable unless pasted
    assert "must quote the exact `git grep -n <symbol> -- .` command and its full output" in p
    # no tree-list grep may survive anywhere in the prompt
    assert "-- src tests scripts alembic" not in p
    assert "-- .github scripts alembic" not in p
    # doc-sourced claims must be labelled as such
    assert "Mark every claim's provenance" in p
    assert "doc, not verified against code" in p


def test_start_sh_creates_the_atlas_state_dir_on_the_volume():
    root = pathlib.Path(__file__).resolve().parents[1]
    s = (root / "start.sh").read_text()
    assert "mkdir -p /data/work/atlas" in s
    # the scripts must NOT be copied to the volume — they ship in the image, so a
    # redeploy can never leave stale bookkeeping logic behind
    assert "cp" not in s.split("mkdir -p /data/work/atlas")[1].split("\n")[0]


def test_atlas_scripts_ship_in_the_image():
    root = pathlib.Path(__file__).resolve().parents[1]
    assert "COPY bootstrap/ /app/bootstrap/" in (root / "Dockerfile").read_text()
    for f in ("atlas.sh", "seed_coverage.sh"):
        assert (root / "bootstrap" / "atlas" / f).exists()


def test_every_ticket_carries_hermes_plus_exactly_one_area_label():
    """A ticket with only `hermes` lands in a backlog nobody filters by.

    The label was renamed `hermes-proposed` -> `hermes` on 2026-08-16 and 11 area
    labels were added to team CUR, so the ticket-filing prompts must (a) name both
    labels, (b) forbid inventing new ones — GUARDRAILS rule 2 already bans
    relabelling, and a fresh label is taxonomy invented unilaterally.
    """
    guard = (OPS.parent / "GUARDRAILS.md").read_text()
    assert "hermes-proposed" not in guard          # single vocabulary, no stragglers
    assert "**Labels: `hermes` plus exactly ONE area label**" in guard
    assert "Never create a new label" in guard

    for name in ("atlas.md", "scout.md"):
        p = (OPS / "prompts" / name).read_text()
        assert "hermes-proposed" not in p
        assert "`hermes`" in p
        # the area vocabulary is enumerated in the prompt, not left to invention
        for area in ("video-pipeline", "data-model", "infra-ci", "entities", "web-api"):
            assert f"`{area}`" in p, f"{name} is missing area label {area}"
        assert "never invent" in p or "never create a new label" in p.lower()

    hygiene = (OPS / "prompts" / "hygiene.md").read_text()
    assert "labelled `hermes`" in hygiene and "hermes-proposed" not in hygiene


def test_start_sh_prefers_private_pat_for_credentials():
    """A stale GH_TOKEN must not be able to overwrite a working credential store.

    Found live 2026-09-04: GH_TOKEN went dead (401) while GH_TOKEN_CURAITION_PRIVATE
    stayed valid. start.sh derives .git-credentials AND gh's stored login from
    GH_TOKEN on every boot, and Hermes strips GH_TOKEN from agent subprocesses — so
    the store is the only credential those shells have. The scout's `gh pr list`
    overlap checks failed 401 while runs still reported "ok". A manual repair does
    not survive a boot, because start.sh re-derives it.
    """
    start = (pathlib.Path(__file__).resolve().parents[1] / "start.sh").read_text()
    assert "GH_TOKEN_CURAITION_PRIVATE" in start, "start.sh must consider the private PAT"

    resolve = start.index('GH_TOKEN="${GH_TOKEN_CURAITION_PRIVATE:-')
    # the private var must win, with GH_TOKEN only as fallback
    assert '${GH_TOKEN_CURAITION_PRIVATE:-${GH_TOKEN:-}}' in start, "private PAT must take precedence"

    # …and the resolution must happen BEFORE every credential WRITE, or a dead
    # GH_TOKEN still lands in the store. Match the writes themselves, not any
    # mention — the rationale comment above them names the same paths.
    writes = (
        '> "${TERM_HOME}/.git-credentials"',      # git credential store
        "gh auth login --with-token",             # gh's own stored login
        'echo "GH_TOKEN=${GH_TOKEN}" >> /data/.hermes/.env',  # env file for subshells
    )
    for w in writes:
        assert w in start, f"expected credential write not found: {w!r}"
        assert start.index(w) > resolve, f"{w!r} runs before the token is resolved"


def test_start_sh_prefers_the_github_app_and_keeps_the_pat_block_as_fallback():
    """CUR-1538: the App mint runs first; every PAT-derived write is gated on it failing.
    A regression that re-runs the PAT block after a successful App install would stamp
    the (possibly dead) PAT over the fresh installation token — the 2026-09-04 class."""
    root = pathlib.Path(__file__).resolve().parents[1]
    s = (root / "start.sh").read_text()
    app = s.index("python3 /app/bootstrap/gh_app_token.py --install")
    pat = s.index('GH_TOKEN="${GH_TOKEN_CURAITION_PRIVATE:-${GH_TOKEN:-}}"')
    assert app < pat, "the App mint must run before the PAT resolution"
    assert 'GH_TOKEN="$(python3 /app/bootstrap/gh_app_token.py --print' in s   # gateway inherits the App token
    assert s.count('[ "$GH_APP_ACTIVE" -ne 1 ]') == 3     # PAT resolution, .env write, terminal-HOME store
    assert '"$rc" -eq 3' in s and "PAT fallback" in s      # unset vars fall back loudly, other failures WARN
    assert "exec python /app/server.py" in s[pat:]         # fallback never blocks boot


def test_env_example_declares_the_app_vars_before_the_legacy_pat():
    lines = (OPS / "env.example").read_text().splitlines()
    keys = [l.partition("=")[0] for l in lines if l and not l.startswith("#")]
    assert keys.index("GH_APP_ID") < keys.index("GH_APP_PRIVATE_KEY_B64") < keys.index("GH_TOKEN")
