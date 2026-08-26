# tickets

Claude Code plugin enforcing well-shaped, self-contained GitHub issues on this box.

- **Skill** `/tickets:file-issue` — the workflow for filing an issue: triage gate, targeted context gathering, verbatim human intent, label conventions. Anatomy lives in [skills/file-issue/template.md](skills/file-issue/template.md), labels in [skills/file-issue/labels.md](skills/file-issue/labels.md), a worked example in [skills/file-issue/examples.md](skills/file-issue/examples.md).
- **Hook** (PreToolUse on Bash) — [scripts/validate-issue.sh](scripts/validate-issue.sh) blocks `gh issue create` / `gh api` issue-creation calls whose body lacks the required sections or a label. Exit 2 feeds the missing list back to the agent. It is a lazy-path gate, not adversarial-proof: it checks the command string plus any literal `--body-file` it can read.

Installed as a skills-directory plugin at `~/.claude/skills/tickets/` — loads automatically each session (hook active after restart or `/reload-plugins`).

Validate the drafted body before filing:

```bash
~/.claude/skills/tickets/scripts/validate-issue.sh --file body.md
```

Escape hatch (operator use only, e.g. filing upstream on a third-party repo): set `CLAUDE_TICKET_SHAPE=off` in the environment or prefix it on the command. Agents must not use it on their own; it is greppable.

Companion policy: `~/.claude/rules/no-untracked-deferral.md` (when to file at all), `~/.claude/rules/human-intent.md` (provenance marks).
