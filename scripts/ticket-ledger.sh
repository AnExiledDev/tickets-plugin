#!/usr/bin/env bash
# The claim ledger's user-facing half. The hooks write it; this is how a
# session answers the one question they ask.
#
#   ticket-ledger.sh skip <N>     this session is only reading #N, not working it
#   ticket-ledger.sh claim <N>    record a claim already posted on #N
#   ticket-ledger.sh status       what this session has read, claimed and skipped
#
# `skip` is the escape hatch, and it is deliberately per-issue and per-session:
# read-only work on an issue should cost exactly one decision, once.
#
# The session id comes from $CLAUDE_CODE_SESSION_ID, or as a trailing argument
# when that is not exported.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/_ledger.sh"

usage() {
  sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

ACTION="${1:-}"
[ -n "$ACTION" ] || usage 1

SESSION="${CLAUDE_CODE_SESSION_ID:-${3:-}}"

if ! ledger_ok; then
  echo "jq is not installed, so the claim ledger is inert. Nothing to do." >&2
  exit 0
fi

if [ -z "$SESSION" ]; then
  echo "No session id. Export CLAUDE_CODE_SESSION_ID or pass it as the last argument." >&2
  exit 1
fi

NOW="$(date +%s)"
ledger_lock "$SESSION"
STATE="$(ledger_read "$SESSION")"

case "$ACTION" in
  skip|claim)
    ISSUE="$(printf '%s' "${2:-}" | grep -oE '[0-9]+' | head -1)"
    [ -n "$ISSUE" ] || usage 1

    [ "$ACTION" = "skip" ] && NEW="skipped" || NEW="claimed"
    ledger_write "$SESSION" "$(ledger_set_state "$STATE" "$ISSUE" "$NEW" "$NOW")"
    echo "#$ISSUE: $NEW for session $SESSION"
    ;;

  status)
    printf '%s' "$STATE" | jq -r '
      .issues | to_entries
      | if length == 0 then "nothing read yet"
        else (.[] | "#\(.key): \(.value.state)") end
    '
    ;;

  *)
    usage 1
    ;;
esac
