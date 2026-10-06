#!/usr/bin/env bash
# Validates GitHub issue bodies against the tickets plugin's required anatomy.
#
# Two modes:
#   As a PreToolUse hook (no args): reads hook JSON on stdin, inspects Bash
#     commands that create issues, exits 2 with reasons on stderr to block.
#   Direct (--file <path>): validates a drafted body file before filing,
#     exits 1 with reasons on stdout.
#
# This is a lazy-path gate, not an adversarial one: it checks that the required
# elements are present in the command string plus any literal --body-file it
# can read. Escape hatch, operator use only: CLAUDE_TICKET_SHAPE=off (in the
# environment or prefixed on the command) skips validation, e.g. for filing
# upstream on a third-party repo.
set -u

# jq built for Windows writes CRLF, which leaves a \r on every "$(jq -r ...)"
# value; -b stops it. Defined only when this jq takes -b (1.7+), so a missing or
# older jq behaves exactly as before.
case "${OSTYPE:-}" in
  msys* | cygwin*) command jq -b -n 1 >/dev/null 2>&1 && jq() { command jq -b "$@"; } ;;
esac

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

# label|pattern1|pattern2...  — a check passes when ANY pattern is present
# (case-insensitive, fixed string).
REQUIRED_CHECKS=(
  "provenance mark (the hub MCP tool \`intent_mark\` prints it; body must start with the AI-written claim + session trailer)|AI-written"
  "Consequence: line (or Icebox: line for iceboxed issues)|Consequence:|Icebox:"
  "Done when: line naming a state of the repo|Done when:"
  "## Problem or ## What to build section|## Problem|## What to build"
  "## Human intent section (verbatim quotes, or explicitly 'None — agent-inferred')|## Human intent"
  "## Context section (paths, symbols, entry points, related items)|## Context"
  "## Acceptance criteria section (falsifiable checkboxes)|## Acceptance criteria"
  "## Verification section (exact commands/steps)|## Verification"
  "## Edge cases section|## Edge cases"
  "## Out of scope section|## Out of scope"
  "## Blocked by section (or 'None - can start immediately')|## Blocked by"
)

# contains_ci <text> <fixed string>: a case-insensitive substring test in bash
# itself, because Git for Windows' grep 3.0 aborts (exit 134) on any `grep -iF`.
contains_ci() {
  [[ "${1,,}" == *"${2,,}"* ]]
}

collect_missing() {
  local body="$1" check label patterns found pattern pats
  MISSING=()

  for check in "${REQUIRED_CHECKS[@]}"; do
    label="${check%%|*}"
    patterns="${check#*|}"
    found=0

    IFS='|' read -ra pats <<<"$patterns"
    for pattern in "${pats[@]}"; do
      if contains_ci "$body" "$pattern"; then
        found=1
        break
      fi
    done

    if [ "$found" -eq 0 ]; then MISSING+=("$label"); fi
  done
}

print_missing() {
  local dest="$1" line

  {
    echo "Issue body is missing required elements:"
    for line in "${MISSING[@]}"; do echo "  - $line"; done
    if [ "${INDIRECT_BODY:-0}" -eq 1 ]; then
      echo ""
      echo "Note: the body was passed indirectly (stdin, a shell variable, or an"
      echo "unreadable path), which this hook cannot inspect. Write the body to a"
      echo "real file and pass a literal --body-file /abs/path."
    fi
    echo ""
    echo "Use the /tickets:file-issue skill. Template and per-section requirements:"
    echo "  $PLUGIN_ROOT/skills/file-issue/template.md"
  } >&"$dest"
}

# --- Direct mode -------------------------------------------------------------
if [ "${1:-}" = "--file" ]; then
  [ -r "${2:-}" ] || { echo "validate-issue.sh: cannot read '${2:-}'" >&2; exit 1; }

  collect_missing "$(cat "$2")"

  if [ "${#MISSING[@]}" -gt 0 ]; then
    print_missing 1
    exit 1
  fi

  echo "OK: all required elements present."
  exit 0
fi

# --- Hook mode ---------------------------------------------------------------
[ "${CLAUDE_TICKET_SHAPE:-}" = "off" ] && exit 0

INPUT=$(cat)

# jq failing must not fail the gate open silently, but blanket exit 2 would
# block EVERY Bash call on the box. Fail closed only for likely issue creation.
if ! CMD=$(jq -r '.tool_input.command // empty' <<<"$INPUT" 2>/dev/null); then
  if grep -q 'gh issue create' <<<"$INPUT"; then
    echo "validate-issue.sh: jq unavailable or hook input unparseable; cannot validate the issue body, blocking. Fix jq, then use /tickets:file-issue." >&2
    exit 2
  fi
  exit 0
fi
[ -n "$CMD" ] || exit 0

# Only issue *creation* is gated; comments, edits, lists, api reads pass.
IS_CREATE=0
if grep -qE '(^|[^[:alnum:]])gh([[:space:]]+--?[^[:space:]]+)*[[:space:]]+issue[[:space:]]+create' <<<"$CMD"; then
  IS_CREATE=1
elif grep -qE 'gh[[:space:]]+api' <<<"$CMD" \
  && grep -qE 'repos/[^[:space:]"'\'']+/issues(["'\''[:space:]]|$)' <<<"$CMD" \
  && ! grep -qiE '(-X|--method)[[:space:]="'\'']*(GET|PATCH|PUT|DELETE)' <<<"$CMD"; then
  # gh api defaults to GET; only a POST marker (explicit method or field/input
  # flags) makes this a creation.
  if grep -qiE '(-X|--method)[[:space:]="'\'']*POST' <<<"$CMD" \
    || grep -qE '(^|[[:space:]])(-f|-F|--field|--raw-field|--input)([= ]|$)' <<<"$CMD"; then
    IS_CREATE=1
  fi
fi
[ "$IS_CREATE" -eq 1 ] || exit 0

if grep -q 'CLAUDE_TICKET_SHAPE=off' <<<"$CMD"; then exit 0; fi

if grep -qE '(^|[[:space:]])(--web|-w)([[:space:]]|$)' <<<"$CMD"; then
  echo "gh issue create --web bypasses body validation. Draft the body per the /tickets:file-issue skill and file with --body-file instead." >&2
  exit 2
fi

# The body may be inline (--body/-b, already inside the command string) or in
# files (--body-file/-F, --input). Validate the command string plus every
# readable body file. Stdin ("-"), shell expansions, and unreadable paths are
# flagged so the block message explains itself.
BODY_TEXT="$CMD"
INDIRECT_BODY=0
CWD=$(jq -r '.cwd // empty' <<<"$INPUT" 2>/dev/null) || CWD=""

while IFS= read -r token; do
  file=$(sed -E 's/^(--body-file|--input|-F)[= ]//' <<<"$token" | tr -d '"'"'")
  case "$file" in
    -|*'$'*|*'`'*) INDIRECT_BODY=1; continue ;;
    /*|[A-Za-z]:[/\\]*) : ;;
    *) file="${CWD:-.}/$file" ;;
  esac
  if [ -r "$file" ]; then
    BODY_TEXT="$BODY_TEXT
$(cat "$file")"
  else
    INDIRECT_BODY=1
  fi
done < <(grep -oE '(--body-file|--input|-F)([= ])[^[:space:]]+' <<<"$CMD")

collect_missing "$BODY_TEXT"

# Label convention: every issue carries at least one label (see labels.md).
if ! grep -qE '(--label|-l)([= ]|$)' <<<"$CMD" && ! contains_ci "$CMD" '"labels"' && ! grep -qE '\-[fF][[:space:]]+["'\'']?labels' <<<"$CMD"; then
  MISSING+=("at least one --label (see labels.md: one type label, plus icebox/needs-human/blocked when they apply)")
fi

if [ "${#MISSING[@]}" -gt 0 ]; then
  print_missing 2
  exit 2
fi

exit 0
