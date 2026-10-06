#!/usr/bin/env bash
# Drives the claim-ledger hooks with synthetic payloads. No network: gh is
# shadowed by a stub on PATH so the collision lookup is deterministic, and all
# state goes to a scratch dir rather than the real ~/.claude/state/tickets.
#
#   tests/hooks.test.sh      exits non-zero if anything fails
set -uo pipefail

S="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

export TICKETS_STATE_DIR="$SCRATCH/state"
SID="11111111-2222-3333-4444-555555555555"
OTHER="99999999-8888-7777-6666-555555555555"
mkdir -p "$TICKETS_STATE_DIR"

STUB="$SCRATCH/stub"
mkdir -p "$STUB"
cat > "$STUB/gh" <<EOF
#!/bin/sh
# 777 is claimed by another session, 778 likewise but CLOSED, 802 by this
# session; everything else is unclaimed.
case "\$*" in
  *777*) echo '**Claimed** - session \`$OTHER\`' ;;
  *778*state*) echo 'CLOSED' ;;
  *778*) echo '**Claimed** - session \`$OTHER\`' ;;
  *802*) echo '**Claimed** - session \`$SID\`' ;;
  *) echo '' ;;
esac
EOF
chmod +x "$STUB/gh"
PATH="$STUB:$PATH"; export PATH

pass=0; fail=0
ck() { # ck <label> <expected-exit> <actual-exit>
  if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok   $1"
  else fail=$((fail+1)); echo "  FAIL $1 (expected exit $2, got $3)"; fi
}

view()   { jq -n --arg s "$SID" --arg c "$1" --arg a "${2:-}" \
             '{session_id:$s,tool_name:"Bash",tool_input:{command:$c},tool_response:{stdout:""}} + (if $a=="" then {} else {agent_id:$a} end)'; }
mutate() { jq -n --arg s "$SID" --arg t "$1" --arg a "${2:-}" \
             '{session_id:$s,tool_name:$t,tool_input:{file_path:"/tmp/x"}} + (if $a=="" then {} else {agent_id:$a} end)'; }

echo "== 1. reading an issue records it and injects once =="
out="$(view 'gh issue view 338' | "$S/record-issue-view.sh")"; ck "first view exits 0" 0 $?
printf '%s' "$out" | grep -q 'have not decided' && { pass=$((pass+1)); echo "  ok   first view injects the reminder"; } || { fail=$((fail+1)); echo "  FAIL first view did not inject"; }
jq -e '.issues["338"].state == "undecided"' "$TICKETS_STATE_DIR/$SID.json" >/dev/null && { pass=$((pass+1)); echo "  ok   ledger records 338 undecided"; } || { fail=$((fail+1)); echo "  FAIL ledger missing 338"; }

echo "== 2. re-reading the SAME issue is silent (per-issue dedup) =="
out="$(view 'gh issue view 338' | "$S/record-issue-view.sh")"
printf '%s' "$out" | grep -q 'have not decided' && { fail=$((fail+1)); echo "  FAIL re-read injected again"; } || { pass=$((pass+1)); echo "  ok   re-read stays silent"; }

echo "== 3. burst cap: 3 injections per window, ledger still records all =="
for n in 400 401 402 403; do view "gh issue view $n" | "$S/record-issue-view.sh" > "$TICKETS_STATE_DIR/out-$n"; done
c=$(grep -l 'have not decided' "$TICKETS_STATE_DIR"/out-40* 2>/dev/null | wc -l)
[ "$c" = "2" ] && { pass=$((pass+1)); echo "  ok   only 2 more injected (3 total in window)"; } || { fail=$((fail+1)); echo "  FAIL injected $c of 400-403, expected 2"; }
jq -e '[.issues | keys[] | select(. >= "400" and . <= "403")] | length == 4' "$TICKETS_STATE_DIR/$SID.json" >/dev/null && { pass=$((pass+1)); echo "  ok   all four still recorded despite the cap"; } || { fail=$((fail+1)); echo "  FAIL suppressed injection also lost the ledger entry"; }

echo "== 4. a collision injects ALWAYS, cap or no cap =="
out="$(view 'gh issue view 777' | "$S/record-issue-view.sh")"
printf '%s' "$out" | grep -q 'COLLISION' && { pass=$((pass+1)); echo "  ok   collision reported past the burst cap"; } || { fail=$((fail+1)); echo "  FAIL collision suppressed"; }

echo "== 5. every work trigger blocks while something is undecided =="
# Cooldown neutralised here so each trigger is tested on its own; one real
# block nags every undecided issue at once, which case 6 covers.
mutate Edit | TICKETS_NAG_COOLDOWN=0 "$S/require-claim.sh" 2>/dev/null; ck "Edit blocked" 2 $?
mutate Task | TICKETS_NAG_COOLDOWN=0 "$S/require-claim.sh" 2>/dev/null; ck "Task (orchestration) blocked" 2 $?
mutate Write | TICKETS_NAG_COOLDOWN=0 "$S/require-claim.sh" 2>/dev/null; ck "Write blocked" 2 $?
jq -n --arg s "$SID" '{session_id:$s,tool_name:"Bash",tool_input:{command:"git commit -m x"}}' | TICKETS_NAG_COOLDOWN=0 "$S/require-claim.sh" 2>/dev/null; ck "git commit blocked" 2 $?
jq -n --arg s "$SID" '{session_id:$s,tool_name:"Bash",tool_input:{command:"ls -la"}}' | TICKETS_NAG_COOLDOWN=0 "$S/require-claim.sh" 2>/dev/null; ck "an unrelated Bash call is not blocked" 0 $?

echo "== 6. the nag cooldown stops a wedge =="
# A fresh undecided issue, because case 5 already stamped every earlier one.
view 'gh issue view 500' | "$S/record-issue-view.sh" >/dev/null
mutate Edit | "$S/require-claim.sh" 2>/dev/null; ck "one real block fires" 2 $?
mutate Edit | "$S/require-claim.sh" 2>/dev/null; ck "second Edit passes inside the cooldown" 0 $?
mutate Task | "$S/require-claim.sh" 2>/dev/null; ck "and so does a Task, same window" 0 $?

echo "== 7. posting the claim clears it =="
jq -n --arg s "$SID" --arg c "gh issue comment 338 --body 'Claimed - session $SID'" \
  '{session_id:$s,tool_name:"Bash",tool_input:{command:$c}}' | "$S/record-claim.sh"
jq -e '.issues["338"].state == "claimed"' "$TICKETS_STATE_DIR/$SID.json" >/dev/null && { pass=$((pass+1)); echo "  ok   claim comment marks it claimed"; } || { fail=$((fail+1)); echo "  FAIL claim not recorded"; }

echo "== 8. a claim via --body-file is seen too =="
echo "**Claimed** - session \`$SID\`" > "$TICKETS_STATE_DIR/claim.md"
jq -n --arg s "$SID" --arg c "gh issue comment 400 --body-file $TICKETS_STATE_DIR/claim.md" \
  '{session_id:$s,tool_name:"Bash",tool_input:{command:$c}}' | "$S/record-claim.sh"
jq -e '.issues["400"].state == "claimed"' "$TICKETS_STATE_DIR/$SID.json" >/dev/null && { pass=$((pass+1)); echo "  ok   --body-file claim recorded"; } || { fail=$((fail+1)); echo "  FAIL --body-file claim missed"; }

echo "== 9. skip is the read-only escape =="
CLAUDE_CODE_SESSION_ID="$SID" "$S/ticket-ledger.sh" skip 401 >/dev/null
jq -e '.issues["401"].state == "skipped"' "$TICKETS_STATE_DIR/$SID.json" >/dev/null && { pass=$((pass+1)); echo "  ok   skip recorded"; } || { fail=$((fail+1)); echo "  FAIL skip not recorded"; }

echo "== 10. once everything is decided, mutations pass =="
CLAUDE_CODE_SESSION_ID="$SID" "$S/ticket-ledger.sh" skip 402 >/dev/null
CLAUDE_CODE_SESSION_ID="$SID" "$S/ticket-ledger.sh" skip 403 >/dev/null
CLAUDE_CODE_SESSION_ID="$SID" "$S/ticket-ledger.sh" skip 777 >/dev/null
CLAUDE_CODE_SESSION_ID="$SID" "$S/ticket-ledger.sh" skip 500 >/dev/null
TICKETS_NAG_COOLDOWN=0 mutate Edit | TICKETS_NAG_COOLDOWN=0 "$S/require-claim.sh" 2>/dev/null; ck "Edit passes with nothing undecided" 0 $?

echo "== 11. subagent calls are ignored entirely =="
rm -f "$TICKETS_STATE_DIR/$SID.json"
view 'gh issue view 555' 'agent-abc' | "$S/record-issue-view.sh" >/dev/null
[ -f "$TICKETS_STATE_DIR/$SID.json" ] && { fail=$((fail+1)); echo "  FAIL subagent wrote to the parent ledger"; } || { pass=$((pass+1)); echo "  ok   subagent view writes nothing"; }
view 'gh issue view 556' | "$S/record-issue-view.sh" >/dev/null
mutate Edit 'agent-abc' | "$S/require-claim.sh" 2>/dev/null; ck "subagent Edit not blocked" 0 $?
mutate Edit | "$S/require-claim.sh" 2>/dev/null; ck "parent Edit still blocked" 2 $?

echo "== 12. no jq / no state dir: fails open =="
TICKETS_STATE_DIR=/proc/nonexistent/nope mutate Edit | TICKETS_STATE_DIR=/proc/nonexistent/nope "$S/require-claim.sh" 2>/dev/null; ck "unwritable state dir does not block" 0 $?

echo "== 13. the PR backstop reads --body-file and checks EVERY closing keyword =="
REPO="$TICKETS_STATE_DIR/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q 2>/dev/null; git -C "$REPO" checkout -q -b some-integration-branch 2>/dev/null
printf 'body\n\nCloses #801\nCloses #802\n' > "$REPO/pr.md"
err="$(jq -n --arg s "$SID" --arg c "gh pr create --title x --body-file $REPO/pr.md" --arg d "$REPO" \
  '{session_id:$s,cwd:$d,tool_name:"Bash",tool_input:{command:$c}}' | "$S/check-claim-adherence.sh" 2>&1 >/dev/null)"
ck "blocks on a --body-file PR from a non-issue branch" 2 $?
printf '%s' "$err" | grep -q '#801' && { pass=$((pass+1)); echo "  ok   names the unclaimed #801"; } || { fail=$((fail+1)); echo "  FAIL did not name #801"; }
printf '%s' "$err" | grep -q '#802' && { fail=$((fail+1)); echo "  FAIL named #802, which IS claimed"; } || { pass=$((pass+1)); echo "  ok   the claimed #802 is not reported"; }

echo "== 14. watch the old behaviour fail: claimed issue listed FIRST =="
# The exact shape that shipped four unclaimed issues: the first closing keyword
# is claimed, the rest are not.
printf 'body\n\nCloses #802\nCloses #801\n' > "$REPO/pr2.md"
run() { jq -n --arg s "$SID" --arg c "gh pr create --title x --body-file $REPO/pr2.md" --arg d "$REPO" \
  '{session_id:$s,cwd:$d,tool_name:"Bash",tool_input:{command:$c}}' | "$1" 2>&1 >/dev/null; }

run "$S/check-claim-adherence.sh" >/dev/null; ck "fixed hook blocks" 2 $?

sed 's/| sort -un/| head -1/' "$S/check-claim-adherence.sh" > "$TICKETS_STATE_DIR/old-head1.sh"
chmod +x "$TICKETS_STATE_DIR/old-head1.sh"
run "$TICKETS_STATE_DIR/old-head1.sh" >/dev/null; ck "old head -1 lets it through (the bug)" 0 $?

sed 's/^\$(body_file_text "\$CMD")/x/' "$S/check-claim-adherence.sh" > "$TICKETS_STATE_DIR/old-nobody.sh"
chmod +x "$TICKETS_STATE_DIR/old-nobody.sh"
run "$TICKETS_STATE_DIR/old-nobody.sh" >/dev/null; ck "without --body-file reading it sees nothing (the other bug)" 0 $?

echo "== 15. the prompt seeds the ledger, so the gate fires without a gh issue view =="
PSID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
prompt() { jq -n --arg s "${2:-$PSID}" --arg p "$1" --arg a "${3:-}" \
  '{session_id:$s,prompt:$p} + (if $a=="" then {} else {agent_id:$a} end)'; }
pledger() { jq -r "${1}" "$TICKETS_STATE_DIR/$PSID.json" 2>/dev/null; }

out="$(prompt 'work issue #338 please' | "$S/inject-work-issue.sh")"
printf '%s' "$out" | grep -q 'work-issue' && { pass=$((pass+1)); echo "  ok   still injects the pointer"; } || { fail=$((fail+1)); echo "  FAIL pointer not injected"; }
jq -e '.issues["338"].state == "undecided"' "$TICKETS_STATE_DIR/$PSID.json" >/dev/null && { pass=$((pass+1)); echo "  ok   prompt seeded 338 undecided"; } || { fail=$((fail+1)); echo "  FAIL prompt did not seed the ledger"; }

# The whole point: no `gh issue view` ever ran for this session.
jq -n --arg s "$PSID" '{session_id:$s,tool_name:"Edit",tool_input:{file_path:"/tmp/x"}}' | "$S/require-claim.sh" 2>/dev/null
ck "first Edit blocked off a prompt-seeded issue" 2 $?

echo "== 16. seeding is scoped to working prompts and real numbers =="
QSID="aaaaaaaa-bbbb-cccc-dddd-ffffffffffff"
prompt 'file an issue about #12' "$QSID" | "$S/inject-work-issue.sh" >/dev/null
[ -f "$TICKETS_STATE_DIR/$QSID.json" ] && { fail=$((fail+1)); echo "  FAIL a filing prompt seeded the ledger"; } || { pass=$((pass+1)); echo "  ok   filing prompt seeds nothing"; }
prompt 'what does the monitor do on a quiet tick?' "$QSID" | "$S/inject-work-issue.sh" >/dev/null
[ -f "$TICKETS_STATE_DIR/$QSID.json" ] && { fail=$((fail+1)); echo "  FAIL an unrelated prompt seeded the ledger"; } || { pass=$((pass+1)); echo "  ok   unrelated prompt seeds nothing"; }

RSID="aaaaaaaa-bbbb-cccc-dddd-111111111111"
prompt 'pick up https://github.com/o/r/issues/442#issuecomment-99 today' "$RSID" | "$S/inject-work-issue.sh" >/dev/null
jq -e '.issues | keys == ["442"]' "$TICKETS_STATE_DIR/$RSID.json" >/dev/null && { pass=$((pass+1)); echo "  ok   issue URL seeds 442, not the comment id"; } || { fail=$((fail+1)); echo "  FAIL URL seeding took the wrong number: $(jq -c '.issues|keys' "$TICKETS_STATE_DIR/$RSID.json" 2>/dev/null)"; }

echo "== 17. seeding never reopens a decision, and fails open =="
"$S/ticket-ledger.sh" skip 338 >/dev/null 2>&1 <<< '' || true
TICKETS_STATE_DIR="$TICKETS_STATE_DIR" jq --arg n 338 '.issues[$n].state="claimed"' "$TICKETS_STATE_DIR/$PSID.json" > "$TICKETS_STATE_DIR/$PSID.tmp" && mv "$TICKETS_STATE_DIR/$PSID.tmp" "$TICKETS_STATE_DIR/$PSID.json"
prompt 'resume issue #338' | "$S/inject-work-issue.sh" >/dev/null
jq -e '.issues["338"].state == "claimed"' "$TICKETS_STATE_DIR/$PSID.json" >/dev/null && { pass=$((pass+1)); echo "  ok   a claimed issue stays claimed"; } || { fail=$((fail+1)); echo "  FAIL re-seeding reopened a claimed issue"; }

ZSID="aaaaaaaa-bbbb-cccc-dddd-222222222222"
prompt 'work issue #7' "$ZSID" 'agent-abc' | "$S/inject-work-issue.sh" >/dev/null
[ -f "$TICKETS_STATE_DIR/$ZSID.json" ] && { fail=$((fail+1)); echo "  FAIL a subagent seeded the ledger"; } || { pass=$((pass+1)); echo "  ok   subagent seeds nothing"; }
out="$(prompt 'work issue #7' '' | "$S/inject-work-issue.sh")"; rc=$?
ck "no session_id: injects, seeds nothing, exits 0" 0 $rc
printf '%s' "$out" | grep -q 'work-issue' && { pass=$((pass+1)); echo "  ok   pointer survives a missing session id"; } || { fail=$((fail+1)); echo "  FAIL lost the pointer when seeding could not run"; }
TICKETS_STATE_DIR=/proc/nonexistent/nope prompt 'work issue #9' | TICKETS_STATE_DIR=/proc/nonexistent/nope "$S/inject-work-issue.sh" >/dev/null
ck "unwritable state dir does not fail the hook" 0 $?

echo "== 18. the view reader takes the command's argument, not any digits after it =="
VSID="aaaaaaaa-bbbb-cccc-dddd-333333333333"
vcmd() { jq -n --arg s "$VSID" --arg c "$1" '{session_id:$s,tool_name:"Bash",tool_input:{command:$c},tool_response:{stdout:""}}'; }
# The real shape that bit twice on 2026-09-07: prose naming the command, with
# digits somewhere further right for the old `first number anywhere` read to
# grab. Here it seeded a bogus #45 and blocked the next edit.
VPROSE='echo "the ledger was written only by gh issue view N (see record-issue-view.sh line 45)"'
vcmd "$VPROSE" | "$S/record-issue-view.sh" >/dev/null
[ -f "$TICKETS_STATE_DIR/$VSID.json" ] && { fail=$((fail+1)); echo "  FAIL prose mentioning the command seeded $(jq -c '.issues|keys' "$TICKETS_STATE_DIR/$VSID.json")"; } || { pass=$((pass+1)); echo "  ok   prose mentioning the command seeds nothing"; }
vcmd 'gh issue view https://github.com/o/r/issues/442#issuecomment-99' | "$S/record-issue-view.sh" >/dev/null
jq -e '.issues | keys == ["442"]' "$TICKETS_STATE_DIR/$VSID.json" >/dev/null && { pass=$((pass+1)); echo "  ok   URL form still reads 442"; } || { fail=$((fail+1)); echo "  FAIL URL form read $(jq -c '.issues|keys' "$TICKETS_STATE_DIR/$VSID.json" 2>/dev/null)"; }
vcmd 'gh issue view 55 --comments' | "$S/record-issue-view.sh" >/dev/null
jq -e '.issues["55"].state == "undecided"' "$TICKETS_STATE_DIR/$VSID.json" >/dev/null && { pass=$((pass+1)); echo "  ok   bare number with flags still reads 55"; } || { fail=$((fail+1)); echo "  FAIL lost the bare-number form"; }

# Watch the old reader fail on the same input. Its whole extraction was
# "everything after the phrase, then the first digits anywhere in it", which is
# why prose could feed it a number.
OLD_READ="$(printf '%s' "$VPROSE" | sed -E 's#.*gh +issue +view +##' | grep -oE '[0-9]+' | head -1)"
[ "$OLD_READ" = "45" ] && { pass=$((pass+1)); echo "  ok   the old read takes a bogus 45 from the same text (the bug)"; } || { fail=$((fail+1)); echo "  FAIL could not reproduce the old misread (got '$OLD_READ')"; }

echo "== 19. the issue number is read from ANY argument position =="
S19="19191919-1111-2222-3333-444444444444"
p19() { jq -n --arg s "$S19" --arg c "$1" '{session_id:$s,tool_name:"Bash",tool_input:{command:$c},tool_response:{stdout:""}}'; }
p19 'gh issue view --repo o/r 14' | "$S/record-issue-view.sh" >/dev/null
jq -e '.issues["14"].state == "undecided"' "$TICKETS_STATE_DIR/$S19.json" >/dev/null && { pass=$((pass+1)); echo "  ok   a flag before the number still records the issue"; } || { fail=$((fail+1)); echo "  FAIL --repo before the number recorded nothing"; }
OLD_VIEW="$(printf '%s' 'gh issue view --repo o/r 14' | grep -oE 'gh +issue +view +[^[:space:]]+' | head -1 | sed -E 's#.*view +##')"
[ "$OLD_VIEW" = "--repo" ] && { pass=$((pass+1)); echo "  ok   the old read took '--repo' as the issue (the bug)"; } || { fail=$((fail+1)); echo "  FAIL could not reproduce the old misread (got '$OLD_VIEW')"; }

p19 "gh issue comment --repo o/r2 12 --body 'claiming, session $S19'" | "$S/record-claim.sh" >/dev/null
jq -e '.issues["12"].state == "claimed"' "$TICKETS_STATE_DIR/$S19.json" >/dev/null && { pass=$((pass+1)); echo "  ok   a claim comment behind a --repo flag marks the right issue"; } || { fail=$((fail+1)); echo "  FAIL claim did not land on 12"; }
jq -e '.issues["2"] == null' "$TICKETS_STATE_DIR/$S19.json" >/dev/null && { pass=$((pass+1)); echo "  ok   the '2' inside the repo name is not treated as an issue"; } || { fail=$((fail+1)); echo "  FAIL claimed issue 2 out of the repo name (the bug)"; }

echo "== 20. git commit is caught with flags before the subcommand =="
S20="20202020-1111-2222-3333-444444444444"
jq -n --arg s "$S20" '{issues:{"338":{state:"undecided",seen:1,nagged:0}},injected:[]}' > "$TICKETS_STATE_DIR/$S20.json"
p20() { jq -n --arg s "$S20" --arg c "$1" '{session_id:$s,cwd:"/tmp",tool_name:"Bash",tool_input:{command:$c}}'; }
p20 'git -C /home/deploy/wt commit -m x' | "$S/require-claim.sh" >/dev/null 2>&1; ck "\`git -C <dir> commit\` is gated" 2 $?
printf '%s' 'git -C /home/deploy/wt commit -m x' | grep -qE 'git +commit'; [ $? = 1 ] && { pass=$((pass+1)); echo "  ok   the old literal match missed it (the bug)"; } || { fail=$((fail+1)); echo "  FAIL old match already caught it"; }
S20B="20b02020-1111-2222-3333-444444444444"
jq -n '{issues:{"338":{state:"undecided",seen:1,nagged:0}},injected:[]}' > "$TICKETS_STATE_DIR/$S20B.json"
jq -n --arg s "$S20B" '{session_id:$s,cwd:"/tmp",tool_name:"Bash",tool_input:{command:"git commit -m x"}}' | "$S/require-claim.sh" >/dev/null 2>&1; ck "plain \`git commit\` still gated" 2 $?
p20 'git log --oneline | grep commit' | "$S/require-claim.sh" >/dev/null 2>&1; ck "a command merely mentioning commit is not gated" 0 $?

echo "== 21. a branch or worktree named issue-<N> seeds the ledger =="
S21="21212121-1111-2222-3333-444444444444"
REPO="$SCRATCH/wt-issue-321"
git init -q "$REPO" && git -C "$REPO" checkout -q -b issue-321-thing
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m seed
jq -n --arg s "$S21" --arg d "$REPO" '{session_id:$s,cwd:$d,tool_name:"Edit",tool_input:{file_path:"/tmp/x"}}' | "$S/require-claim.sh" >/dev/null 2>&1; ck "an edit on an issue-321 branch is gated" 2 $?
jq -e '.issues["321"].state == "undecided"' "$TICKETS_STATE_DIR/$S21.json" >/dev/null && { pass=$((pass+1)); echo "  ok   the branch name seeded 321"; } || { fail=$((fail+1)); echo "  FAIL branch name seeded nothing"; }

S22="22222222-1111-2222-3333-444444444444"
jq -n --arg s "$S22" '{session_id:$s,tool_name:"Bash",tool_input:{command:"git worktree add .claude/worktrees/issue-654-x -b issue-654-x"},tool_response:{stdout:""}}' | "$S/record-branch-work.sh" >/dev/null
jq -e '.issues["654"].state == "undecided"' "$TICKETS_STATE_DIR/$S22.json" >/dev/null && { pass=$((pass+1)); echo "  ok   creating an issue-654 worktree seeds 654"; } || { fail=$((fail+1)); echo "  FAIL worktree creation seeded nothing"; }
jq -n --arg s "$S22" '{session_id:$s,tool_name:"Bash",tool_input:{command:"git status"},tool_response:{stdout:""}}' | "$S/record-branch-work.sh" >/dev/null
jq -e '[.issues | keys[]] | length == 1' "$TICKETS_STATE_DIR/$S22.json" >/dev/null && { pass=$((pass+1)); echo "  ok   an unrelated git command seeds nothing"; } || { fail=$((fail+1)); echo "  FAIL unrelated git command seeded an issue"; }

echo "== 23. a pipe or chain after the issue argument ends the read =="
S23="23232323-1111-2222-3333-444444444444"
p23() { jq -n --arg s "$S23" --arg c "$1" '{session_id:$s,tool_name:"Bash",tool_input:{command:$c},tool_response:{stdout:""}}'; }
p23 'gh issue view "$n" --json body | head -1' | "$S/record-issue-view.sh" >/dev/null
[ -f "$TICKETS_STATE_DIR/$S23.json" ] && { fail=$((fail+1)); echo "  FAIL a variable issue piped to head seeded $(jq -c '.issues|keys' "$TICKETS_STATE_DIR/$S23.json")"; } || { pass=$((pass+1)); echo "  ok   head -1 after a variable issue seeds no phantom #1"; }
p23 'gh issue view "$n" && sleep 5' | "$S/record-issue-view.sh" >/dev/null
[ -f "$TICKETS_STATE_DIR/$S23.json" ] && { fail=$((fail+1)); echo "  FAIL a chained sleep seeded $(jq -c '.issues|keys' "$TICKETS_STATE_DIR/$S23.json")"; } || { pass=$((pass+1)); echo "  ok   a chained command's number is not the issue"; }

echo "== 24. reading another repo's issue is research, not work =="
S24="24242424-1111-2222-3333-444444444444"
MINE="$SCRATCH/mine"; git init -q "$MINE"; git -C "$MINE" remote add origin https://github.com/Me/Mine.git
p24() { jq -n --arg s "$S24" --arg c "$1" --arg d "$MINE" '{session_id:$s,cwd:$d,tool_name:"Bash",tool_input:{command:$c},tool_response:{stdout:""}}'; }
p24 'gh issue view 8419 -R emilk/egui' | "$S/record-issue-view.sh" >/dev/null
p24 'gh issue view https://github.com/emilk/egui/issues/8420' | "$S/record-issue-view.sh" >/dev/null
[ -f "$TICKETS_STATE_DIR/$S24.json" ] && { fail=$((fail+1)); echo "  FAIL an upstream issue seeded $(jq -c '.issues|keys' "$TICKETS_STATE_DIR/$S24.json")"; } || { pass=$((pass+1)); echo "  ok   -R and URL reads of another repo seed nothing"; }
p24 'gh issue view 15 --repo me/mine' | "$S/record-issue-view.sh" >/dev/null
jq -e '.issues["15"].state == "undecided"' "$TICKETS_STATE_DIR/$S24.json" >/dev/null && { pass=$((pass+1)); echo "  ok   -R naming this repo still records"; } || { fail=$((fail+1)); echo "  FAIL -R naming this repo recorded nothing"; }

echo "== 25. a stale claim on a CLOSED issue is not a collision =="
out="$(view 'gh issue view 778' | "$S/record-issue-view.sh")"
printf '%s' "$out" | grep -q 'COLLISION' && { fail=$((fail+1)); echo "  FAIL closed issue reported as a collision"; } || { pass=$((pass+1)); echo "  ok   closed issue raises no collision"; }

echo "== 26. a claim the ledger missed is found on GitHub before blocking =="
# The stub carries this session's claim on 802 only.
jq -n '{issues:{"802":{state:"undecided",seen:1,nagged:0}},injected:[]}' > "$TICKETS_STATE_DIR/$SID.json"
mutate Edit | "$S/require-claim.sh" 2>/dev/null; ck "an issue already claimed on GitHub does not block" 0 $?
jq -e '.issues["802"].state == "claimed"' "$TICKETS_STATE_DIR/$SID.json" >/dev/null && { pass=$((pass+1)); echo "  ok   the GitHub claim is written back to the ledger"; } || { fail=$((fail+1)); echo "  FAIL ledger still says $(jq -r '.issues["802"].state' "$TICKETS_STATE_DIR/$SID.json")"; }
jq -n '{issues:{"338":{state:"undecided",seen:1,nagged:0}},injected:[]}' > "$TICKETS_STATE_DIR/$SID.json"
mutate Edit | "$S/require-claim.sh" 2>/dev/null; ck "an issue with no claim on GitHub still blocks" 2 $?

echo "== 27. a claim and a view in one call: the claim survives the parallel hooks =="
lost=0
for i in $(seq 1 15); do
  R="27272727-1111-2222-3333-4444444444$(printf '%02d' "$i")"
  c="gh issue view 900 && gh issue comment 900 --body 'Claimed - session $R'"
  in="$(jq -n --arg s "$R" --arg c "$c" '{session_id:$s,tool_name:"Bash",tool_input:{command:$c},tool_response:{stdout:""}}')"
  printf '%s' "$in" | "$S/record-issue-view.sh" >/dev/null &
  printf '%s' "$in" | "$S/record-claim.sh" >/dev/null &
  wait
  jq -e '.issues["900"].state == "claimed"' "$TICKETS_STATE_DIR/$R.json" >/dev/null || lost=$((lost+1))
done
[ "$lost" = "0" ] && { pass=$((pass+1)); echo "  ok   15 of 15 parallel runs kept the claim"; } || { fail=$((fail+1)); echo "  FAIL the view hook overwrote the claim in $lost of 15 runs"; }

echo "== 28. a complete body passes where grep aborts on -i with -F =="
# Git for Windows ships grep 3.0, which aborts (exit 134) on any -iF; the
# validator read that as "missing" and refused every complete issue body there.
BROKEN="$SCRATCH/broken-grep"
mkdir -p "$BROKEN"
cat > "$BROKEN/grep" <<STUB
#!/bin/sh
for arg in "\$@"; do
  case "\$arg" in --) break ;; -*i*F*|-*F*i*) exit 134 ;; esac
done
exec $(command -v grep) "\$@"
STUB
chmod +x "$BROKEN/grep"
BODY="$SCRATCH/complete-body.md"
cat > "$BODY" <<'BODY'
> **AI-written.** No human has read this.
consequence: the operator waits
DONE WHEN: the repo has X
## problem
## Human intent
## Context
## Acceptance criteria
## Verification
## Edge cases
## Out of scope
## Blocked by
BODY
PATH="$BROKEN:$PATH" "$S/validate-issue.sh" --file "$BODY" >/dev/null; ck "a complete body in any case passes under a grep that aborts on -iF" 0 $?
sed -i '/## Edge cases/d' "$BODY"
PATH="$BROKEN:$PATH" "$S/validate-issue.sh" --file "$BODY" >/dev/null; ck "a missing section is still caught" 1 $?

echo "== 29. values from a CRLF jq carry no trailing carriage return =="
# jq built for Windows writes CRLF, so "$(jq -r ...)" kept a \r: the session id
# named the wrong state file and the cwd matched no directory. The fake jq below
# behaves like it (CRLF unless -b) and runs the real one without -b, which jq 1.6
# does not know.
CRLF="$SCRATCH/crlf-jq"
mkdir -p "$CRLF"
cat > "$CRLF/jq" <<STUB
#!/usr/bin/env bash
binary=0; args=()
for arg in "\$@"; do
  if [ "\$arg" = "-b" ]; then binary=1; else args+=("\$arg"); fi
done
if [ "\$binary" = 1 ]; then exec $(command -v jq) "\${args[@]}"; fi
$(command -v jq) "\${args[@]}" | sed 's/\$/\r/'
exit "\${PIPESTATUS[0]}"
STUB
chmod +x "$CRLF/jq"
R29="29292929-1111-2222-3333-444444444444"
jq -n --arg s "$R29" --arg c "gh issue comment 929 --body 'claiming, session $R29'" \
  '{session_id:$s,tool_name:"Bash",tool_input:{command:$c}}' \
  | OSTYPE=msys PATH="$CRLF:$PATH" "$S/record-claim.sh" >/dev/null
[ -f "$TICKETS_STATE_DIR/$R29.json" ]; ck "a claim lands in the session's own state file" 0 $?
mkdir -p "$SCRATCH/cwd29"
cp "$BODY" "$SCRATCH/cwd29/body.md"
echo "## Edge cases" >> "$SCRATCH/cwd29/body.md"
jq -n --arg d "$SCRATCH/cwd29" '{cwd:$d,tool_name:"Bash",tool_input:{command:"gh issue create --label bug --body-file body.md"}}' \
  | OSTYPE=msys PATH="$CRLF:$PATH" "$S/validate-issue.sh" 2>/dev/null; ck "a relative --body-file resolves against the hook's cwd" 0 $?

echo "== 30. without flock the parallel hooks still serialize (Git Bash, macOS) =="
# Git for Windows ships no flock, so the ledger lock was a no-op there and case
# 27 lost the claim in about a third of runs. NOFLOCK is a PATH with every
# program in /usr/bin and /bin except flock; where flock is already missing,
# the normal PATH is that already.
NOFLOCK_PATH="$PATH"
if command -v flock >/dev/null 2>&1; then
  NOFLOCK="$SCRATCH/noflock"
  mkdir -p "$NOFLOCK"
  for f in /usr/bin/* /bin/*; do
    [ "${f##*/}" = flock ] || [ -e "$NOFLOCK/${f##*/}" ] || ln -s "$f" "$NOFLOCK/${f##*/}"
  done
  NOFLOCK_PATH="$STUB:$NOFLOCK"
fi
PATH="$NOFLOCK_PATH" bash -c 'command -v flock' >/dev/null; ck "the test PATH really has no flock" 1 $?
lost=0
for i in $(seq 1 15); do
  R="30303030-1111-2222-3333-4444444444$(printf '%02d' "$i")"
  c="gh issue view 900 && gh issue comment 900 --body 'Claimed - session $R'"
  in="$(jq -n --arg s "$R" --arg c "$c" '{session_id:$s,tool_name:"Bash",tool_input:{command:$c},tool_response:{stdout:""}}')"
  printf '%s' "$in" | PATH="$NOFLOCK_PATH" "$S/record-issue-view.sh" >/dev/null &
  printf '%s' "$in" | PATH="$NOFLOCK_PATH" "$S/record-claim.sh" >/dev/null &
  wait
  jq -e '.issues["900"].state == "claimed"' "$TICKETS_STATE_DIR/$R.json" >/dev/null || lost=$((lost+1))
done
[ "$lost" = "0" ] && { pass=$((pass+1)); echo "  ok   15 of 15 parallel runs kept the claim without flock"; } || { fail=$((fail+1)); echo "  FAIL without flock the view hook overwrote the claim in $lost of 15 runs"; }
ls -d "$TICKETS_STATE_DIR"/*.lockdir >/dev/null 2>&1; ck "every hook released its lock on exit" 2 $?

R30="30303030-dead-2222-3333-444444444444"
DEAD="$(sh -c 'echo $$')"
mkdir -p "$TICKETS_STATE_DIR/$R30.json.lockdir" && echo "$DEAD" > "$TICKETS_STATE_DIR/$R30.json.lockdir/pid"
START=$(date +%s)
jq -n --arg s "$R30" --arg c "gh issue comment 931 --body 'claiming, session $R30'" '{session_id:$s,tool_name:"Bash",tool_input:{command:$c}}' \
  | TICKETS_LOCK_WAIT=30 PATH="$NOFLOCK_PATH" "$S/record-claim.sh" >/dev/null
# Far under the 30 s wait; one hook alone takes about 2 s on Windows.
[ $(( $(date +%s) - START )) -lt 15 ] && jq -e '.issues["931"].state == "claimed"' "$TICKETS_STATE_DIR/$R30.json" >/dev/null
ck "a lock left by a dead hook is taken over at once" 0 $?

R30L="30303030-live-2222-3333-444444444444"
mkdir -p "$TICKETS_STATE_DIR/$R30L.json.lockdir" && echo "$$" > "$TICKETS_STATE_DIR/$R30L.json.lockdir/pid"
jq -n --arg s "$R30L" --arg c "gh issue comment 932 --body 'claiming, session $R30L'" '{session_id:$s,tool_name:"Bash",tool_input:{command:$c}}' \
  | TICKETS_LOCK_WAIT=1 PATH="$NOFLOCK_PATH" timeout 10 "$S/record-claim.sh" >/dev/null
ck "a lock held past the wait fails open instead of blocking" 0 $?
[ -d "$TICKETS_STATE_DIR/$R30L.json.lockdir" ]; ck "a hook that never got the lock leaves the holder's lock alone" 0 $?

echo
echo "pass=$pass fail=$fail"
[ "$fail" = "0" ]
