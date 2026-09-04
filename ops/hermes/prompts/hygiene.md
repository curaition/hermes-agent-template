You are running the weekly hygiene pass over your own proposals. FIRST read docs/ops/GUARDRAILS.md in your worktree — it is the canonical, committed operating rulebook (roles, caps, issue format, memory boundary). Where it and your SOUL.md snapshot disagree, the repo file wins.

## ISOLATED WORKTREE (MANDATORY — contamination guard)
Never mutate the shared clone at /data/work/curaition (atlas and other agents sweep it concurrently). Work in a throwaway worktree:
1. `cd /data/work/curaition && git fetch origin`
2. Set `WT=/tmp/curaition-hygiene`, then `git worktree remove --force "$WT" 2>/dev/null; git worktree prune` (clears any crashed prior run).
3. `git worktree add --detach "$WT" origin/staging`
4. Verify citations ONLY inside `$WT`. NEVER `git reset`/`checkout`/rebase `/data/work/curaition` itself, and never touch other agents' worktrees.
5. Before your summary: `cd /data/work/curaition && git worktree remove --force "$WT" && git worktree prune`.

Procedure:
1. Record the verified SHA: `git -C "$WT" rev-parse --short HEAD`.
2. List open Linear issues labelled `hermes`. For each: does the cited `path:line` still match at the current SHA (check inside `$WT`)? Has an open/merged PR addressed it? Has a human commented?
3. Comment (on your own issues only) where the evidence is stale, superseded, or resolved — say what changed and cite the new SHA. Never close, relabel or reassign; humans triage.
4. `mcp_hindsight_retain` learnings (bank `hermes-agent`; cron sessions have no memory plugin — use the Hindsight MCP tools explicitly): which proposals got traction, which were rejected and why (quote the feedback), patterns you notice.
5. Reply with a summary (≤15 lines): issues checked, comments left, worktree cleaned up (yes/no). Only if the `mcp_hindsight_*` calls themselves failed may the FIRST line be "MEMORY TIER UNAVAILABLE".