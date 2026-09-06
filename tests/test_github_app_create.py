"""ops/github-app/create_app.py + manifest.json — the one-click App registration (CUR-1538).

The browser step is human-only (manifest flow), so what is testable is: the manifest
we submit, the state check on the callback, the conversion call, and that the private
key lands on disk mode 600 and never in app.json or the printed instructions.
"""
import html
import importlib.util
import json
import stat
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
DIR = ROOT / "ops" / "github-app"

_spec = importlib.util.spec_from_file_location("create_app", DIR / "create_app.py")
ca = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = ca
_spec.loader.exec_module(ca)

PEM = "-----BEGIN RSA PRIVATE KEY-----\nMIIfake\n-----END RSA PRIVATE KEY-----\n"
CONVERSION = {"id": 4242, "slug": "curaition-hermes", "client_id": "Iv1.abc", "html_url": "https://github.com/apps/curaition-hermes",
              "pem": PEM, "webhook_secret": "whs", "client_secret": "cs", "name": "curaition-hermes"}


def mode(p: Path) -> int:
    return stat.S_IMODE(p.stat().st_mode)


def test_manifest_is_a_private_webhookless_app_with_the_decided_permissions():
    m = json.loads((DIR / "manifest.json").read_text())
    assert m["name"] == "curaition-hermes"
    assert m["public"] is False
    assert m["hook_attributes"]["active"] is False
    assert m["default_events"] == []
    # spec §3 + CUR-1538: issues/actions are WRITE (labels, PR comments, workflow re-run need it)
    assert m["default_permissions"] == {"contents": "write", "pull_requests": "write", "issues": "write",
                                        "checks": "read", "actions": "write", "metadata": "read"}
    assert m["redirect_url"].startswith("http://127.0.0.1:")          # loopback only
    assert m["url"].startswith("https://github.com/curaition/")


def test_form_posts_the_manifest_to_the_org_registration_url():
    m = ca.load_manifest()
    page = ca.render_form(m, state="s3cret")
    assert 'action="https://github.com/organizations/curaition/settings/apps/new?state=s3cret"' in page
    assert 'method="post"' in page
    assert 'name="manifest"' in page
    assert html.escape(json.dumps(m), quote=True) in page


def test_manifest_org_and_redirect_port_are_derived_not_duplicated():
    m = ca.load_manifest()
    assert ca.ORG == "curaition"
    assert ca.redirect_port(m) == 8766
    assert m["redirect_url"] == f"http://127.0.0.1:{ca.redirect_port(m)}/callback"


def test_callback_rejects_state_mismatch_and_missing_code():
    with pytest.raises(ca.FlowError, match="state"):
        ca.parse_callback("/callback?code=abc&state=wrong", expected_state="right")
    with pytest.raises(ca.FlowError, match="code"):
        ca.parse_callback("/callback?state=right", expected_state="right")
    assert ca.parse_callback("/callback?code=abc&state=right", expected_state="right") == "abc"


def test_convert_posts_unauthenticated_and_writes_key_600_and_metadata_without_secrets(tmp_path):
    calls = []

    def http(method, url, headers, body=None):
        calls.append((method, url, headers, body))
        return 201, CONVERSION

    info = ca.convert("abc", out_dir=tmp_path, http=http)
    (method, url, headers, body), = calls
    assert (method, url) == ("POST", "https://api.github.com/app-manifests/abc/conversions")
    assert "Authorization" not in headers and body is None

    pem = tmp_path / "curaition-hermes.private-key.pem"
    assert pem.read_text() == PEM and mode(pem) == 0o600
    meta = json.loads((tmp_path / "curaition-hermes.app.json").read_text())
    assert meta == {"id": 4242, "slug": "curaition-hermes", "client_id": "Iv1.abc", "html_url": "https://github.com/apps/curaition-hermes"}
    assert mode(tmp_path / "curaition-hermes.app.json") == 0o600
    assert info["id"] == 4242 and info["install_url"] == "https://github.com/apps/curaition-hermes/installations/new"


def test_convert_surfaces_github_errors(tmp_path):
    with pytest.raises(ca.FlowError, match="422"):
        ca.convert("abc", out_dir=tmp_path, http=lambda *a, **k: (422, {"message": "expired"}))
    assert not list(tmp_path.iterdir())


def test_instructions_name_the_railway_vars_and_never_inline_the_key(tmp_path):
    pem = tmp_path / "k.pem"; pem.write_text(PEM)
    text = ca.railway_instructions({"id": 4242, "slug": "curaition-hermes", "install_url": "https://github.com/apps/curaition-hermes/installations/new"}, pem_path=pem)
    assert "GH_APP_ID=4242" in text
    assert "GH_APP_PRIVATE_KEY_B64 --stdin" in text and str(pem) in text
    assert "installations/new" in text
    assert "MIIfake" not in text and "BEGIN RSA" not in text
    assert 'railway variable set' in text and '--service "Hermes Agent"' in text


def test_readme_documents_the_human_steps():
    r = (DIR / "README.md").read_text()
    for needle in ["create_app.py", "installations/new", "GH_APP_ID", "GH_APP_PRIVATE_KEY_B64", "gh api /installation/repositories"]:
        assert needle in r
