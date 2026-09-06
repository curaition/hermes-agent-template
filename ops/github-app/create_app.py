#!/usr/bin/env python3
"""Register the `curaition-hermes` GitHub App from `manifest.json` in one click (CUR-1538).

    python3 ops/github-app/create_app.py            # opens the browser, waits for the callback
    python3 ops/github-app/create_app.py --code X   # you already have the code from the redirect

GitHub Apps can only be created through the browser (the manifest flow), so this script
does everything around that click: it serves a local page whose form POSTs the manifest
to the org's registration URL, receives GitHub's redirect on 127.0.0.1 with a temporary
code, exchanges the code (no auth needed, one-hour validity) for the App's id and private
key, and writes both to --out-dir mode 600. The key never leaves your machine except via
the `railway variable set --stdin` line printed at the end.

Requires an org-owner GitHub session in the browser that opens.
"""
from __future__ import annotations

import argparse
import html
import json
import os
import secrets
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import webbrowser
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
ORG = "curaition"
API = "https://api.github.com"
DEFAULT_OUT = Path.home() / ".config" / "curaition-hermes"
RAILWAY_SERVICE = "Hermes Agent"


class FlowError(Exception):
    pass


def load_manifest(path: Path = HERE / "manifest.json") -> dict:
    return json.loads(path.read_text())


def redirect_port(manifest: dict) -> int:
    u = urllib.parse.urlparse(manifest["redirect_url"])
    if u.hostname != "127.0.0.1" or not u.port:
        raise FlowError(f"redirect_url must be http://127.0.0.1:<port>/..., got {manifest['redirect_url']}")
    return u.port


def render_form(manifest: dict, *, state: str) -> str:
    action = f"https://github.com/organizations/{ORG}/settings/apps/new?state={urllib.parse.quote(state)}"
    payload = html.escape(json.dumps(manifest), quote=True)
    perms = "".join(f"<li><code>{html.escape(k)}</code>: {html.escape(v)}</li>" for k, v in manifest["default_permissions"].items())
    return f"""<!doctype html><meta charset="utf-8"><title>Create {html.escape(manifest['name'])}</title>
<body style="font:15px/1.5 system-ui;max-width:42em;margin:3em auto">
<h1>Create the <code>{html.escape(manifest['name'])}</code> GitHub App</h1>
<p>Submits <code>ops/github-app/manifest.json</code> to the <b>{ORG}</b> organization. Private App, webhook off, permissions:</p>
<ul>{perms}</ul>
<p>GitHub will show a confirmation page; press <b>Create GitHub App for {ORG}</b> there. You are then redirected back here and this script finishes on its own.</p>
<form action="{action}" method="post"><input type="hidden" name="manifest" value="{payload}">
<button type="submit" style="font-size:1.1em;padding:.5em 1.2em">Create GitHub App</button></form>
</body>"""


def parse_callback(path: str, *, expected_state: str) -> str:
    q = urllib.parse.parse_qs(urllib.parse.urlparse(path).query)
    if q.get("state", [None])[0] != expected_state:
        raise FlowError("callback state mismatch — not the flow this script started; refusing the code")
    code = q.get("code", [None])[0]
    if not code:
        raise FlowError("callback carried no code")
    return code


def default_http(method: str, url: str, headers: dict, body=None):
    req = urllib.request.Request(url, method=method, headers=dict(headers))
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read()
            return resp.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw) if raw else {}
        except ValueError:
            return e.code, {"message": raw.decode(errors="replace")[:200]}


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


def convert(code: str, *, out_dir: Path, http=default_http) -> dict:
    """POST /app-manifests/{code}/conversions (unauthenticated) → write pem + metadata."""
    url = f"{API}/app-manifests/{urllib.parse.quote(code)}/conversions"
    status, body = http("POST", url, {"Accept": "application/vnd.github+json", "User-Agent": "curaition-hermes-create-app"})
    if status != 201 or not isinstance(body, dict) or not body.get("pem") or not body.get("id"):
        msg = body.get("message") if isinstance(body, dict) else body
        raise FlowError(f"conversion failed: HTTP {status}: {msg}")
    slug = body.get("slug") or body.get("name") or "github-app"
    out_dir = Path(out_dir)
    pem_path = out_dir / f"{slug}.private-key.pem"
    meta = {k: body.get(k) for k in ("id", "slug", "client_id", "html_url")}
    _write_private(pem_path, body["pem"])
    _write_private(out_dir / f"{slug}.app.json", json.dumps(meta, indent=2) + "\n")
    return {**meta, "pem_path": str(pem_path), "install_url": f"{body.get('html_url')}/installations/new"}


def railway_instructions(info: dict, *, pem_path: Path) -> str:
    return f"""
App created: id {info['id']} (slug {info['slug']}). Private key: {pem_path} (mode 600).

1. Install it on the one repo (org owner, browser):
     {info['install_url']}
   → "Only select repositories" → curaition/curaition.

2. Set the Railway service variables (the second reads the key from the file, never from your shell history):
     railway variable set GH_APP_ID={info['id']} --service "{RAILWAY_SERVICE}" --skip-deploys
     base64 < {pem_path} | tr -d '\\n' | railway variable set GH_APP_PRIVATE_KEY_B64 --stdin --service "{RAILWAY_SERVICE}"
   (drop --skip-deploys on the last one so the service redeploys with both; check `hermes cron list --all` first —
    a redeploy kills an in-flight cron run.)

3. Verify from the laptop once the deploy is live:
     railway ssh -s "{RAILWAY_SERVICE}" -- env -u GH_TOKEN HOME=/data/.hermes/home gh api /installation/repositories --jq .total_count
   Expect 1. Then retire GH_TOKEN / GH_TOKEN_CURAITION_PRIVATE from the service (start.sh only uses them as a fallback).
"""


class _Handler(BaseHTTPRequestHandler):
    server: "_Server"

    def log_message(self, *a):  # quiet
        pass

    def do_GET(self):
        s = self.server
        if self.path == "/":
            return self._html(200, render_form(s.manifest, state=s.state))
        if self.path.startswith("/callback"):
            try:
                s.code = parse_callback(self.path, expected_state=s.state)
            except FlowError as e:
                s.error = str(e)
                return self._html(400, f"<p>{html.escape(str(e))}</p>")
            return self._html(200, "<p>Code received — back to the terminal; you can close this tab.</p>")
        self._html(404, "<p>not found</p>")

    def _html(self, status: int, body: str):
        data = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


class _Server(HTTPServer):
    def __init__(self, port: int, manifest: dict, state: str):
        super().__init__(("127.0.0.1", port), _Handler)
        self.manifest, self.state, self.code, self.error = manifest, state, None, None


def run_flow(manifest: dict, *, open_browser=True) -> str:
    port = redirect_port(manifest)
    state = secrets.token_urlsafe(24)
    srv = _Server(port, manifest, state)
    url = f"http://127.0.0.1:{port}/"
    print(f"Open {url} (org-owner GitHub session) and press the button.", file=sys.stderr)
    if open_browser:
        webbrowser.open(url)
    while srv.code is None and srv.error is None:
        srv.handle_request()
    srv.server_close()
    if srv.error:
        raise FlowError(srv.error)
    return srv.code


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--code", help="skip the browser flow; exchange this code from the redirect URL")
    ap.add_argument("--out-dir", default=str(DEFAULT_OUT))
    ap.add_argument("--no-browser", action="store_true")
    a = ap.parse_args(argv)
    manifest = load_manifest()
    try:
        code = a.code or run_flow(manifest, open_browser=not a.no_browser)
        info = convert(code, out_dir=Path(a.out_dir))
    except FlowError as e:
        print(f"create_app: {e}", file=sys.stderr)
        return 1
    print(railway_instructions(info, pem_path=Path(info["pem_path"])))
    return 0


if __name__ == "__main__":
    sys.exit(main())
