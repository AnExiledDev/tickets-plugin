#!/usr/bin/env bash
# Shared state for the claim ledger. Sourced by the hooks, never run on its own.
#
# The problem it exists to solve: every earlier adherence check inferred the
# issue number from text - the prompt's wording, the branch name, the command
# line - and inference is what kept failing. The ledger records the number at
# the one moment it is unambiguous (`gh issue view N`) and everything else
# reads that recorded fact instead of guessing.
#
# One file per session at $TICKETS_STATE_DIR/<session-id>.json:
#
#   { "issues":   { "338": { "state": "undecided|claimed|skipped",
#                            "seen": <epoch>, "nagged": <epoch> } },
#     "injected": [ <epoch>, ... ] }
#
# `injected` is the burst cap's window, not a log; it is trimmed on write.
#
# Every helper FAILS OPEN. No jq, an unwritable state dir, a truncated file:
# all of it degrades to "no state" and lets the model work. These are
# tripwires, not security gates, and a broken tripwire must never be the
# thing that stops a session.

TICKETS_STATE_DIR="${TICKETS_STATE_DIR:-$HOME/.claude/state/tickets}"

# Reminders are a courtesy; the ledger is the enforcement. Suppressing an
# injection loses nothing, because require-claim.sh still blocks the first
# mutation with the whole undecided list.
TICKETS_INJECT_WINDOW="${TICKETS_INJECT_WINDOW:-600}"   # burst window, seconds
TICKETS_INJECT_BURST="${TICKETS_INJECT_BURST:-3}"       # injections per window
TICKETS_NAG_COOLDOWN="${TICKETS_NAG_COOLDOWN:-600}"     # re-block the same issue no sooner than this

ledger_ok() { command -v jq >/dev/null 2>&1; }

# A subagent's tool calls fire these hooks with the PARENT's session_id, and
# are told apart only by `agent_id` being populated. The ledger deliberately
# ignores them: the orchestrator is the one that reads issues, decides and
# claims, and its Task spawn is already gated, so letting a subagent write
# entries the parent must then clear - or blocking an implementer mid-edit on
# a decision it is not allowed to make - is cross-talk bought for nothing.
hook_is_subagent() {
  local id
  id="$(printf '%s' "$1" | jq -r '.agent_id // empty' 2>/dev/null)"
  [ -n "$id" ]
}

ledger_path() { printf '%s/%s.json' "$TICKETS_STATE_DIR" "$1"; }

ledger_read() {
  local file
  file="$(ledger_path "$1")"

  if [ -s "$file" ] && jq -e . "$file" >/dev/null 2>&1; then
    cat "$file"
    return 0
  fi

  printf '%s' '{"issues":{},"injected":[]}'
}

ledger_write() {
  local file
  file="$(ledger_path "$1")"

  mkdir -p "$TICKETS_STATE_DIR" 2>/dev/null || return 0
  printf '%s' "$2" > "$file.tmp" 2>/dev/null && mv -f "$file.tmp" "$file" 2>/dev/null
  return 0
}

ledger_state_of() {
  printf '%s' "$1" | jq -r --arg n "$2" '.issues[$n].state // "unknown"' 2>/dev/null || printf 'unknown'
}

# Record an issue as undecided. An issue already claimed or skipped keeps that
# state - re-reading a claimed issue is normal and must not reopen the question.
ledger_note_seen() {
  printf '%s' "$1" | jq --arg n "$2" --argjson t "$3" '
    .issues[$n] = (.issues[$n] // {state: "undecided", seen: $t, nagged: 0})
  ' 2>/dev/null || printf '%s' "$1"
}

ledger_set_state() {
  printf '%s' "$1" | jq --arg n "$2" --arg s "$3" --argjson t "$4" '
    .issues[$n] = ((.issues[$n] // {seen: $t, nagged: 0}) + {state: $s})
  ' 2>/dev/null || printf '%s' "$1"
}

# The burst cap: a triage sweep viewing thirty issues must not emit thirty
# reminders. Per-issue dedup does nothing for that case, and this does nothing
# for a re-read, so both exist.
ledger_may_inject() {
  local count
  count="$(printf '%s' "$1" | jq --argjson t "$2" --argjson w "$TICKETS_INJECT_WINDOW" \
    '[.injected[] | select(. > ($t - $w))] | length' 2>/dev/null)" || return 0
  [ "${count:-0}" -lt "$TICKETS_INJECT_BURST" ]
}

ledger_note_injected() {
  printf '%s' "$1" | jq --argjson t "$2" --argjson w "$TICKETS_INJECT_WINDOW" '
    .injected = ([.injected[]?, $t] | map(select(. > ($t - $w))))
  ' 2>/dev/null || printf '%s' "$1"
}

# True when this issue may block again. The cooldown keeps a session that
# refuses to decide from being wedged forever; check-claim-adherence.sh is
# still there at PR time as the backstop.
ledger_may_nag() {
  local last
  last="$(printf '%s' "$1" | jq -r --arg n "$2" '.issues[$n].nagged // 0' 2>/dev/null)" || return 0
  [ $((${3:-0} - ${last:-0})) -ge "$TICKETS_NAG_COOLDOWN" ]
}

ledger_note_nagged() {
  printf '%s' "$1" | jq --arg n "$2" --argjson t "$3" '
    .issues[$n].nagged = $t
  ' 2>/dev/null || printf '%s' "$1"
}

# `gh pr create --body-file X` and `-F X` keep the closing keywords out of the
# command text entirely, which is how four unclaimed issues shipped in one PR
# without the adherence hook saying a word. Read the file so it can see them.
body_file_text() {
  local path
  path="$(printf '%s' "$1" | grep -oE -- '(--body-file|-F)[=[:space:]]+[^[:space:]]+' | head -1 |
          sed -E 's/^(--body-file|-F)[=[:space:]]+//' | tr -d "\"'")"
  [ -n "$path" ] || return 0

  case "$path" in
    '~'*) path="$HOME${path#\~}" ;;
  esac

  [ -f "$path" ] && cat "$path" 2>/dev/null
  return 0
}

# Claim comments are written by the work-issue skill as:
#   **Claimed** - session `<id>`
# Anything carrying a session id on a "claim" line counts, so a reworded claim
# still registers.
claim_session_ids() {
  printf '%s' "$1" | grep -iE 'claim' -A2 | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | sort -u
}
