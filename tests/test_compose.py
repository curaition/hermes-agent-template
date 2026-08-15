import re
from pathlib import Path
import yaml

F = Path(__file__).resolve().parents[1] / "ops" / "hindsight" / "docker-compose.yaml"

def test_compose_shape():
    d = yaml.safe_load(F.read_text())
    assert set(d["services"]) == {"hindsight"}          # DB is a Coolify database resource, not in-compose
    s = d["services"]["hindsight"]
    assert s["image"] == "ghcr.io/vectorize-io/hindsight:${HINDSIGHT_VERSION}"   # pinned via env, never :latest
    assert "ports" not in s                              # proxy-only; :9999 never published
    e = s["environment"]
    assert e["HINDSIGHT_API_TENANT_EXTENSION"] == "hindsight_api.extensions.builtin.tenant:ApiKeyTenantExtension"
    assert e["HINDSIGHT_API_TENANT_API_KEY"] == "${HINDSIGHT_TENANT_API_KEY}"
    assert e["HINDSIGHT_API_LLM_PROVIDER"] == "gemini"
    assert e["HINDSIGHT_API_LLM_MODEL"] == "${HINDSIGHT_LLM_MODEL:-gemini-3-flash-preview}"
    assert e["HINDSIGHT_API_EMBEDDINGS_PROVIDER"] == "openai"
    assert e["HINDSIGHT_API_EMBEDDINGS_OPENAI_MODEL"] == "text-embedding-3-small"
    assert e["HINDSIGHT_API_DATABASE_URL"] == "${HINDSIGHT_API_DATABASE_URL}"
    assert s["restart"] == "always"

def test_no_secret_literals():
    txt = F.read_text()
    assert not re.search(r"(sk-[A-Za-z0-9]{10,}|AIza[0-9A-Za-z_-]{20,}|postgres(ql)?://\w+:\w+@)", txt)
