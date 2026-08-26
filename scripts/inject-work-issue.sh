#!/usr/bin/env bash
# UserPromptSubmit hook: when the prompt reads like "work issue #N", inject a
# deterministic pointer at /tickets:work-issue. The injected skills list is not
# fully reliable; this fires on the prompt itself, so recognition cannot miss.
# Injection only — it never blocks anything and stays silent on every other prompt.
set -uo pipefail

PROMPT="$(jq -r '.prompt // empty' 2>/dev/null)" || exit 0
[ -n "$PROMPT" ] || exit 0

# Working verbs near "issue/ticket" or a bare #N. Filing verbs (file, create,
# make, open) deliberately absent — those belong to /tickets:file-issue.
if printf '%s' "$PROMPT" | grep -qiE '\b(work|works|working|pick up|take|start|resume|continue|implement|finish)\b[^.]{0,40}\b(issue|ticket)s?\b' ||
   printf '%s' "$PROMPT" | grep -qiE '\b(work|pick up|take|start|resume|continue|implement|finish)\b[^.]{0,20}#[0-9]+'; then
  echo "This prompt looks like tracked-issue work. Invoke the /tickets:work-issue skill before touching anything — it carries the claim protocol (claim comment with your session id, last-writer-loses re-read). Never start a tracked item without claiming it there first."
fi

exit 0
