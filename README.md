# tickets

Claude Code plugin enforcing well-shaped, self-contained GitHub issues on this box.

- **Skill** `/tickets:file-issue` — the workflow for filing an issue: triage gate, targeted context gathering, verbatim human intent, label conventions. Anatomy lives in [skills/file-issue/template.md](skills/file-issue/template.md), labels in [skills/file-issue/labels.md](skills/file-issue/labels.md), a worked example in [skills/file-issue/examples.md](skills/file-issue/examples.md).
- **Skill** `/tickets:work-issue` — the workflow for working one: claim protocol (session-id claim comments, dead-claim takeover), contract reading (human intent binding, out-of-scope as a wall), verification, ship per PR policy, close-out checks.
- **Hook** (PreToolUse on Bash) — [scripts/validate-issue.sh](scripts/validate-issue.sh) blocks `gh issue create` / `gh api` issue-creation calls whose body lacks the required sections or a label. Exit 2 feeds the missing list back to the agent. It is a lazy-path gate, not adversarial-proof: it checks the command string plus any literal `--body-file` it can read.
- **Hook** (UserPromptSubmit) — [scripts/inject-work-issue.sh](scripts/inject-work-issue.sh) injects a `/tickets:work-issue` pointer when the prompt reads like "work issue #N" (working verbs only; filing verbs stay with file-issue). Injection only, never blocks.
- **Hook** (PreToolUse on Bash) — [scripts/check-claim-adherence.sh](scripts/check-claim-adherence.sh) adherence tripwire ONLY: on `gh pr create` closing an issue, or `git commit`/`push` on an `issue-N` branch, it checks the issue's COMMENTS for this session's id and blocks with a report-your-failure message when absent. Comments only — the body's provenance mark carries the filing session's id and never counts as a claim. Fails open on anything it can't determine; the shape gate stays validate-issue.sh.

Installed as a skills-directory plugin at `~/.claude/skills/tickets/` — loads automatically each session (hook active after restart or `/reload-plugins`).

Validate the drafted body before filing:

```bash
~/.claude/skills/tickets/scripts/validate-issue.sh --file body.md
```

Escape hatch (operator use only, e.g. filing upstream on a third-party repo): set `CLAUDE_TICKET_SHAPE=off` in the environment or prefix it on the command. Agents must not use it on their own; it is greppable.

Companion policy: `~/.claude/rules/no-untracked-deferral.md` (when to file at all), `~/.claude/rules/human-intent.md` (provenance marks).
