#!/usr/bin/env python3
"""Daily Hindsight knowledge-page refresh, run as a Hermes no-agent cron job.

Pages (mental models) used to carry `refresh_after_consolidation: true`, so every
consolidation rebuilt every page in the bank: ~4,400 refresh calls a day, ~88% of the
Hindsight LLM bill (2026-10-02). All pages are now manual; this job refreshes them once a
day, and only in banks where consolidation ran inside LOOKBACK_HOURS — an idle bank has
nothing new to synthesise.

Install (inside the Hermes container):
  cp ops/hindsight/page_refresh.py /data/.hermes/scripts/hindsight-page-refresh.py
  hermes cron create "15 5 * * *" --name hindsight-page-refresh \
    --script hindsight-page-refresh.py --no-agent --deliver telegram

Stdout is delivered to Telegram, and empty stdout is silent: it prints only on failure.
`--dry-run` lists what it would refresh without submitting anything.
"""

import json
import os
import sys
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

LOOKBACK_HOURS = 26  # daily schedule plus slack for a late run
ENV_FILE = os.path.join(os.environ.get("HERMES_HOME", "/data/.hermes"), ".env")


def load_env():
    if os.environ.get("HINDSIGHT_API_KEY") and os.environ.get("HINDSIGHT_API_URL"):
        return
    try:
        with open(ENV_FILE) as f:
            for line in f:
                key, sep, value = line.strip().partition("=")
                if sep and key.startswith("HINDSIGHT_"):
                    os.environ.setdefault(key, value)
    except OSError:
        pass


def call(method, path, query=None):
    url = os.environ["HINDSIGHT_API_URL"].rstrip("/") + path
    if query:
        url += "?" + urllib.parse.urlencode(query)
    req = urllib.request.Request(
        url, method=method, headers={"Authorization": "Bearer " + os.environ["HINDSIGHT_API_KEY"]}
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.load(resp)


def items(payload, *keys):
    if isinstance(payload, list):
        return payload
    for key in keys:
        if key in payload:
            return payload[key]
    return []


def main(dry_run):
    load_env()
    if not (os.environ.get("HINDSIGHT_API_KEY") and os.environ.get("HINDSIGHT_API_URL")):
        print(f"hindsight-page-refresh: HINDSIGHT_API_KEY/URL not set (env or {ENV_FILE})")
        return 1
    since = (datetime.now(timezone.utc) - timedelta(hours=LOOKBACK_HOURS)).isoformat()
    submitted, skipped, failures = [], [], []
    for bank in items(call("GET", "/v1/default/banks"), "banks"):
        bank_id = bank.get("bank_id") or bank.get("id")
        q = urllib.parse.quote(bank_id, safe="")
        try:
            pages = items(call("GET", f"/v1/default/banks/{q}/mental-models"), "items", "mental_models")
            if not pages:
                continue
            recent = call(
                "GET",
                f"/v1/default/banks/{q}/llm-requests",
                {"operation": "consolidation", "start_date": since, "limit": 1},
            )
            if not recent.get("total"):
                skipped.append(bank_id)
                continue
            for page in pages:
                if not dry_run:
                    call("POST", f"/v1/default/banks/{q}/mental-models/{urllib.parse.quote(page['id'], safe='')}/refresh")
                submitted.append(f"{bank_id}/{page['id']}")
        except Exception as exc:  # one bad bank must not stop the others
            failures.append(f"{bank_id}: {exc}")
    if dry_run:
        print(f"would refresh {len(submitted)} pages; idle banks skipped: {skipped}")
        for page in submitted:
            print("  " + page)
    if failures:
        print(f"hindsight-page-refresh: {len(failures)} bank(s) failed, {len(submitted)} pages submitted")
        for failure in failures:
            print("  " + failure)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main("--dry-run" in sys.argv[1:]))
