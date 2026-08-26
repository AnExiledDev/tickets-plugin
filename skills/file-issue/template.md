# Issue body template and per-section requirements

Every section below is required, in this order. The PreToolUse hook checks for each header mechanically; this file defines what makes the content *good*. A section filled with boilerplate passes the hook but fails the point: the ticket must let an agent start working from the body alone.

## The template

```markdown
> **AI-written.** No human has read this. Every requirement below is an agent's inference.
> `session: <id> | <date>`

Consequence: <who or what suffers today — a subject that can experience something>
Done when: <a state of the repo, verifiable by looking at it>

## Problem            <!-- or "## What to build" for features -->
...

## Human intent
...

## Context
...

## Acceptance criteria
- [ ] ...

## Verification
...

## Edge cases
...

## Out of scope
...

## Blocked by
None - can start immediately
```

## Per-section requirements

### Provenance mark (first two lines)

Output of `intent mark <tier>`, pasted verbatim. Tier 1 by default; tiers 2–4 only with an `op:` citation (see `human-intent.md`). Never hand-type the claim.

### `Consequence:` / `Done when:`

- **Consequence** names a subject that suffers *today*: "every PR pays 40s of CI", "the operator waits", "users lose drafts". "The file is long" is a description, not a consequence. Icebox issues may replace this line with `Icebox: <one line on why it's captured but unscheduled>` and must carry the `icebox` label.
- **Done when** names a repo state: "`check:code` runs tsc under tsgo", not "we understand X". For a **spike**, add `Timebox: <n hours>` and Done when names an artifact: "an ADR at docs/adr/... records the measured numbers and a decision".

### `## Problem` / `## What to build`

Behavior and end state, not layer-by-layer implementation. For bugs: observed vs expected, reproduction if known. Keep implementation freedom open unless a constraint is real — if a prototype settled a shape (schema, state machine, type), inline the decision-rich snippet and say where it came from.

### `## Human intent`

Everything the operator said that bears on this work, **verbatim**, each quote with its `op:` ref or source and date. Include expectations about feel/quality, not just function. Never paraphrase, never trim meaning. If nothing exists: `None — agent-inferred.` — that line is load-bearing; it tells the worker every requirement here is a hypothesis they may challenge.

### `## Context`

The section that kills re-discovery. Include:

- **Where the change lives**: file paths and key symbols (`src/core/session.ts` — `SessionStore.restore()`), the entry point to start reading from.
- **Related items**: prior PRs/issues/ADRs/log entries with one line each on why they matter.
- **Constraints not derivable from code**: gotchas, rejected approaches, environment limits.
- Close with the staleness line: `Pointers verified as of <date>; paths and symbols may have moved — verify before trusting.`

Include as much as is *prudent*: enough that the worker never does free-form discovery, not a codebase tour. Everything listed must be something you actually read while drafting — no guessed paths.

### `## Acceptance criteria`

Checkboxes, each **falsifiable**: an observer can mark it true or false without judgment calls. "Restore completes in <200ms on the sample fixture" passes; "restore is fast" fails. Cover behavior, not implementation steps. 3–7 is typical; if you need more, the issue is probably two issues.

### `## Verification`

Exact commands and steps that prove the criteria: the project's gate commands, the manual check (what to run, what to click, what output to expect). If verification needs fixtures or credentials, say where they are. A worker should be able to run this section top to bottom.

### `## Edge cases`

Enumerate the cases that will bite: boundary inputs, concurrent access, failure modes, migration of existing data. For each, say the expected handling — including "explicitly not handled, acceptable because X". `None known.` is allowed but must be true; a bug later found in an obvious edge case traces back to this line.

### `## Out of scope`

The guardrail against bloat. Name the adjacent work a competent agent would be tempted to do, and forbid it: refactors of neighboring code, generalizations, extra features, "while I'm here" cleanups. End with the standing rule: `Anything discovered while working this: file it via /tickets:file-issue, don't do it here.`

### `## Blocked by`

Real issue references, or `None - can start immediately`. A blocker is something whose absence makes this issue unworkable, not merely related work.
