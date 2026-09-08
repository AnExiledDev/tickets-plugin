#!/usr/bin/env bash
# PostToolUse(Bash): a branch or worktree named `issue-<N>` is the session
# saying which issue it is about, in the one place text inference cannot go
# wrong - a checkout names exactly one issue. require-claim.sh reads the
# current branch, which covers a session already inside the worktree; this
# covers the other half, where the branch is created from the parent checkout
# and the work happens before anything cds into it.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_ledger.sh
. "$DIR/_ledger.sh"

INPUT="$(cat)"
ledger_ok || exit 0
hook_is_subagent "$INPUT" && exit 0

CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)"
[ -n "$CMD" ] || exit 0

printf '%s' "$CMD" |
  grep -qE "${GIT_SUBCMD_RE}(worktree +add|switch +-c|checkout +-b|branch)" || exit 0

ISSUE="$(issue_from_ref "$CMD")"
[ -n "$ISSUE" ] || exit 0

SESSION="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)"
[ -n "$SESSION" ] || exit 0

NOW="$(date +%s)"
ledger_write "$SESSION" "$(ledger_note_seen "$(ledger_read "$SESSION")" "$ISSUE" "$NOW")"
exit 0
