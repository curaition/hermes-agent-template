import json
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
    assert set(d) == {"gbrain", "linear"}       # never touch CurAItion/youcom entries

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
                                 "<b64 of ops/GUARDRAILS.md>", "hindsight"), line
