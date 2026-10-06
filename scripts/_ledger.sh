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

# jq built for Windows writes CRLF, which leaves a \r on every "$(jq -r ...)"
# value; -b stops it. Defined only when this jq takes -b (1.7+), so a missing or
# older jq behaves exactly as before.
case "${OSTYPE:-}" in
  msys* | cygwin*) command jq -b -n 1 >/dev/null 2>&1 && jq() { command jq -b "$@"; } ;;
esac

TICKETS_STATE_DIR="${TICKETS_STATE_DIR:-$HOME/.claude/state/tickets}"

# Reminders are a courtesy; the ledger is the enforcement. Suppressing an
# injection loses nothing, because require-claim.sh still blocks the first
# mutation with the whole undecided list.
TICKETS_INJECT_WINDOW="${TICKETS_INJECT_WINDOW:-600}"   # burst window, seconds
TICKETS_INJECT_BURST="${TICKETS_INJECT_BURST:-3}"       # injections per window
TICKETS_NAG_COOLDOWN="${TICKETS_NAG_COOLDOWN:-600}"     # re-block the same issue no sooner than this
TICKETS_LOCK_WAIT="${TICKETS_LOCK_WAIT:-5}"             # seconds a hook waits for the ledger lock

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

# The issue number a `gh issue <verb>` command acts on, from ANY argument
# position. Flags can sit before the number (`gh issue view --repo o/r 14`), so
# the first token after the verb is not it; reading the first digits anywhere to
# the right is worse, because prose about the command feeds it numbers. Walk the
# tokens after the verb, stop at a shell separator, take the first bare number or
# `issues/<N>` URL. A number the shell would expand (`gh issue view "$N"`) is not
# recoverable from the command text and yields nothing, which fails open.
#
# The separator is a sentinel word, not a newline: once tr has split on
# whitespace a newline token can never compare equal, so the old stop never
# fired and `gh issue view "$n" | head -1` recorded a phantom issue 1.
gh_issue_number() {
  printf '%s' "$1" |
    sed -E 's/(&&|\|\||[;|&])/ __SEP__ /g' |
    tr ' \t' '\n\n' |
    awk -v verb="$2" '
      { gsub(/^["'"'"']+|["'"'"']+$/, "") }
      seen && $0 == "__SEP__" { exit }
      seen && /^#?[0-9]+$/ { gsub(/#/, ""); print; exit }
      seen && /issues\/[0-9]+/ {
        match($0, /issues\/[0-9]+/)
        print substr($0, RSTART + 7, RLENGTH - 7)
        exit
      }
      p2 == "gh" && p1 == "issue" && $0 == verb { seen = 1 }
      { p2 = p1; p1 = $0 }
    ' 2>/dev/null | head -1
}

# `git -C <dir> commit` is house style for worktree jobs on this box and matched
# neither gate: both greps required `git` and the subcommand to be adjacent. Any
# run of flags (with or without values) may sit between them.
GIT_SUBCMD_RE='git([[:space:]]+-[^[:space:]]+([[:space:]]+[^-][^[:space:]]*)?)*[[:space:]]+'

# The issue a branch or worktree directory names, e.g. `issue-338-short-slug` or
# `.claude/worktrees/issue-338-x`. This is the one discovery signal that is not
# text inference: check-claim-adherence.sh already trusts it at PR time, and a
# branch names exactly one issue, so a triage sweep can never mass-seed through
# it.
issue_from_ref() {
  printf '%s' "$1" | grep -oE '(^|/)issue-?[0-9]+' | tail -1 | grep -oE '[0-9]+'
}

ledger_path() { printf '%s/%s.json' "$TICKETS_STATE_DIR" "$1"; }

# Claude Code runs every hook on a matcher in parallel, so record-issue-view
# and record-claim both read the ledger, both write it, and the slower one wins:
# a claim posted in the same Bash call as a view (or beside a branch command)
# was overwritten with "undecided". Each hook takes this lock before its first
# read and holds it until it exits. A lock not granted within
# TICKETS_LOCK_WAIT seconds is skipped: fail open.
ledger_lock() {
  mkdir -p "$TICKETS_STATE_DIR" 2>/dev/null || return 0

  if command -v flock >/dev/null 2>&1; then
    exec 9>"$(ledger_path "$1").lock" 2>/dev/null || return 0
    flock -w "$TICKETS_LOCK_WAIT" 9 2>/dev/null || true
  else
    ledger_dir_lock "$(ledger_path "$1").lockdir"
  fi
}

# The lock where flock is missing (Git for Windows, macOS): mkdir is atomic
# everywhere. The holder's pid sits inside so a lock left by a killed hook is
# taken over at once instead of costing every later hook the full wait. The
# release is an EXIT trap, so a hook that sets its own EXIT trap must call
# ledger_dir_unlock from it.
ledger_dir_lock() {
  local dir="$1" tries=$((TICKETS_LOCK_WAIT * 20)) holder

  while ! mkdir "$dir" 2>/dev/null; do
    holder="$(cat "$dir/pid" 2>/dev/null)"
    if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
      rm -rf "$dir"
      continue
    fi

    tries=$((tries - 1))
    [ "$tries" -gt 0 ] || return 0
    sleep 0.05
  done

  echo "$$" > "$dir/pid"
  LEDGER_LOCK_DIR="$dir"
  trap ledger_dir_unlock EXIT
}

ledger_dir_unlock() {
  [ "$(cat "$LEDGER_LOCK_DIR/pid" 2>/dev/null)" = "$$" ] && rm -rf "$LEDGER_LOCK_DIR"
}

# The owner/repo a `gh issue` command names with -R/--repo or an issue URL,
# lowercased; empty when it names none (it then acts on the cwd's repo).
issue_cmd_repo() {
  local repo
  repo="$(printf '%s' "$1" | grep -oE -- '(-R|--repo)[=[:space:]]+[^[:space:]]+' | head -1 |
          sed -E 's/^(-R|--repo)[=[:space:]]+//' | tr -d "\"'")"
  [ -n "$repo" ] || repo="$(printf '%s' "$1" | grep -oE 'github\.com/[^/[:space:]]+/[^/[:space:]]+/issues/' | head -1 |
                            sed -E 's#^github\.com/##; s#/issues/$##')"
  printf '%s' "${repo##*github.com/}" | tr 'A-Z' 'a-z'
}

# True when the command reads an issue in some other repo than the one the
# session is working in: research on an upstream tracker is never a work item.
# Unknown either way (no -R, no cwd, no origin) is not foreign.
issue_is_foreign() {
  local repo origin
  repo="$(issue_cmd_repo "$1")"
  [ -n "$repo" ] && [ -n "$2" ] || return 1

  origin="$(timeout 5 git -C "$2" remote get-url origin 2>/dev/null | tr 'A-Z' 'a-z')"
  [ -n "$origin" ] || return 1

  origin="${origin%.git}"
  case "$origin" in
    *[/:]"$repo") return 1 ;;
  esac
  return 0
}

# True when this session's id is on a claim comment on GitHub. The ledger only
# hears claims made through the hooks; a claim posted in a loop, through a
# variable, before a compaction, or by any route the command text hides is
# still on the issue, so the gate asks the issue before it blocks.
claimed_on_github() {
  local body
  body="$(cd "${3:-.}" 2>/dev/null && timeout 10 gh issue view "$1" --json comments -q '.comments[].body // ""' 2>/dev/null)" || return 1
  claim_session_ids "$body" | grep -qxF "$2"
}

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
