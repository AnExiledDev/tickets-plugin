# tickets

Claude Code plugin enforcing well-shaped, self-contained GitHub issues on this box.

- **Skill** `/tickets:file-issue` — the workflow for filing an issue: triage gate, targeted context gathering, verbatim human intent, label conventions. Anatomy lives in [skills/file-issue/template.md](skills/file-issue/template.md), labels in [skills/file-issue/labels.md](skills/file-issue/labels.md), a worked example in [skills/file-issue/examples.md](skills/file-issue/examples.md).
- **Skill** `/tickets:work-issue` — the workflow for working one: claim protocol (session-id claim comments, dead-claim takeover), contract reading (human intent binding, out-of-scope as a wall), verification, ship per PR policy, close-out checks.
- **Hook** (PreToolUse on Bash) — [scripts/validate-issue.sh](scripts/validate-issue.sh) blocks `gh issue create` / `gh api` issue-creation calls whose body lacks the required sections or a label. Exit 2 feeds the missing list back to the agent. It is a lazy-path gate, not adversarial-proof: it checks the command string plus any literal `--body-file` it can read.
- **Hook** (UserPromptSubmit) — [scripts/inject-work-issue.sh](scripts/inject-work-issue.sh) injects a `/tickets:work-issue` pointer when the prompt reads like "work issue #N" (working verbs only; filing verbs stay with file-issue). Injection only, never blocks.
- **Hook** (PreToolUse on Bash) — [scripts/check-claim-adherence.sh](scripts/check-claim-adherence.sh) adherence tripwire ONLY: on `gh pr create` closing an issue, or `git commit`/`push` on an `issue-N` branch, it checks the issue's COMMENTS for this session's id and blocks with a report-your-failure message when absent. Comments only — the body's provenance mark carries the filing session's id and never counts as a claim. Fails open on anything it can't determine; the shape gate stays validate-issue.sh. Now the BACKSTOP behind the claim ledger, not the gate.

## The claim ledger

Every check above infers the issue number from text — the prompt's wording, the branch name, the command line — and inference is what kept failing. An eleven-issue epic was worked with one claim posted and nothing said a word, because "work the epic to completion" names no issue, an integration branch is not `issue-N`, and `--body-file` keeps the closing keywords out of the command line entirely.

The ledger records the number at the one moment it is unambiguous, and everything downstream reads that recorded fact.

- **Hook** (PostToolUse on Bash) — [scripts/record-issue-view.sh](scripts/record-issue-view.sh): `gh issue view N` records N as *undecided* (the number is read from any argument position, so `--repo o/r` before it does not hide it) and injects the claim-or-skip reminder. Another session's claim on that issue is injected **always** — a collision is a fact, it is rare, and it is worthless late. The reminder is capped: once per issue per session, and at most 3 per 10 minutes so a triage sweep across thirty issues does not emit thirty. Both caps are needed; dedup does nothing for a sweep and the burst cap does nothing for a re-read. Suppressing a reminder loses nothing, because the ledger entry is written on every view regardless.
- **Hook** (PostToolUse on Bash) — [scripts/record-claim.sh](scripts/record-claim.sh): `gh issue comment N` (again from any argument position) whose body (inline or `--body-file`) carries this session's id marks it *claimed*. The claim comment IS the ledger write, so the happy path needs no extra command.
- **Hook** (PreToolUse on Edit/Write/NotebookEdit/Task and on `git commit`, including `git -C <dir> commit`) — [scripts/require-claim.sh](scripts/require-claim.sh): the first mutation pays the debt. `Task` is the one that matters — an orchestrator's own tree stays clean while subagents do every edit. An issue blocks at most once per 10 minutes, deliberately: a session that will not decide gets one loud interrupt and then proceeds, and the PR tripwire catches it later. Never deadlocking beats never escaping.
- **Hook** (PostToolUse on Bash) — [scripts/record-branch-work.sh](scripts/record-branch-work.sh): `git worktree add`/`switch -c`/`checkout -b` naming `issue-<N>` records N as *undecided*, and require-claim.sh reads the current branch for the same reason. A checkout names exactly one issue, so unlike prompt text this signal cannot mass-seed, and it closes the case where a session is handed a ready worktree and never runs `gh issue view` at all.
- **CLI** — [scripts/ticket-ledger.sh](scripts/ticket-ledger.sh) `skip <N>` / `claim <N>` / `status`. `skip` is the read-only escape: one decision, per issue, once.

State lives at `~/.claude/state/tickets/<session-id>.json` and every helper fails open — no jq, an unwritable dir, a truncated file all degrade to "no state" rather than blocking work.

**Subagent calls are ignored.** They fire these hooks with the *parent's* `session_id` and are told apart only by `agent_id` being populated. The orchestrator reads, decides and claims, and its `Task` spawn is already gated, so a subagent writing entries the parent must clear — or an implementer blocked mid-edit on a decision it is not allowed to make — is cross-talk bought for nothing.

**What it still cannot see:** a session that never runs `gh issue view` at all, working straight from an epic body or a spawn prompt. That is what check-claim-adherence.sh is left for.

```bash
tests/hooks.test.sh    # 29 cases, no network, scratch state
```

Installed as a skills-directory plugin at `~/.claude/skills/tickets/` — loads automatically each session (hook active after restart or `/reload-plugins`).

Validate the drafted body before filing:

```bash
~/.claude/skills/tickets/scripts/validate-issue.sh --file body.md
```

Escape hatch (operator use only, e.g. filing upstream on a third-party repo): set `CLAUDE_TICKET_SHAPE=off` in the environment or prefix it on the command. Agents must not use it on their own; it is greppable.

Companion policy: `~/.claude/rules/no-untracked-deferral.md` (when to file at all), `~/.claude/rules/human-intent.md` (provenance marks).
