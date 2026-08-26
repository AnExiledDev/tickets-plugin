---
description: Work a GitHub issue end to end — claim it, build it, ship it, close it. Use whenever asked to work, pick up, take, or implement an issue or ticket ("Work issue #123"), or when starting any tracked backlog item. Covers the claim protocol, scope guardrails, verification, and close-out.
argument-hint: "[repo] <issue number>"
allowed-tools: Bash(gh issue view:*), Bash(gh issue list:*), Bash(gh issue edit:*), Bash(gh issue comment:*), Bash(gh issue close:*), Bash(gh repo view:*), Bash(gh pr list:*), Bash(gh pr view:*), Bash(gh pr create:*), Bash(gh pr checks:*), Bash(gh pr merge:*), Bash(gh label list:*), Bash(date:*), Bash(intent:*)
---

# Work an issue

Take one tracked issue from claimed to closed. The issue body is the contract: a well-shaped issue (filed via `/tickets:file-issue`) contains everything needed, so the default is to work from it without re-exploring the codebase. Live context:

- Session: !`echo "${CLAUDE_CODE_SESSION_ID:-unknown}"`
- Now: !`date -u +"%Y-%m-%dT%H:%MZ"`

## 1. Read the whole issue

`gh issue view <n> --comments`. Read the body AND every comment — later comments carry claims, decisions, and human replies that amend the body.

- **Staleness check:** the Context section states when its pointers were verified. Confirm the named files and symbols still exist before trusting them; if the code has moved, re-locate it, but only what the change touches.
- **`## Blocked by`:** if it names an open issue, stop — this one is not workable. Say so and pick other work.
- **`needs-human` label:** the operator owes something first. Don't start; say what's owed.

## 2. Claim it — before touching anything

Two sessions silently working the same issue is the most expensive collision available. A claim you never looked for is not collision avoidance.

1. **Check for an active claim** in the comments. A claim is live unless released. It is dead only when its worktree is gone from disk AND no PR exists for its branch — then take over, saying so in a comment. Never let a dead claim freeze an issue forever.
2. **Post the claim** (assignee is not enough — every agent authenticates as the same user):

   ```
   **Claimed** — session `<session id>`
   worktree: <path> · branch: <branch> · <UTC time>
   ```

3. **Re-read the issue.** If another session claimed first while you were posting, release yours with a one-line comment and take the next item. Last writer loses; that is cheaper than a lock.

Comment lifecycle events only — claim, release, takeover, PR opened, decision taken, human intent captured. No progress chatter.

## 3. Isolate

Work on a branch named for the issue (e.g. `issue-123-short-slug`), in a worktree when the session pattern calls for one. Never on the default branch.

## 4. Honor the contract

- **`## Human intent` is binding, per line.** A verbatim operator quote outranks the AI-written acceptance criteria around it; on conflict the human line wins and you note the conflict in the PR. Never average the two.
- **`## Acceptance criteria` is the definition of done.** Each unchecked box is work; each checked claim in your PR must be true.
- **`## Out of scope` is a wall, not a suggestion.** Adjacent improvements, refactors, and discoveries do NOT ride along. Anything real you find while working: file it via `/tickets:file-issue` and keep moving. A gap in *this* change (missing test, wrong comment) is not a deferral — fix it here.
- **`## Edge cases` is the minimum test list.** Cover each named case or state in the PR why one doesn't apply.
- Where the issue is genuinely ambiguous and the codebase doesn't settle it, delegate the call (`delegate-decisions.md`) and post the DECISION line to the issue; don't guess silently and don't stall.

## 5. Build and verify

Implement the one diff the issue names — the smallest change satisfying the criteria. Then run the issue's `## Verification` section literally: every command, every manual check. Tests encode the criteria and must be watched failing before the fix (or against deliberately broken code) — a test you never saw red proves nothing.

## 6. Ship

Follow `background-job-pr-policy.md`: run the affected package's gate locally and see it pass, open a **normal** PR (not draft) with `Closes #<n>` as plain prose in the body (never backtick-quoted; neutral phrasing for every other issue number), watch CI, and merge. Comment the PR link on the issue when it opens.

## 7. Close out

- After merge, verify the issue actually closed: `gh issue view <n> --json state`. The closing keyword silently fails on non-default target branches and when quoted — close manually if still open.
- Clean up the branch/worktree you created.
- If the work surfaced human intent (an operator reply on the issue or PR), it is already captured there; anything said elsewhere gets quoted onto the issue before you finish.

## Stopping without finishing

If you abandon or park the issue for any reason, release the claim before you go: a comment saying why you stopped, what state the branch is in, and that the claim is released. A session that dies mid-work leaves an item that looks owned forever. If you're blocked on the operator, add `needs-human` and say exactly what's needed; if blocked on another issue, add `blocked` and name it in the body's `## Blocked by`. Then take other work — one blocked issue never halts a run.
