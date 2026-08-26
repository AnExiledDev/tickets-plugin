# Worked example

A complete issue body that passes the hook and the point. Filed as:

```bash
gh issue create -R acme/botbase --title "Restore session cursor after daemon restart" \
  --body-file /tmp/issue-body.md --label "type:bug"
```

```markdown
> **AI-written.** No human has read this. Every requirement below is an agent's inference.
> `session: 3b4ac1f2-b28b-471b-bc68-5ce766d3f3e5 | 2026-08-26`

Consequence: every daemon restart (nightly, plus each deploy) silently drops all live session cursors, so agents resume from stale positions and re-process work.
Done when: a restarted daemon restores each session's cursor from the persisted store and a regression test covers the restart path.

## Problem

`SessionStore.restore()` is only called on cold start (`src/daemon/boot.ts:41`), not on the SIGTERM→relaunch path the nightly restart uses. Observed: after the 03:00 restart, `session.cursor` is `0` for every live session. Expected: cursor equals the last persisted value.

## Human intent

> "if the box restarts I expect everything to just pick up where it left off, I shouldn't even notice"
> — operator, op:2026-08-19-1142-ab3c (2026-08-19)

## Context

- `src/daemon/boot.ts:41` — cold-start path calls `SessionStore.restore()`; start reading here.
- `src/daemon/lifecycle.ts` — `onRelaunch()` is the SIGTERM path; it rebuilds sessions but never touches the store.
- `src/core/session-store.ts` — `persist()` runs on every cursor advance, so the data is already on disk; only the read-back is missing.
- PR #212 introduced the relaunch path; its body says persistence was "out of scope, follow-up needed" — this is that follow-up.
- Gotcha: the store file is owned by the daemon user; tests must use the tmp-dir fixture (`test/fixtures/store.ts`), not the real path.

Pointers verified as of 2026-08-26; paths and symbols may have moved — verify before trusting.

## Acceptance criteria

- [ ] After SIGTERM relaunch, every live session's `cursor` equals its last persisted value.
- [ ] Cold start behavior is unchanged.
- [ ] A session persisted with a cursor beyond the current queue length clamps to queue end rather than throwing.
- [ ] A regression test exercises the relaunch path and fails against current `main`.

## Verification

- `bun test src/daemon` — includes the new relaunch test; watch it fail before the fix (Rule 7).
- Manual: `bun run daemon:dev`, advance a session, `kill -TERM <pid>`, wait for relaunch, confirm the cursor in `~/.botbase/store.json` matches the resumed session.
- Gate: `bun run check` on the affected package.

## Edge cases

- Store file missing or corrupt on relaunch: fall back to cursor 0 and log a warning — same as today's cold-start behavior, acceptable.
- Relaunch racing an in-flight `persist()`: `persist()` writes atomically via rename (`session-store.ts`), so last-write-wins is fine; do not add locking.
- Sessions created after the last persist: restore must not delete them.

## Out of scope

- No refactor of `lifecycle.ts` (it's tangled; tempting; separate issue if it blocks you).
- No new persistence format, no schema versioning, no store migration.
- Cursor persistence *frequency* stays as-is; batching writes is not this issue.
- Anything discovered while working this: file it via /tickets:file-issue, don't do it here.

## Blocked by

None - can start immediately
```

Why this works: the worker opens `boot.ts:41` and `lifecycle.ts` and is oriented in two minutes; the operator's expectation is quoted, not paraphrased; every criterion is checkable; the tempting refactor is explicitly fenced off.
