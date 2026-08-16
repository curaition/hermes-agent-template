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
    assert set(d) == {"gbrain", "linear", "hindsight"}   # never touch CurAItion/youcom entries
    h = d["hindsight"]
    assert h["url"] == "https://hindsight.curaition.xyz/mcp/hermes-agent/"
    assert h["headers"]["Authorization"] == "Bearer ${HINDSIGHT_API_KEY}"
    LOCKDOWN = {"retain","sync_retain","recall","reflect","list_memories","get_memory","list_mental_models","get_mental_model","list_directives","list_tags","get_bank","list_documents","get_document","list_operations","get_operation"}
    assert set(h["tools"]["include"]) <= LOCKDOWN          # never name a tool the bank lockdown removed
    assert not {t for t in h["tools"]["include"] if t.startswith(("delete","update","clear","create"))}

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
