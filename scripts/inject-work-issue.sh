#!/usr/bin/env bash
# UserPromptSubmit hook. Two jobs, both keyed off the same recognition.
#
# 1. When the prompt reads like "work issue #N", inject a deterministic pointer
#    at /tickets:work-issue. The injected skills list is not fully reliable;
#    this fires on the prompt itself, so recognition cannot miss.
#
# 2. Seed the ledger with every issue number the prompt names, as undecided.
#    Until this existed the ledger was written ONLY by `gh issue view N`
#    (record-issue-view.sh), so a number that arrived in the operator's prompt,
#    or through `gh api`, or as an issue URL, recorded nothing at all and
#    require-claim.sh's pre-work gate never fired. The claim then landed at PR
#    time via check-claim-adherence.sh, which makes it a receipt instead of a
#    lock. The prompt is the other moment where the number is unambiguous.
#
# Seeding is deliberately tied to the working-verb recognition below rather
# than to any `#N` in any prompt: filing verbs are excluded there, so "file an
# issue about #12" seeds nothing. A number that slips through anyway costs one
# block and one `ticket-ledger.sh skip N`.
#
# Injection only - it never blocks anything, and it stays silent on every other
# prompt. Fails open on everything.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/_ledger.sh"

INPUT="$(cat)" || exit 0
PROMPT="$(printf '%s' "$INPUT" | jq -r '.prompt // empty' 2>/dev/null)" || exit 0
[ -n "$PROMPT" ] || exit 0

# Every issue number the prompt names, bare or inside a GitHub issue URL.
prompt_issue_numbers() {
  {
    printf '%s' "$PROMPT" | grep -oE '#[0-9]+' | tr -d '#'
    printf '%s' "$PROMPT" | grep -oiE 'issues/[0-9]+' | grep -oE '[0-9]+'
  } 2>/dev/null | sort -un
}

seed_ledger() {
  ledger_ok || return 0
  hook_is_subagent "$INPUT" && return 0

  local session numbers now state n
  session="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)"
  [ -n "$session" ] || return 0

  numbers="$(prompt_issue_numbers)"
  [ -n "$numbers" ] || return 0

  now="$(date +%s)"
  state="$(ledger_read "$session")"

  # ledger_note_seen preserves an existing claimed/skipped state, so a prompt
  # that mentions an issue already decided this session reopens nothing.
  for n in $numbers; do
    state="$(ledger_note_seen "$state" "$n" "$now")"
  done

  ledger_write "$session" "$state"
}

# Working verbs near "issue/ticket/epic" or a bare #N. Filing verbs (file,
# create, make, open) deliberately absent - those belong to /tickets:file-issue.
#
# "epic" and issue URLs are here because both were missed: "work the epic to
# completion" names no issue and no ticket, and a github issue URL contains no
# "#N" for the second pattern to find. Between them they let an eleven-issue
# epic be worked with one claim posted.
if printf '%s' "$PROMPT" | grep -qiE '\b(work|works|working|pick up|take|start|resume|continue|implement|finish)\b[^.]{0,40}\b(issue|ticket|epic)s?\b' ||
   printf '%s' "$PROMPT" | grep -qiE '\b(work|pick up|take|start|resume|continue|implement|finish)\b[^.]{0,20}#[0-9]+' ||
   printf '%s' "$PROMPT" | grep -qiE 'github\.com/[^ ]+/issues/[0-9]+'; then
  seed_ledger
  echo "This prompt looks like tracked-issue work. Invoke the /tickets:work-issue skill before touching anything — it carries the claim protocol (claim comment with your session id, last-writer-loses re-read). Never start a tracked item without claiming it there first."
fi

exit 0
