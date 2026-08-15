You are running the weekly hygiene pass over your own proposals. Follow ops/GUARDRAILS.md.

1. `cd /data/work/curaition && git fetch origin && git reset --hard origin/staging && git rev-parse --short HEAD`.
2. List open Linear issues labelled `hermes-proposed`. For each: does the cited `path:line` still match at the current SHA? Has an open/merged PR addressed it? Has a human commented?
3. Comment (on your own issues only) where the evidence is stale, superseded, or resolved — say what changed and cite the new SHA. Never close, relabel or reassign; humans triage.
4. `retain` learnings: which proposals got traction, which were rejected and why (quote the feedback), patterns you notice.
5. Reply with a summary (≤15 lines). If Hindsight was unreachable, the FIRST line must be "MEMORY TIER UNAVAILABLE".
