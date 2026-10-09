#!/usr/bin/env bash
# PreToolUse hook (Edit|Write|Task|Bash matchers): the first mutation pays the
# debt that reading an issue created.
#
# This is the "claim before work starts" gate. It fires on the earliest action
# that is unambiguously work rather than reading:
#
#   Edit / Write     the session is doing the work itself, on a file inside
#                    its own repository (a scratch file in /tmp is not work)
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
    printf '%s' "$CMD" | grep -qE "${GIT_SUBCMD_RE}commit" || exit 0
    ;;
  *) exit 0 ;;
esac

SESSION="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)"
[ -n "$SESSION" ] || exit 0

NOW="$(date +%s)"
CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)"

# An absolute path with every symlink resolved, for a file that may not exist
# yet. `realpath -m` where it works (GNU, Git Bash); elsewhere (macOS) the
# nearest existing ancestor is resolved and the rest appended as written.
resolve_path() {
  local path="$1" dir rest="" parent

  case "$path" in
    [A-Za-z]:*) path="$(printf '%s' "$path" | tr '\\' '/')" ;;
  esac

  realpath -m -- "$path" 2>/dev/null && return 0

  dir="$path"
  while [ ! -d "$dir" ]; do
    parent="${dir%/*}"
    [ "$parent" != "$dir" ] || { printf '%s\n' "$path"; return 0; }
    rest="/${dir##*/}$rest"
    dir="${parent:-/}"
  done

  printf '%s%s\n' "$(cd "$dir" 2>/dev/null && pwd -P)" "$rest" | sed 's#^//*#/#'
}

# True when an Edit, Write or NotebookEdit targets a file outside the session's
# repository: drafting an issue body in /tmp is not work on any issue. Without
# a repository to compare against (no cwd, or a cwd outside git) nothing is
# outside, so the call stays gated exactly as before. Task, Agent and git
# commit name no file and always stay gated.
target_is_outside_repo() {
  local path top

  case "$TOOL" in
    Edit|Write) path="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)" ;;
    NotebookEdit) path="$(printf '%s' "$INPUT" | jq -r '.tool_input.notebook_path // empty' 2>/dev/null)" ;;
    *) return 1 ;;
  esac
  [ -n "$path" ] && [ -n "$CWD" ] || return 1

  top="$(timeout 5 git -C "$CWD" rev-parse --show-toplevel 2>/dev/null)" || return 1
  [ -n "$top" ] || return 1

  case "$path" in
    /*|[A-Za-z]:[/\\]*) ;;
    *) path="$CWD/$path" ;;
  esac
  path="$(resolve_path "$path")"
  top="$(resolve_path "$top")"

  case "$path/" in
    "$top"/*) return 1 ;;
  esac
  return 0
}

target_is_outside_repo && exit 0

ledger_lock "$SESSION"

# A branch or worktree named `issue-<N>` is a claim-worthy signal the ledger
# never heard: a session handed a ready worktree does its reading in the
# editor, never runs `gh issue view`, and so passes the gate with an empty
# ledger. Unlike prompt text this cannot mass-seed, because a checkout names
# exactly one issue, and check-claim-adherence.sh already trusts it at PR time.
seed_from_branch() {
  local cwd branch ref n state
  cwd="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)"
  [ -n "$cwd" ] || return 0

  branch="$(timeout 5 git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  ref="$(issue_from_ref "$branch")"
  [ -n "$ref" ] || ref="$(issue_from_ref "$cwd")"
  [ -n "$ref" ] || return 0

  state="$(ledger_read "$SESSION")"
  ledger_write "$SESSION" "$(ledger_note_seen "$state" "$ref" "$NOW")"
}

seed_from_branch


STATE="$(ledger_read "$SESSION")"

UNDECIDED="$(printf '%s' "$STATE" | jq -r '
  .issues | to_entries | map(select(.value.state == "undecided")) | .[].key
' 2>/dev/null)" || exit 0
[ -n "$UNDECIDED" ] || exit 0

# Only issues about to block are checked, at most ten per call, so a quiet
# session never pays for the lookup.
DUE=""
CHECKED=0
for n in $UNDECIDED; do
  if ledger_may_nag "$STATE" "$n" "$NOW" && [ "$CHECKED" -lt 10 ]; then
    CHECKED=$((CHECKED + 1))

    if claimed_on_github "$n" "$SESSION" "$CWD"; then
      STATE="$(ledger_set_state "$STATE" "$n" "claimed" "$NOW")"
      continue
    fi
  fi

  if ledger_may_nag "$STATE" "$n" "$NOW"; then
    DUE="${DUE:+$DUE }#$n"
    STATE="$(ledger_note_nagged "$STATE" "$n" "$NOW")"
  fi
done

ledger_write "$SESSION" "$STATE"

[ -n "$DUE" ] || exit 0

FIRST="$(printf '%s' "$DUE" | tr ' ' '\n' | head -1 | tr -d '#')"

cat >&2 <<EOF
CLAIM FIRST: you have read $DUE and decided nothing about them, and $TOOL is work starting. Two sessions silently on one issue is the most expensive collision there is, so decide now, per issue:

  Working it  -> post the claim comment /tickets:work-issue specifies, carrying this session id ($SESSION). Check the issue for another session's claim first; if one is live, STOP and surface the collision.
  Only reading -> ~/.claude/skills/tickets/scripts/ticket-ledger.sh skip $FIRST

Then retry this command. Claiming is what makes the work visible to every other session on this box; doing it after the work is built makes it a receipt instead of a lock.
EOF
exit 2
