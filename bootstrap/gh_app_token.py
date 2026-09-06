#!/usr/bin/env python3
"""Mint a GitHub App installation token for the `curaition-hermes` App and install it
into the tool shell's HOME (owner swarm Step 1, CUR-1538).

    gh_app_token.py --install            # boot, and the first step of every owner run
    gh_app_token.py --print              # token on stdout (for `GH_TOKEN="$(...)"`)

Why this exists: Hermes strips GH_TOKEN from every terminal/execute_code subprocess and
runs that shell with HOME=/data/.hermes/home, so git/gh inside the agent authenticate
ONLY via that HOME's stored credentials. A PAT stamped there at boot went stale twice
(silent 403s with an "ok" run, 2026-08-16 and 2026-09-04), and the owner preflight
(`scripts/ops/preflight.py --expect-app-identity`) refuses a PAT outright: it needs
`gh api /installation/repositories` to succeed, which only an installation token can.

Installation tokens live one hour, so this runs at boot AND at the start of every owner
run; a cache (mode 600) avoids re-minting when the current token still has more than
--min-remaining seconds left. Owner runs longer than the margin re-run `--install`
before the push.

Env (Railway service variables):
  GH_APP_ID               App id (client id also accepted as `iss`)
  GH_APP_PRIVATE_KEY_B64  base64 of the downloaded PEM (wrapped output accepted)
  GH_APP_INSTALLATION_ID  optional; otherwise resolved via GET /repos/{repo}/installation
  GH_APP_REPO             optional, default curaition/curaition

Exit codes: 0 ok · 2 bad config (undecodable key, partial vars) · 3 App not configured
(both vars unset — start.sh falls back to the PAT path, loudly) · 4 GitHub API failure ·
5 install failure. The token never reaches stderr or the log; --print puts it on stdout
and nothing else.
"""
from __future__ import annotations

import argparse
import base64
import binascii
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

API = "https://api.github.com"
API_VERSION = "2022-11-28"
USER_AGENT = "curaition-hermes-bootstrap"
DEFAULT_REPO = "curaition/curaition"
# Anything token-shaped (ghs_/ghp_/gho_/ghu_/ghr_) is scrubbed from every log line, so
# even an API error that echoes a credential cannot land in the Railway log.
_TOKEN_SHAPE = re.compile(r"\bgh[pousr]_[A-Za-z0-9_]{16,}")
GITCONFIG_TEMPLATE = "[user]\n\tname = Hermes Agent\n\temail = info@curaition.xyz\n[credential]\n\thelper = store --file={cred}\n"


class ConfigError(Exception):
    """GH_APP_* present but unusable (exit 2)."""


class MintError(Exception):
    """GitHub refused or the response is malformed (exit 4)."""


class InstallError(Exception):
    """Writing the tool-shell credentials or `gh auth login` failed (exit 5)."""


@dataclass(frozen=True)
class AppConfig:
    app_id: str
    pem: bytes
    installation_id: str | None
    repo: str


@dataclass(frozen=True)
class Token:
    token: str
    expires_at: str
    installation_id: str


# ----------------------------------------------------------------------------- config

def load_config(environ) -> AppConfig | None:
    app_id = (environ.get("GH_APP_ID") or "").strip()
    key_b64 = (environ.get("GH_APP_PRIVATE_KEY_B64") or "").strip()
    if not app_id and not key_b64:
        return None
    if not app_id:
        raise ConfigError("GH_APP_PRIVATE_KEY_B64 is set but GH_APP_ID is not")
    if not key_b64:
        raise ConfigError("GH_APP_ID is set but GH_APP_PRIVATE_KEY_B64 is not")
    try:
        pem = base64.b64decode("".join(key_b64.split()), validate=True)
    except (binascii.Error, ValueError) as e:
        raise ConfigError(f"GH_APP_PRIVATE_KEY_B64 is not valid base64: {e}") from e
    if b"-----BEGIN" not in pem or b"PRIVATE KEY-----" not in pem:
        raise ConfigError("GH_APP_PRIVATE_KEY_B64 does not decode to a PEM private key")
    inst = (environ.get("GH_APP_INSTALLATION_ID") or "").strip() or None
    repo = (environ.get("GH_APP_REPO") or "").strip() or DEFAULT_REPO
    if repo.count("/") != 1:
        raise ConfigError(f"GH_APP_REPO must be owner/name, got {repo!r}")
    return AppConfig(app_id=app_id, pem=pem, installation_id=inst, repo=repo)


# ----------------------------------------------------------------------------- jwt

def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def build_jwt(cfg: AppConfig, *, now: int) -> str:
    """RS256 JWT per GitHub's spec: iat 60 s in the past (clock drift), exp +10 min (the max)."""
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import padding

    try:
        key = serialization.load_pem_private_key(cfg.pem, password=None)
    except (ValueError, TypeError) as e:
        raise ConfigError(f"GH_APP_PRIVATE_KEY_B64 is not a loadable PEM private key: {e}") from e
    header = _b64url(json.dumps({"alg": "RS256", "typ": "JWT"}, separators=(",", ":")).encode())
    payload = _b64url(json.dumps({"iat": now - 60, "exp": now + 600, "iss": cfg.app_id}, separators=(",", ":")).encode())
    signing_input = f"{header}.{payload}".encode()
    sig = key.sign(signing_input, padding.PKCS1v15(), hashes.SHA256())
    return f"{header}.{payload}.{_b64url(sig)}"


# ----------------------------------------------------------------------------- http

def default_http(method: str, url: str, headers: dict, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers=dict(headers))
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read()
            return resp.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            parsed = json.loads(raw) if raw else {}
        except ValueError:
            parsed = {"message": raw.decode(errors="replace")[:200]}
        return e.code, parsed
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        raise MintError(f"{method} {url}: {e}") from e


def _headers(jwt: str) -> dict:
    return {"Authorization": f"Bearer {jwt}", "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": API_VERSION, "User-Agent": USER_AGENT}


def _fail(status: int, url: str, body) -> MintError:
    msg = body.get("message") if isinstance(body, dict) else None
    return MintError(f"{url} -> HTTP {status}: {msg or 'no message'}")


# ----------------------------------------------------------------------------- mint

def mint(cfg: AppConfig, *, http, now: int) -> Token:
    jwt = build_jwt(cfg, now=now)
    headers = _headers(jwt)
    inst = cfg.installation_id
    if inst is None:
        url = f"{API}/repos/{cfg.repo}/installation"
        status, body = http("GET", url, headers)
        if status != 200:
            raise _fail(status, url, body)
        inst_app = str(body.get("app_id", ""))
        if inst_app != cfg.app_id:
            raise MintError(f"installation on {cfg.repo} belongs to app_id {inst_app}, not {cfg.app_id}")
        inst = str(body.get("id", "")).strip()
        if not inst:
            raise MintError(f"{url}: response has no installation id")
    url = f"{API}/app/installations/{inst}/access_tokens"
    status, body = http("POST", url, headers, {"repositories": [cfg.repo.split("/", 1)[1]]})
    if status != 201:
        raise _fail(status, url, body)
    token = body.get("token") if isinstance(body, dict) else None
    expires = body.get("expires_at") if isinstance(body, dict) else None
    if not token or not expires:
        raise MintError(f"{url}: response lacks token/expires_at")
    return Token(token=token, expires_at=expires, installation_id=inst)


# ----------------------------------------------------------------------------- cache

def parse_expiry(s: str) -> int:
    return int(datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp())


def _write_private(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=f".{path.name}.")
    try:
        with os.fdopen(fd, "w") as fh:
            fh.write(text)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def write_cache(path: Path, tok: Token, *, app_id: str) -> None:
    _write_private(Path(path), json.dumps({"app_id": app_id, "installation_id": tok.installation_id,
                                           "token": tok.token, "expires_at": tok.expires_at}) + "\n")


def read_cache(path: Path, *, app_id: str, now: int, min_remaining: int) -> Token | None:
    try:
        d = json.loads(Path(path).read_text())
        if d.get("app_id") != app_id or not d.get("token") or not d.get("expires_at"):
            return None
        if parse_expiry(d["expires_at"]) - now <= min_remaining:
            return None
        return Token(token=d["token"], expires_at=d["expires_at"], installation_id=str(d.get("installation_id", "")))
    except (OSError, ValueError, TypeError, AttributeError):
        return None


# ----------------------------------------------------------------------------- install

def default_runner(argv, *, env, input) -> int:
    return subprocess.run(argv, env=env, input=input, text=True, capture_output=True).returncode


def _upsert_env_line(env_file: Path, key: str, value: str) -> None:
    lines = env_file.read_text().splitlines() if env_file.exists() else []
    line, done = f"{key}={value}", False
    out = []
    for ln in lines:
        if ln.startswith(f"{key}="):
            if not done:
                out.append(line)
                done = True
            continue  # drop duplicates
        out.append(ln)
    if not done:
        out.append(line)
    _write_private(env_file, "\n".join(out) + "\n")


def install(tok: Token, *, term_home: Path, env_file: Path, runner, base_env) -> None:
    """Mirror of the start.sh PAT block, driven by the App token:
    .git-credentials (600), .gitconfig with the store helper (only if absent — a custom
    config is kept), GH_TOKEN in the hermes .env for hermes's own GitHub tool, and
    `gh auth login --with-token` under the terminal HOME with GH_TOKEN removed from the
    environment (gh refuses to store a login while GH_TOKEN is set)."""
    term_home, env_file = Path(term_home), Path(env_file)
    (term_home / ".config" / "gh").mkdir(parents=True, exist_ok=True)
    cred = term_home / ".git-credentials"
    _write_private(cred, f"https://x-access-token:{tok.token}@github.com\n")
    gitconfig = term_home / ".gitconfig"
    helper = f"helper = store --file={cred}"
    if not (gitconfig.exists() and helper in gitconfig.read_text()):
        gitconfig.write_text(GITCONFIG_TEMPLATE.format(cred=cred))
    _upsert_env_line(env_file, "GH_TOKEN", tok.token)
    env = {k: v for k, v in dict(base_env).items() if k != "GH_TOKEN"}
    env["HOME"] = str(term_home)
    rc = runner(["gh", "auth", "login", "--with-token"], env=env, input=tok.token)
    if rc != 0:
        raise InstallError(f"gh auth login --with-token failed (rc={rc}) under HOME={term_home}")


# ----------------------------------------------------------------------------- main

def parse_args(argv):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--install", action="store_true", help="write the tool-shell credentials and log gh in")
    mode.add_argument("--print", action="store_true", help="print the token to stdout (nothing else)")
    ap.add_argument("--force", action="store_true", help="ignore the cache and mint a fresh token")
    ap.add_argument("--cache", default="/data/.hermes/gh_app_token.json")
    ap.add_argument("--term-home", default="/data/.hermes/home")
    ap.add_argument("--env-file", default="/data/.hermes/.env")
    ap.add_argument("--min-remaining", type=int, default=900, help="re-mint when fewer seconds than this remain")
    return ap.parse_args(argv)


def main(argv=None, *, environ=None, http=None, runner=None, now=None, stdout=None, stderr=None) -> int:
    a = parse_args(sys.argv[1:] if argv is None else argv)
    environ = os.environ if environ is None else environ
    http = http or default_http
    runner = runner or default_runner
    now = int(time.time()) if now is None else now
    out = stdout or sys.stdout
    err = stderr or sys.stderr

    def log(msg):
        print(f"gh_app_token: {_TOKEN_SHAPE.sub('[redacted]', str(msg))}", file=err)

    try:
        cfg = load_config(environ)
    except ConfigError as e:
        log(f"config error: {e}")
        return 2
    if cfg is None:
        log("GH_APP_ID / GH_APP_PRIVATE_KEY_B64 not set — no GitHub App identity available")
        return 3

    cache = Path(a.cache)
    tok = None if a.force else read_cache(cache, app_id=cfg.app_id, now=now, min_remaining=a.min_remaining)
    if tok is not None:
        log(f"using cached token for installation {tok.installation_id} (expires {tok.expires_at})")
    else:
        try:
            tok = mint(cfg, http=http, now=now)
        except ConfigError as e:
            log(f"config error: {e}")
            return 2
        except MintError as e:
            log(f"mint failed: {e}")
            return 4
        try:
            write_cache(cache, tok, app_id=cfg.app_id)
        except OSError as e:
            log(f"warning: could not write cache {cache}: {e}")
        log(f"minted token for installation {tok.installation_id} on {cfg.repo} (expires {tok.expires_at})")

    if a.install:
        try:
            install(tok, term_home=Path(a.term_home), env_file=Path(a.env_file), runner=runner, base_env=environ)
        except (InstallError, OSError) as e:
            log(f"install failed: {e}")
            return 5
        log(f"installed into {a.term_home} (git store + gh login) and {a.env_file}")
    if a.print:
        print(tok.token, file=out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
