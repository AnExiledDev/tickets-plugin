#!/usr/bin/env bash
# PreToolUse hook (Bash matcher): adherence tripwire for /tickets:work-issue.
#
# The BACKSTOP, not the gate. require-claim.sh blocks the first mutation off
# the ledger and is what enforces claiming before work starts; this catches the
# session that reached a PR without ever reading the issue through `gh issue
# view`, which is the one path the ledger cannot see.
#
# Its ONLY task is to identify a session shipping issue work without having
# claimed the issue, and force the model to report that failure. It validates
# nothing else, and it fails OPEN on anything it cannot determine (no issue
# number, gh unreachable, no such issue): a tripwire, not a security gate —
# the shape gate is validate-issue.sh.
#
# Triggers:
#   - `gh pr create` whose command text, --body-file/-F contents, or current
#     branch names an issue
#   - `git commit` / `git push` on a branch matching issue-<N>
# Check: does issue <N> have a COMMENT containing this session's id? The body
# never counts — its provenance mark carries the FILING session's id, which
# would make the filer look claimed.
#
# EVERY closing keyword is checked, not just the first. A PR closing five
# issues used to pass on one claim; #417 here closed three.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/_ledger.sh"

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

# Resolve the issue numbers: branch name first, then Closes/Fixes/Resolves
# anywhere in the PR text. A bare #N elsewhere is too noisy.
ISSUES=""
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"

if printf '%s' "$BRANCH" | grep -qE '^issue-[0-9]+'; then
  ISSUES="$(printf '%s' "$BRANCH" | grep -oE '[0-9]+' | head -1)"
elif printf '%s' "$CMD" | grep -q "gh pr create"; then
  # --body-file/-F keeps the keywords out of the command line entirely, which
  # is how four unclaimed issues shipped in one PR without a word from here.
  PR_TEXT="$CMD
$(body_file_text "$CMD")"
  ISSUES="$(printf '%s' "$PR_TEXT" |
            grep -oiE '(close[sd]?|fix(e[sd])?|resolve[sd]?) #[0-9]+' |
            grep -oE '[0-9]+' | sort -un)"
fi

[ -n "$ISSUES" ] || exit 0

# git commit/push with no issue-branch convention: nothing to key on, stay silent.
if ! printf '%s' "$CMD" | grep -q "gh pr create" && ! printf '%s' "$BRANCH" | grep -qE '^issue-[0-9]+'; then
  exit 0
fi

UNCLAIMED=""
for ISSUE in $ISSUES; do
  COMMENTS="$(timeout 10 gh issue view "$ISSUE" --json comments -q '.comments[].body // ""' 2>/dev/null)" || continue
  printf '%s' "$COMMENTS" | grep -qF "$SESSION_ID" && continue
  UNCLAIMED="${UNCLAIMED:+$UNCLAIMED }#$ISSUE"
done

[ -n "$UNCLAIMED" ] || exit 0

cat >&2 <<EOF
ADHERENCE FAILURE on $UNCLAIMED: no claim from this session ($SESSION_ID) is on those issues, which means /tickets:work-issue was not followed. Do BOTH, in order:
1. Report this failure to the user in your next message, plainly and un-buried: you worked a tracked issue without invoking /tickets:work-issue or claiming it.
2. Invoke /tickets:work-issue now — check each of $UNCLAIMED for another session's claim (if one exists, STOP and surface the collision), post your claim comment on each, then retry this command.
EOF
exit 2
