#!/usr/bin/env bash
# PostToolUse hook (Bash matcher): reading a tracked issue creates an obligation.
#
# `gh issue view N` is the one moment where the issue number is unambiguous and
# always present - nobody works an issue they have not read - so this is where
# the ledger gets written. Two separate things then happen, and they have
# deliberately different noise rules:
#
#   * A COLLISION (another session's claim on that issue) is injected ALWAYS.
#     No dedup, no burst cap. It is a fact about the world, it is rare, and it
#     is worthless if it arrives late.
#
#   * A REMINDER to claim or skip is injected at most once per issue per
#     session, and at most $TICKETS_INJECT_BURST times per
#     $TICKETS_INJECT_WINDOW seconds. Both caps are needed and neither
#     substitutes for the other: dedup handles re-reading one issue, the burst
#     cap handles a triage sweep across thirty.
#
# Suppressing a reminder loses nothing. The ledger entry is written on EVERY
# view regardless, and require-claim.sh blocks the first mutation with the full
# undecided list. Worst case is finding out at the first edit instead of at the
# read, which is still before the work.
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

printf '%s' "$CMD" | grep -qE 'gh +issue +view' || exit 0

SESSION="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)"
[ -n "$SESSION" ] || exit 0

# The number, whether written bare or as an issue URL.
ISSUE="$(printf '%s' "$CMD" | sed -E 's#.*gh +issue +view +##' |
         grep -oE '[0-9]+' | head -1)"
[ -n "$ISSUE" ] || exit 0

NOW="$(date +%s)"
STATE="$(ledger_read "$SESSION")"
WAS="$(ledger_state_of "$STATE" "$ISSUE")"

STATE="$(ledger_note_seen "$STATE" "$ISSUE" "$NOW")"

# Prefer the comments the model already fetched over a second API call. Only
# `--comments` puts them in the output, so fall back when they are not there.
BODY="$(printf '%s' "$INPUT" | jq -r '
  (.tool_response.stdout // .tool_response.output // .tool_response // "") | tostring
' 2>/dev/null)"

if ! printf '%s' "$BODY" | grep -qi 'claim'; then
  BODY="$(timeout 10 gh issue view "$ISSUE" --json comments -q '.comments[].body // ""' 2>/dev/null || true)"
fi

OTHERS="$(claim_session_ids "$BODY" | grep -vF "$SESSION" || true)"

NOTE=""

if [ -n "$OTHERS" ]; then
  NOTE="COLLISION: issue #$ISSUE already carries a claim from another session ($(printf '%s' "$OTHERS" | tr '\n' ' ')). Per /tickets:work-issue a claim is live unless released, and dead only when its worktree is gone from disk AND no PR exists for its branch. Do not start work on #$ISSUE until you have checked that and said which it is."
fi

if [ "$WAS" = "unknown" ] && ledger_may_inject "$STATE" "$NOW"; then
  STATE="$(ledger_note_injected "$STATE" "$NOW")"
  NOTE="${NOTE:+$NOTE }You have read issue #$ISSUE and have not decided about it. If you are going to work it, claim it now (a comment on #$ISSUE carrying this session id, $SESSION). If you are only reading, run: ~/.claude/skills/tickets/scripts/ticket-ledger.sh skip $ISSUE — otherwise your first edit, commit or subagent spawn will be blocked until you decide."
fi

ledger_write "$SESSION" "$STATE"

[ -n "$NOTE" ] || exit 0

jq -n --arg c "$NOTE" '{
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: $c
  }
}'
exit 0
