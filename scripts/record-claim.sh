#!/usr/bin/env bash
# PostToolUse hook (Bash matcher): a posted claim IS the ledger write.
#
# `gh issue comment N` whose body carries this session's id is exactly what the
# work-issue skill tells you to post, so the happy path needs no extra command
# and no discipline of its own: claim the issue the way you already would, and
# the obligation clears itself.
#
# The body is read from the command text AND from --body-file/-F, because the
# claim comment is usually long enough to be written to a file first.
#
# Fails open on everything.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/_ledger.sh"

ledger_ok || exit 0

INPUT="$(cat)" || exit 0
hook_is_subagent "$INPUT" && exit 0

CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)" || exit 0
[ -n "$CMD" ] || exit 0

printf '%s' "$CMD" | grep -qE 'gh +issue +comment' || exit 0

SESSION="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)"
[ -n "$SESSION" ] || exit 0

# Any argument position: `gh issue comment --repo o/r2 12` fed the old read
# the `2` out of the repo name and marked the wrong issue claimed.
ISSUE="$(gh_issue_number "$CMD" comment)"
[ -n "$ISSUE" ] || exit 0

BODY="$CMD
$(body_file_text "$CMD")"

printf '%s' "$BODY" | grep -qF "$SESSION" || exit 0

NOW="$(date +%s)"
ledger_write "$SESSION" "$(ledger_set_state "$(ledger_read "$SESSION")" "$ISSUE" "claimed" "$NOW")"
exit 0
