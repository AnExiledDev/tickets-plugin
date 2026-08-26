#!/usr/bin/env bash
# PreToolUse hook (Bash matcher): adherence tripwire for /tickets:work-issue.
#
# Its ONLY task is to identify a session shipping issue work without having
# claimed the issue, and force the model to report that failure. It validates
# nothing else, and it fails OPEN on anything it cannot determine (no issue
# number, gh unreachable, no such issue): a tripwire, not a security gate —
# the shape gate is validate-issue.sh.
#
# Triggers:
#   - `gh pr create` whose command text or current branch names an issue
#   - `git commit` / `git push` on a branch matching issue-<N>
# Check: does issue <N> have a COMMENT containing this session's id? The body
# never counts — its provenance mark carries the FILING session's id, which
# would make the filer look claimed.
set -uo pipefail

INPUT="$(cat)" || exit 0
CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)" || exit 0
[ -n "$CMD" ] || exit 0

case "$CMD" in
  *"gh pr create"*|*"git commit"*|*"git push"*) ;;
  *) exit 0 ;;
esac

SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)"
CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)"
[ -n "$SESSION_ID" ] || exit 0
[ -n "$CWD" ] && [ -d "$CWD" ] && cd "$CWD" 2>/dev/null || exit 0

# Resolve the issue number: branch name first, then Closes/Fixes/Resolves in
# the command text (pr create bodies). A bare #N elsewhere is too noisy.
ISSUE=""
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"

if printf '%s' "$BRANCH" | grep -qE '^issue-[0-9]+'; then
  ISSUE="$(printf '%s' "$BRANCH" | grep -oE '[0-9]+' | head -1)"
elif printf '%s' "$CMD" | grep -q "gh pr create"; then
  ISSUE="$(printf '%s' "$CMD" | grep -oiE '(close[sd]?|fix(e[sd])?|resolve[sd]?) #[0-9]+' | grep -oE '[0-9]+' | head -1)"
fi

[ -n "$ISSUE" ] || exit 0

# git commit/push with no issue-branch convention: nothing to key on, stay silent.
if ! printf '%s' "$CMD" | grep -q "gh pr create" && ! printf '%s' "$BRANCH" | grep -qE '^issue-[0-9]+'; then
  exit 0
fi

COMMENTS="$(timeout 10 gh issue view "$ISSUE" --json comments -q '.comments[].body // ""' 2>/dev/null)" || exit 0

if printf '%s' "$COMMENTS" | grep -qF "$SESSION_ID"; then
  exit 0
fi

cat >&2 <<EOF
ADHERENCE FAILURE on issue #$ISSUE: no claim from this session ($SESSION_ID) is on the issue, which means /tickets:work-issue was not followed. Do BOTH, in order:
1. Report this failure to the user in your next message, plainly and un-buried: you worked a tracked issue without invoking /tickets:work-issue or claiming it.
2. Invoke /tickets:work-issue now — check issue #$ISSUE for another session's claim (if one exists, STOP and surface the collision), post your claim comment, then retry this command.
EOF
exit 2
