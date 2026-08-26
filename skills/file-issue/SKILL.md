---
description: File a well-shaped, self-contained GitHub issue. Use whenever creating an issue or ticket, deferring discovered work to the tracker, converting a finding/plan item into tracked work, or when the user says "file an issue", "make a ticket", "defer this". Produces issues an AI can work from "Work issue #123" alone.
argument-hint: "[repo] [what the ticket is about]"
allowed-tools: Bash(gh repo view:*), Bash(gh label list:*), Bash(gh label create:*), Bash(gh issue list:*), Bash(gh issue view:*), Bash(gh issue create:*), Bash(gh pr list:*), Bash(gh search:*), Bash(date:*), Bash(intent:*), Bash(/home/deploy/.claude/skills/tickets/scripts/validate-issue.sh:*)
---

# File an issue

Create one GitHub issue that is **self-contained**: everything needed to work it is in the body, so the next agent starts from "Work issue #123" with no re-discovery. A PreToolUse hook blocks `gh issue create` bodies missing the required anatomy, so follow this workflow rather than fighting the hook.

Live context (session cwd — if the target repo differs, or a line below shows an error instead of data, re-run the command yourself with `-R <owner/repo>`):

- Today: !`date +%F`
- Repo: !`gh repo view --json nameWithOwner,defaultBranchRef -q '.nameWithOwner + " (default: " + .defaultBranchRef.name + ")"' 2>&1 | head -2`
- Existing labels: !`gh label list --limit 200 --json name,description -q '.[] | .name + " — " + (.description // "")' 2>&1 | head -60`

## 1. Scope: one issue, one change

An issue names **one diff** someone could merge. If the request contains several independent changes, split into several issues (state the split to the user). If the verb is investigate/measure/evaluate, it is either not a ticket (answer it, or note it in a docs file) or a **spike**: timeboxed, with a falsifiable question and a `Done when:` naming an artifact (ADR, measurement doc), never "we know X".

## 2. Triage: scheduled or icebox

Apply the triage gate from `~/.claude/rules/no-untracked-deferral.md`:

- **Scheduled** needs a falsifiable `Consequence:` (who or what suffers today) and `Done when:` (a state of the repo).
- **Icebox** (user wouldn't notice, code isn't garbage): still gets a full body, plus the `icebox` label. Never icebox defects, security, races, silent failures, red/flaky CI.

## 3. Gather context — targeted, not a sweep

Collect exactly what the worker needs, and only from where the change lives:

- Read the specific files/symbols the change touches; note paths, key symbols, and entry points. Do NOT explore unrelated subsystems — if you can't name why a file matters to this change, don't read it.
- Search for prior art: `gh issue list --search`, `gh pr list --search` (dedupe against open issues — never file a duplicate), the running log (`~/ops/agent-reports/bin/agent-reports find <terms>`), and any ADRs/docs in the area.
- Note constraints the worker can't derive from the code: gotchas, prior decisions, rejected approaches.

## 4. Capture human intent

Search the intent ledger (`intent find <terms>`) for anything the operator said that bears on this work. Quote it **verbatim** with its `op:` ref and date in the `## Human intent` section — never paraphrase. If nothing exists, write `None — agent-inferred.` Then generate the provenance mark: `intent mark 1` (or tier 2–4 with `--source op:...` when you can cite direction) and paste its two lines at the very top of the body.

## 5. Draft the body

Follow [template.md](template.md) exactly — it defines every section and what good looks like. See [examples.md](examples.md) for a complete worked example. Write the body to a file (e.g. `/tmp/issue-body.md` or the job tmp dir).

Watch the auto-close traps: `Closes #N` only as plain prose when this issue should close N on merge into the default branch; reference all other issues neutrally ("see #28"), and never backtick-quote a closing keyword.

## 6. Labels

Follow [labels.md](labels.md): exactly one `type:` label (`type:spike` for spikes), plus `icebox`, `needs-human`, or `blocked` when they apply. Reconcile against the existing labels injected above; create any missing conventional label with `gh label create <name> --description "..." --color <hex>` before filing.

## 7. Validate, then file

```bash
/home/deploy/.claude/skills/tickets/scripts/validate-issue.sh --file /path/to/issue-body.md
```

Fix anything it reports, then file:

```bash
gh issue create -R <owner/repo> --title "<imperative, specific title>" --body-file /path/to/issue-body.md --label "type:bug"
```

## 8. After filing

- Confirm with `gh issue view <n>` that it rendered correctly (mark first, sections intact).
- Link it where it came from: the PR/issue/plan that spawned it gets a one-line pointer.
- Do NOT claim it — claiming happens when someone starts the work (`issue-claim-protocol.md`).
