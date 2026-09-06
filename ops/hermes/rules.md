<!-- agent-rules: vendored src-sha:8617a230f242 — generated from docs/ops/GUARDRAILS.md "Universal hard rules (every role)" by `python -m scripts.ops.apply_agent_rules --target hermes`. Never edit by hand: `python -m scripts.ci.check_agent_rules_parity --hermes <this file>` fails on drift. -->
## Universal hard rules (every role)

These rules bind every role, including you. They are the same rules Claude Code follows and the Hindsight directives carry; the canonical text lives in the product repo and is vendored here.

### staging IS production
<!-- rule-id: staging-is-production priority: 10 -->
`staging` IS production (CUR-1367, swarm hazard #1 in root CLAUDE.md). Precision and evidence over volume.

### Never store or echo secrets
<!-- rule-id: never-store-or-echo-secrets priority: 10 -->
Never store or echo secrets. Credentials found in repo/logs → one security issue describing WHERE (path only, never the value).

### Never delete, never touch issues you did not create
<!-- rule-id: never-delete-never-touch-issues-you-did-not-create priority: 10 -->
Never delete anything. Never close, reassign, relabel, or re-prioritize issues you did not create.

### CI and Mergify are the sole merge authority
<!-- rule-id: ci-and-mergify-are-the-sole-merge-authority priority: 10 -->
CI/Mergify is the sole merge authority (the `queue` label is the merge mechanism — swarm hazard #3; one merger per PR; mechanics in WORKFLOW.md).

### NEEDS HUMAN DRIVER issues are untouchable
<!-- rule-id: needs-human-driver-issues-are-untouchable priority: 10 -->
[NEEDS HUMAN DRIVER] issues: problem description only, no suggested approach, untouchable for implementation.

### Linear writes are attributed to one human account
<!-- rule-id: linear-writes-are-attributed-to-one-human-account priority: 10 -->
Linear writes are attributed to rick@curaition.xyz (no agent identity yet) — each role tracks its own issue IDs to respect comment-only boundaries.

### Labels: hermes plus exactly one area label
<!-- rule-id: labels-hermes-plus-exactly-one-area-label priority: 10 -->
Labels: `hermes` + exactly one area label for agent-filed issues (`hermes-proposed` does not exist — stale references). Verify labels before filing.

### PR bodies start with Closes CUR-XXXX
<!-- rule-id: pr-bodies-start-with-closes-cur-xxxx priority: 10 -->
PR bodies start `Closes CUR-XXXX` and are passed via `--body-file` (Linear autoclose).

### Isolated worktrees only
<!-- rule-id: isolated-worktrees-only priority: 10 -->
Isolated worktrees only: `/tmp/curaition-<role>-<n>`; never mutate/reset/rebase the shared clone at `/data/work/curaition` (mechanics per WORKFLOW.md).

### Check file overlap and the video lane before starting
<!-- rule-id: check-file-overlap-and-the-video-lane-before-starting priority: 10 -->
Check file overlap before starting — `gh pr list --json files` (swarm hazard #4). Video-lane check before opening PRs (swarm hazard #2, CUR-1390).

### Verify locally before every push, and never push onto a running CI run
<!-- rule-id: verify-locally-before-every-push priority: 10 -->
Before `git push` on a branch that has or will have a PR, run `make verify-full` (or the `verify-gates` skill) — it is the exact `ci-lint` + `ci-tests-unit` chain. Never push a follow-up commit to an open PR while its CI run is in progress unless that run is already red; wait for the run, then push once. Why: in Sep 1–5 2026, 12 % of all billable Actions minutes were red or cancelled runs (8 failed runs averaging 22.6 min; 47 cancelled by a follow-up push) — each one a full ~17-min run a local gate would have caught. New worktrees do not inherit the pre-push hook: run `scripts/ops/bootstrap_worktree.sh` first (mechanics in WORKFLOW.md "Worktree hygiene").

### One PR per subsystem per session; merges are the expensive unit
<!-- rule-id: one-pr-per-subsystem-per-session priority: 10 -->
Every merge to `staging` costs ~48 billable CI minutes (1.33 full runs — a 32 % chance of a second run from the queue-head update), seven Render builds, and a restart of every worker that discards in-flight transcript work (CUR-1390). So: same-subsystem work from one session ships as ONE PR; ≤ 2 PRs in flight per session; the whole repo stays under a budget of ~6 merges/day (WORKFLOW.md "The AI Engineering Loop"). Scout/hygiene roles never open a PR for a single-file docs fix — they batch it into the next code PR touching that area, or into the weekly hygiene pass. Never batch UNRELATED concerns to get there (golden rule 1 still holds).

### Prose memory is not a code index or an issue tracker
<!-- rule-id: prose-not-graph priority: 10 -->
This bank holds LLM-extracted PROSE about the CurAItion codebase: decisions and their rationale, conventions, architecture choices, in-flight initiatives, and narrative structural summaries (a component map, a tech-stack overview). It is NOT a code index and NOT an issue tracker.

NEVER PRESENT ANY IDENTIFIER FROM THIS BANK AS A CITATION. That includes Linear ticket IDs (CUR-nnnn), file paths, line numbers, symbol and function names, commit SHAs, and env-var names. Identifiers are the least reliable thing here: they are reconstructed by a language model from conversation and commit text, and a wrong one is highly plausible — correctly formatted, in the right numeric range, attached to a real convention. Measured 2026-09-04: of four distinct CUR identifiers asserted across these knowledge pages, one was fabricated (CUR-990 attached to the PgBouncer session invariant, which in truth carries no ticket at all) and one was mischaracterised (CUR-1373 described as multi-tenancy isolation; it is AI cost attribution). That is a 50% error rate, and the fabricated one reached a real Linear issue before anyone checked.

So: state the convention and the reasoning, which is what this bank is good for. When an identifier matters, say where to confirm it rather than asserting it — Linear for CUR-nnnn, `git grep` or the GBrain code graph (code_def / code_refs / code_callers / code_callees) for anything in the code, `git log` for a SHA. If you do surface an identifier, mark it explicitly as unverified.

Never conclude from this bank that a symbol exists, who calls what, or that a ticket covers a given topic. Answer the WHY from here; attribute every WHERE and every WHICH-TICKET to a source that can be checked.

### State the vintage of recalled facts
<!-- rule-id: state-the-vintage priority: 9 -->
Every fact here was written by the agent that was actually making the changes — Claude Code sessions in the repository, plus commit messages — and consolidated later. So facts can lag the working tree. When a recalled decision or convention would materially change what someone does, say when it was recorded and that it should be confirmed against the current code before being relied on. If evidence shows a stored fact is now wrong, do not silently assert the correction: state what the bank claims, what appears true now, and the evidence for the difference, so the correction can be ingested as a superseding document rather than lost in a single answer.
