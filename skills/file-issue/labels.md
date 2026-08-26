# Label conventions

Labels are the mechanical layer of triage: they must be queryable, so the vocabulary is fixed. Reconcile against the repo's existing labels first (`gh label list`); reuse an existing equivalent if one is clearly established in that repo (e.g. a bare `bug`), otherwise create the conventional one. Never invent new label names outside this file.

## Type — exactly one per issue

| Label | Color | Use |
| --- | --- | --- |
| `type:bug` | `d73a4a` | Behavior is wrong: user-visible breakage, data loss, races, silent failures |
| `type:feature` | `0e8a16` | New behavior a user or agent would notice |
| `type:chore` | `c5def5` | Internal change with no behavior delta: tooling, CI, refactor, docs |
| `type:spike` | `d4c5f9` | Timeboxed investigation with an artifact as its Done-when |

## Status — add when they apply

| Label | Color | Use |
| --- | --- | --- |
| `icebox` | `ededed` | Captured, deliberately unscheduled. Body carries the `Icebox:` line instead of `Consequence:` |
| `needs-human` | `fbca04` | Blocked on an operator decision, access, or review (HITL). Say what's needed in the body |
| `blocked` | `b60205` | Blocked on another issue; `## Blocked by` names it |

## Creating a missing label

```bash
gh label create "type:bug" --description "Behavior is wrong" --color d73a4a
```

`gh label create` fails if the label exists — that's fine, ignore the error and use it.

## Rules

- Exactly one `type:` label per issue. The hook mechanically rejects only *unlabeled* issues; picking the right type label is on you.
- `icebox` and `type:bug` never combine — bugs are never iceboxed (`no-untracked-deferral.md`).
- Projects with their own richer vocabulary (tracks, priorities) keep it; this set is the floor, not the ceiling.
