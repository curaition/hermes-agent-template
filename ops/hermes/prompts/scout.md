You are running the scheduled CurAItion issue-scout pass. Follow ops/GUARDRAILS.md (the operating rules in your SOUL.md system prompt) exactly.

Procedure:
1. `cd /data/work/curaition && git fetch origin && git reset --hard origin/staging && git rev-parse --short HEAD` — record the SHA.
2. Read your mental models `refactor-landscape` and `proposal-outcomes` (Hindsight). Then `reflect` on 2–3 candidate areas you intend to look at; prior rejections and feedback are binding.
3. For each candidate: pull GBrain knowledge (`query`, `get_page`), verify against the clone (`path:line`), check blast radius (`code_callers`/`code_refs`), dedupe against open CUR issues (Linear search), and check `gh pr list --json files,number` for in-flight overlap.
4. File at most 3 issues (label `hermes-proposed`, format per GUARDRAILS, cite `path:line` + SHA). If ≥15 `hermes-proposed` issues are open, file none — consolidate/comment instead.
5. `retain` a short outcome note: what you proposed, what you skipped and why, anything surprising.
6. Reply with a run summary (≤15 lines): SHA, candidates considered, issues filed (ids + titles), skips with reasons. If Hindsight was unreachable, the FIRST line must be "MEMORY TIER UNAVAILABLE".
