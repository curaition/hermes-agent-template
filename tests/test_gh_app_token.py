"""bootstrap/gh_app_token.py — GitHub App installation-token minting for the owner swarm (CUR-1538).

Every check injects the HTTP client, the subprocess runner and the clock, so no test
touches GitHub, `gh`, or the wall clock. The RSA key is generated per test module.
"""
import base64
import importlib.util
import io
import json
import os
import stat
import sys
from pathlib import Path

import pytest
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "bootstrap" / "gh_app_token.py"

_spec = importlib.util.spec_from_file_location("gh_app_token", SCRIPT)
gat = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = gat   # dataclasses resolve annotations via sys.modules[cls.__module__]
_spec.loader.exec_module(gat)

NOW = 1_800_000_000  # fixed clock
KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)
PEM = KEY.private_bytes(
    serialization.Encoding.PEM,
    serialization.PrivateFormat.TraditionalOpenSSL,  # GitHub downloads PKCS#1 "RSA PRIVATE KEY"
    serialization.NoEncryption(),
)
PEM_B64 = base64.b64encode(PEM).decode()
TOKEN = "ghs_testtoken1234567890"
EXPIRES = "2027-01-15T12:00:00Z"


def env(**extra):
    e = {"GH_APP_ID": "1234", "GH_APP_PRIVATE_KEY_B64": PEM_B64}
    e.update(extra)
    return e


def b64url_decode(s: str) -> bytes:
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


class FakeHttp:
    """Records calls; answers from a {(method, url): (status, body)} table."""

    def __init__(self, table):
        self.table = table
        self.calls = []

    def __call__(self, method, url, headers, body=None):
        self.calls.append((method, url, headers, body))
        try:
            return self.table[(method, url)]
        except KeyError:
            return 404, {"message": f"no fake for {method} {url}"}


def happy_http(installation_id=42, app_id=1234):
    return FakeHttp({
        ("GET", "https://api.github.com/repos/curaition/curaition/installation"): (200, {"id": installation_id, "app_id": app_id}),
        (f"POST", f"https://api.github.com/app/installations/{installation_id}/access_tokens"): (201, {"token": TOKEN, "expires_at": EXPIRES}),
    })


class FakeRunner:
    def __init__(self, rc=0):
        self.rc = rc
        self.calls = []

    def __call__(self, argv, *, env, input):
        self.calls.append((argv, env, input))
        return self.rc


def mode(p: Path) -> int:
    return stat.S_IMODE(p.stat().st_mode)


# ------------------------------------------------------------------ config

def test_load_config_absent_returns_none():
    assert gat.load_config({}) is None
    assert gat.load_config({"GH_APP_ID": "", "GH_APP_PRIVATE_KEY_B64": ""}) is None


def test_load_config_partial_is_an_error():
    with pytest.raises(gat.ConfigError, match="GH_APP_PRIVATE_KEY_B64"):
        gat.load_config({"GH_APP_ID": "1234"})
    with pytest.raises(gat.ConfigError, match="GH_APP_ID"):
        gat.load_config({"GH_APP_PRIVATE_KEY_B64": PEM_B64})


def test_load_config_rejects_bad_base64_and_bad_pem():
    with pytest.raises(gat.ConfigError, match="base64"):
        gat.load_config(env(GH_APP_PRIVATE_KEY_B64="not*base64"))
    with pytest.raises(gat.ConfigError, match="PEM"):
        gat.load_config(env(GH_APP_PRIVATE_KEY_B64=base64.b64encode(b"hello").decode()))


def test_load_config_tolerates_wrapped_base64_and_reads_optional_fields():
    wrapped = "\n".join(PEM_B64[i:i + 76] for i in range(0, len(PEM_B64), 76)) + "\n"
    cfg = gat.load_config(env(GH_APP_PRIVATE_KEY_B64=wrapped, GH_APP_INSTALLATION_ID="77", GH_APP_REPO="acme/widgets"))
    assert cfg.app_id == "1234"
    assert cfg.pem == PEM
    assert cfg.installation_id == "77"
    assert cfg.repo == "acme/widgets"
    assert gat.load_config(env()).repo == "curaition/curaition"      # default
    assert gat.load_config(env()).installation_id is None


# ------------------------------------------------------------------ jwt

def test_build_jwt_claims_and_rs256_signature_verify_with_public_key():
    cfg = gat.load_config(env())
    tok = gat.build_jwt(cfg, now=NOW)
    h, p, s = tok.split(".")
    assert json.loads(b64url_decode(h)) == {"alg": "RS256", "typ": "JWT"}
    claims = json.loads(b64url_decode(p))
    assert claims == {"iat": NOW - 60, "exp": NOW + 600, "iss": "1234"}   # 60 s drift guard, 10 min max
    KEY.public_key().verify(b64url_decode(s), f"{h}.{p}".encode(), padding.PKCS1v15(), hashes.SHA256())
    assert "=" not in tok      # base64url, unpadded


# ------------------------------------------------------------------ mint

def test_mint_resolves_installation_then_posts_scoped_token():
    http = happy_http()
    tok = gat.mint(gat.load_config(env()), http=http, now=NOW)
    assert (tok.token, tok.expires_at, tok.installation_id) == (TOKEN, EXPIRES, "42")
    (m1, u1, h1, b1), (m2, u2, h2, b2) = http.calls
    assert (m1, u1) == ("GET", "https://api.github.com/repos/curaition/curaition/installation")
    assert h1["Authorization"].startswith("Bearer ") and h1["Authorization"].count(".") == 2   # a JWT, not a token
    assert h1["Accept"] == "application/vnd.github+json" and "X-GitHub-Api-Version" in h1 and "User-Agent" in h1
    assert (m2, u2) == ("POST", "https://api.github.com/app/installations/42/access_tokens")
    assert b2 == {"repositories": ["curaition"]}                       # scoped to the one repo
    assert h2["Authorization"] == h1["Authorization"]


def test_mint_skips_lookup_when_installation_id_is_configured():
    http = happy_http(installation_id=77)
    tok = gat.mint(gat.load_config(env(GH_APP_INSTALLATION_ID="77")), http=http, now=NOW)
    assert tok.installation_id == "77"
    assert [c[0] for c in http.calls] == ["POST"]


def test_mint_refuses_an_installation_of_another_app():
    http = happy_http(app_id=9999)
    with pytest.raises(gat.MintError, match="app_id 9999"):
        gat.mint(gat.load_config(env()), http=http, now=NOW)


def test_mint_surfaces_api_failures_without_leaking_the_jwt():
    http = FakeHttp({("GET", "https://api.github.com/repos/curaition/curaition/installation"): (401, {"message": "bad credentials"})})
    with pytest.raises(gat.MintError) as ei:
        gat.mint(gat.load_config(env()), http=http, now=NOW)
    assert "401" in str(ei.value) and "bad credentials" in str(ei.value)
    assert "eyJ" not in str(ei.value)


def test_mint_rejects_a_token_response_missing_fields():
    http = FakeHttp({
        ("GET", "https://api.github.com/repos/curaition/curaition/installation"): (200, {"id": 42, "app_id": 1234}),
        ("POST", "https://api.github.com/app/installations/42/access_tokens"): (201, {"token": ""}),
    })
    with pytest.raises(gat.MintError, match="token"):
        gat.mint(gat.load_config(env()), http=http, now=NOW)


# ------------------------------------------------------------------ cache

def test_cache_roundtrip_reuse_window_and_mode(tmp_path):
    cache = tmp_path / "gh_app_token.json"
    tok = gat.Token(TOKEN, "2027-01-15T12:00:00Z", "42")
    gat.write_cache(cache, tok, app_id="1234")
    assert mode(cache) == 0o600
    exp = gat.parse_expiry(EXPIRES)
    assert gat.read_cache(cache, app_id="1234", now=exp - 3600, min_remaining=900) == tok
    assert gat.read_cache(cache, app_id="1234", now=exp - 600, min_remaining=900) is None    # inside the margin
    assert gat.read_cache(cache, app_id="1234", now=exp + 1, min_remaining=0) is None         # expired
    assert gat.read_cache(cache, app_id="5678", now=exp - 3600, min_remaining=900) is None    # another App's token
    assert gat.read_cache(tmp_path / "missing.json", app_id="1234", now=0, min_remaining=0) is None


def test_cache_ignores_corrupt_file(tmp_path):
    cache = tmp_path / "gh_app_token.json"
    cache.write_text("{not json")
    assert gat.read_cache(cache, app_id="1234", now=0, min_remaining=0) is None


# ------------------------------------------------------------------ install

def test_install_writes_store_gitconfig_env_and_logs_gh_in_without_gh_token(tmp_path):
    term_home = tmp_path / "home"
    env_file = tmp_path / ".env"
    env_file.write_text("OTHER=1\nGH_TOKEN=old_pat\nLINEAR_API_KEY=lin\n")
    runner = FakeRunner()
    gat.install(gat.Token(TOKEN, EXPIRES, "42"), term_home=term_home, env_file=env_file, runner=runner,
                base_env={"GH_TOKEN": "old_pat", "PATH": "/usr/bin", "HOME": "/data"})

    cred = term_home / ".git-credentials"
    assert cred.read_text() == f"https://x-access-token:{TOKEN}@github.com\n"
    assert mode(cred) == 0o600
    gitconfig = (term_home / ".gitconfig").read_text()
    assert f"helper = store --file={term_home}/.git-credentials" in gitconfig
    assert "name = Hermes Agent" in gitconfig
    assert (term_home / ".config" / "gh").is_dir()

    lines = env_file.read_text().splitlines()
    assert lines == ["OTHER=1", f"GH_TOKEN={TOKEN}", "LINEAR_API_KEY=lin"]      # replaced in place, siblings kept
    assert mode(env_file) == 0o600

    (argv, genv, stdin), = runner.calls
    assert argv == ["gh", "auth", "login", "--with-token"]
    assert "GH_TOKEN" not in genv and genv["HOME"] == str(term_home) and genv["PATH"] == "/usr/bin"
    assert stdin == TOKEN


def test_install_appends_gh_token_when_env_file_lacks_it_and_keeps_a_custom_gitconfig(tmp_path):
    term_home = tmp_path / "home"; term_home.mkdir()
    custom = f"[user]\n\tname = Custom\n[credential]\n\thelper = store --file={term_home}/.git-credentials\n[alias]\n\tst = status\n"
    (term_home / ".gitconfig").write_text(custom)
    env_file = tmp_path / ".env"; env_file.write_text("OTHER=1\n")
    gat.install(gat.Token(TOKEN, EXPIRES, "42"), term_home=term_home, env_file=env_file, runner=FakeRunner(), base_env={})
    assert (term_home / ".gitconfig").read_text() == custom          # helper already present → untouched
    assert env_file.read_text() == f"OTHER=1\nGH_TOKEN={TOKEN}\n"


def test_install_treats_gh_login_failure_as_an_error(tmp_path):
    with pytest.raises(gat.InstallError, match="gh auth login"):
        gat.install(gat.Token(TOKEN, EXPIRES, "42"), term_home=tmp_path / "h", env_file=tmp_path / ".env",
                    runner=FakeRunner(rc=1), base_env={})


# ------------------------------------------------------------------ main

def run_main(argv, environ, http=None, runner=None, now=NOW):
    out, err = io.StringIO(), io.StringIO()
    rc = gat.main(argv, environ=environ, http=http or happy_http(), runner=runner or FakeRunner(), now=now, stdout=out, stderr=err)
    return rc, out.getvalue(), err.getvalue()


def test_main_exit_3_when_the_app_is_not_configured(tmp_path):
    rc, out, err = run_main(["--install", "--cache", str(tmp_path / "c.json")], {})
    assert rc == 3 and out == ""
    assert "GH_APP_ID" in err and "GH_APP_PRIVATE_KEY_B64" in err


def test_main_exit_2_on_a_bad_key(tmp_path):
    rc, out, err = run_main(["--print", "--cache", str(tmp_path / "c.json")], env(GH_APP_PRIVATE_KEY_B64="@@"))
    assert rc == 2 and "base64" in err and out == ""


def test_main_exit_4_on_api_failure(tmp_path):
    http = FakeHttp({("GET", "https://api.github.com/repos/curaition/curaition/installation"): (503, {"message": "down"})})
    rc, out, err = run_main(["--print", "--cache", str(tmp_path / "c.json")], env(), http=http)
    assert rc == 4 and "503" in err and out == ""


def test_main_print_emits_only_the_token_on_stdout(tmp_path):
    rc, out, err = run_main(["--print", "--cache", str(tmp_path / "c.json")], env())
    assert rc == 0 and out == TOKEN + "\n"
    assert TOKEN not in err and "installation 42" in err and EXPIRES in err


def test_main_install_then_reuse_cache_then_force(tmp_path):
    cache = tmp_path / "c.json"
    args = ["--install", "--cache", str(cache), "--term-home", str(tmp_path / "home"), "--env-file", str(tmp_path / ".env")]
    http, runner = happy_http(), FakeRunner()
    rc, out, err = run_main(args, env(), http=http, runner=runner)
    assert rc == 0 and out == ""
    assert (tmp_path / "home" / ".git-credentials").read_text().strip().endswith(f"{TOKEN}@github.com")
    assert len(http.calls) == 2 and len(runner.calls) == 1 and "minted" in err

    rc, out, err = run_main(args, env(), http=http, runner=runner, now=NOW + 60)
    assert rc == 0 and len(http.calls) == 2 and len(runner.calls) == 2 and "cached" in err   # re-installed, not re-minted

    rc, out, err = run_main(args + ["--force"], env(), http=http, runner=runner, now=NOW + 120)
    assert rc == 0 and len(http.calls) == 4 and "minted" in err


def test_main_never_writes_the_token_to_stderr(tmp_path, capsys):
    cache = tmp_path / "c.json"
    for argv, http in [
        (["--install", "--cache", str(cache), "--term-home", str(tmp_path / "h"), "--env-file", str(tmp_path / ".env")], happy_http()),
        (["--print", "--cache", str(cache)], happy_http()),
        (["--print", "--cache", str(cache), "--force"], FakeHttp({("GET", "https://api.github.com/repos/curaition/curaition/installation"): (500, {"message": TOKEN})})),
    ]:
        _, _, err = run_main(argv, env(), http=http)
        assert TOKEN not in err


def test_main_default_paths_follow_hermes_layout():
    a = gat.parse_args([])
    assert a.term_home == "/data/.hermes/home"
    assert a.env_file == "/data/.hermes/.env"
    assert a.cache == "/data/.hermes/gh_app_token.json"
    assert a.min_remaining == 900


def test_script_is_executable_and_compiles():
    assert os.access(SCRIPT, os.X_OK)
    compile(SCRIPT.read_text(), str(SCRIPT), "exec")
