#!/usr/bin/env bash
# PreToolUse hook (Edit|Write|Task|Bash matchers): the first mutation pays the
# debt that reading an issue created.
#
# This is the "claim before work starts" gate. It fires on the earliest action
# that is unambiguously work rather than reading:
#
#   Edit / Write     the session is doing the work itself
#   Task             the session is orchestrating - this is the one that
#                    matters, because an orchestrator's own tree stays clean
#                    while subagents do every edit
#   git commit       the fallback for anything the two above missed
#
# It needs no branch-name convention and no closing keyword, because it reads
# the ledger rather than inferring an issue number from text. That inference is
# what made every earlier check late and holey.
#
# COOLDOWN: an issue blocks at most once per $TICKETS_NAG_COOLDOWN seconds. A
# session that will not decide must not be wedged forever - it gets one loud,
# actionable interrupt, then it proceeds and check-claim-adherence.sh catches
# it at PR time. That is a deliberate weakening of enforcement in exchange for
# never deadlocking a session.
#
# Fails open on everything.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/_ledger.sh"

ledger_ok || exit 0

INPUT="$(cat)" || exit 0
hook_is_subagent "$INPUT" && exit 0

TOOL="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)" || exit 0

case "$TOOL" in
  Edit|Write|NotebookEdit|Task|Agent) ;;
  Bash)
    CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)"
    printf '%s' "$CMD" | grep -qE 'git +commit' || exit 0
    ;;
  *) exit 0 ;;
esac

SESSION="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)"
[ -n "$SESSION" ] || exit 0

NOW="$(date +%s)"
STATE="$(ledger_read "$SESSION")"

UNDECIDED="$(printf '%s' "$STATE" | jq -r '
  .issues | to_entries | map(select(.value.state == "undecided")) | .[].key
' 2>/dev/null)" || exit 0
[ -n "$UNDECIDED" ] || exit 0

DUE=""
for n in $UNDECIDED; do
  if ledger_may_nag "$STATE" "$n" "$NOW"; then
    DUE="${DUE:+$DUE }#$n"
    STATE="$(ledger_note_nagged "$STATE" "$n" "$NOW")"
  fi
done

[ -n "$DUE" ] || exit 0

ledger_write "$SESSION" "$STATE"

FIRST="$(printf '%s' "$DUE" | tr ' ' '\n' | head -1 | tr -d '#')"

cat >&2 <<EOF
CLAIM FIRST: you have read $DUE and decided nothing about them, and $TOOL is work starting. Two sessions silently on one issue is the most expensive collision there is, so decide now, per issue:

  Working it  -> post the claim comment /tickets:work-issue specifies, carrying this session id ($SESSION). Check the issue for another session's claim first; if one is live, STOP and surface the collision.
  Only reading -> ~/.claude/skills/tickets/scripts/ticket-ledger.sh skip $FIRST

Then retry this command. Claiming is what makes the work visible to every other session on this box; doing it after the work is built makes it a receipt instead of a lock.
EOF
exit 2
