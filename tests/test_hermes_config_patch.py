import base64, subprocess, sys, textwrap
from pathlib import Path
import yaml

SCRIPT = Path(__file__).resolve().parents[1] / "bootstrap" / "hermes_config_patch.py"

BASE = textwrap.dedent("""
memory:
  memory_enabled: true
  provider: ''
mcp_servers:
  gbrain:
    url: http://gbrain.railway.internal:3131/mcp
    headers:
      Authorization: Bearer ${HERMES_GBRAIN_TOKEN}
    tools:
      include: [put_page, get_page]
    enabled: true
  youcom:
    url: https://api.you.com/mcp
    enabled: true
""")

MCP = textwrap.dedent("""
gbrain:
  url: http://gbrain.railway.internal:3131/mcp
  headers:
    Authorization: Bearer ${HERMES_GBRAIN_TOKEN}
  tools:
    include: [query, code_callers, put_page]
  enabled: true
linear:
  url: https://mcp.linear.app/mcp
  tools:
    include: [list_issues, save_issue]
  enabled: true
""")

def run(cfg: Path, *args):
    return subprocess.run([sys.executable, str(SCRIPT), "--config", str(cfg), *args],
                          capture_output=True, text=True)

def b64(s: str) -> str:
    return base64.b64encode(s.encode()).decode()

def test_sets_provider_and_replaces_named_servers(tmp_path):
    cfg = tmp_path / "config.yaml"; cfg.write_text(BASE)
    r = run(cfg, "--memory-provider", "hindsight", "--mcp-servers-b64", b64(MCP))
    assert r.returncode == 0, r.stderr
    d = yaml.safe_load(cfg.read_text())
    assert d["memory"]["provider"] == "hindsight"
    assert d["memory"]["memory_enabled"] is True            # untouched sibling
    assert d["mcp_servers"]["gbrain"]["tools"]["include"] == ["query", "code_callers", "put_page"]
    assert d["mcp_servers"]["linear"]["url"] == "https://mcp.linear.app/mcp"
    assert d["mcp_servers"]["youcom"] == {"url": "https://api.you.com/mcp", "enabled": True}  # untouched

def test_idempotent(tmp_path):
    cfg = tmp_path / "config.yaml"; cfg.write_text(BASE)
    run(cfg, "--memory-provider", "hindsight", "--mcp-servers-b64", b64(MCP))
    first = cfg.read_text()
    r = run(cfg, "--memory-provider", "hindsight", "--mcp-servers-b64", b64(MCP))
    assert r.returncode == 0
    assert cfg.read_text() == first
    assert "no changes" in r.stdout

def test_creates_missing_sections(tmp_path):
    cfg = tmp_path / "config.yaml"; cfg.write_text("model: foo\n")
    r = run(cfg, "--memory-provider", "hindsight", "--mcp-servers-b64", b64("linear:\n  url: https://mcp.linear.app/mcp\n"))
    assert r.returncode == 0, r.stderr
    d = yaml.safe_load(cfg.read_text())
    assert d["memory"]["provider"] == "hindsight"
    assert d["mcp_servers"]["linear"]["url"] == "https://mcp.linear.app/mcp"
    assert d["model"] == "foo"

def test_missing_config_file_is_error(tmp_path):
    r = run(tmp_path / "nope.yaml", "--memory-provider", "hindsight")
    assert r.returncode == 2

def test_invalid_b64_is_error(tmp_path):
    cfg = tmp_path / "config.yaml"; cfg.write_text(BASE)
    r = run(cfg, "--mcp-servers-b64", "%%%notbase64%%%")
    assert r.returncode == 2
    assert yaml.safe_load(cfg.read_text())["mcp_servers"]["gbrain"]["tools"]["include"] == ["put_page", "get_page"]

def test_wrapped_base64_is_accepted(tmp_path):
    # Controller ruling R5: GNU `base64` wraps output at 76 columns. Strip all
    # whitespace before decoding so a wrapped value is still accepted.
    cfg = tmp_path / "config.yaml"; cfg.write_text(BASE)
    raw = b64("linear:\n  url: https://mcp.linear.app/mcp\n")
    wrapped = "\n".join(raw[i:i + 60] for i in range(0, len(raw), 60))
    r = run(cfg, "--mcp-servers-b64", wrapped)
    assert r.returncode == 0, r.stderr
    d = yaml.safe_load(cfg.read_text())
    assert d["mcp_servers"]["linear"]["url"] == "https://mcp.linear.app/mcp"

def test_null_memory_section_is_guarded(tmp_path):
    # memory: present but null (YAML "memory:\n" with no mapping value) must
    # not raise AttributeError on mem.get(...).
    cfg = tmp_path / "config.yaml"; cfg.write_text("memory:\nmodel: foo\n")
    r = run(cfg, "--memory-provider", "hindsight")
    assert r.returncode == 0, r.stderr
    d = yaml.safe_load(cfg.read_text())
    assert d["memory"]["provider"] == "hindsight"
    assert d["model"] == "foo"
