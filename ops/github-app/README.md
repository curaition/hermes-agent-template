# `curaition-hermes` GitHub App (owner swarm Step 1, CUR-1538)

The Railway Hermes service identifies to GitHub as a GitHub App, not a PAT. PRs, labels
and comments on `curaition/curaition` show `curaition-hermes[bot]`; the owner preflight
(`scripts/ops/preflight.py --expect-app-identity`) proves it by calling
`gh api /installation/repositories`, which only an installation token can answer.
Spec: `docs/specs/2026-09-05-hermes-owner-swarm-design.md` §3 (product repo).

| File | Purpose |
|---|---|
| `manifest.json` | What gets registered: private App, webhook off, permissions `contents`/`pull_requests`/`issues`/`actions` write, `checks`/`metadata` read. |
| `create_app.py` | Runs the manifest flow locally: serves the form, catches the redirect on `127.0.0.1:8766`, exchanges the code, writes the key (mode 600) to `~/.config/curaition-hermes/`, prints the Railway commands. |
| `../../bootstrap/gh_app_token.py` | In the container: mints an installation token from `GH_APP_ID` + `GH_APP_PRIVATE_KEY_B64` and installs it into the tool-shell HOME. Runs at boot (`start.sh`) and at the start of every owner run. |

## Human steps (org owner, once)

1. `python3 ops/github-app/create_app.py` — a browser tab opens; press **Create GitHub App**, then GitHub's confirm. The script finishes by itself and prints the next commands.
2. Install the App on **only** `curaition/curaition`: `https://github.com/apps/curaition-hermes/installations/new`.
3. Set `GH_APP_ID` and `GH_APP_PRIVATE_KEY_B64` on the Railway service with the printed `railway variable set` lines (the key is piped from the file with `--stdin`). Check `hermes cron list --all` before the redeploy.
4. Verify: `railway ssh -s "Hermes Agent" -- env -u GH_TOKEN HOME=/data/.hermes/home gh api /installation/repositories --jq .total_count` → `1`.
5. Retire `GH_TOKEN` and `GH_TOKEN_CURAITION_PRIVATE` from the service. `start.sh` only falls back to them (with a WARN) when the App variables are absent.

## Permission rationale

Spec §3 said `issues: read`. The REST permission tables require **Issues: write** to add or remove labels and to comment on a PR, and **Actions: write** to re-run a workflow (the release cron's cure #4). Adding a permission later means re-approving the installation, so both are granted now. The App is never a bypass actor on the `integration` ruleset (D11).

## Rotation

Generate a new private key on the App's settings page, `base64 < new.pem | tr -d '\n' | railway variable set GH_APP_PRIVATE_KEY_B64 --stdin --service "Hermes Agent"`, then delete the old key on GitHub. The boot mint proves the new key before any run uses it.
