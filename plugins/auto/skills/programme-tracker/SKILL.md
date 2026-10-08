---
name: programme-tracker
description: >
  Keep the issue tracker up to date for an auto programme. Use when this
  session drives a programme and the sweep finds items whose tracker view is
  behind: move issue state forward, post one short progress comment per
  change, link PRs and plan docs, mark handed items, and file issues for
  blockers. Never writes proof (a done or canceled state, or a root-cause
  comment).
---

# Keep the tracker up to date

The issue tracker is the PM's working document. Other people read it to know
where each piece of work stands, so the PM keeps it current. `P` below means
`bash "${CLAUDE_PLUGIN_ROOT}/lib/programme.sh"`.

Today the write path is the Linear MCP tools (`mcp__linear__*`). Run them in
your own session, never from a dispatched Agent.

## When to write

The sweep calls this skill at its end. Write only to issues inside the remit's
tracker scope (its teams, and its projects or initiatives when those are set);
a hook denies a write to an issue of a team outside it. For each issue item,
pick the label that says where the item is now:

| What happened | Label | Tracker write |
| --- | --- | --- |
| A worker started | `in_progress` | state In Progress, comment "Work started." |
| A PR opened | `pr_open` | state In Review, link the PR, comment "PR opened: <url>" |
| A PR merged | `merged` | comment "PR merged: <url>. Waiting on <what proves it done>." |
| Blocked | `blocked` | comment "Blocked on <who or what>: <one line>." and link the blocker issue |
| Handed to Shawn | `handed` | the needs-you mark, comment "Waiting on Shawn: <question>" |
| Unblocked | `in_progress` | comment "Unblocked: <what changed>." |

A plan doc that names the issue gets linked once, when the PM first sees it.

## The no-spam rule

Write only when the label changed since the last write:

1. `P tracker-synced --item <item> --state <label> --check`. If `due` is false,
   skip the item: the tracker already says this.
2. Make the tracker writes for that label.
3. `P tracker-synced --item <item> --state <label> --note "<the comment, short>"`.

One comment per change. Never repeat a comment, and never post a comment for a
sweep where nothing changed. If a write fails, do not run step 3; the item stays
due and the next sweep tries again.

## How to write

- **State:** `mcp__linear__save_issue` with `id` (the issue key) and `state`
  by name (for example "In Progress", "In Review"). Pass the state by name, not
  by id: the guard cannot check an id it has not seen.
- **Comment:** `mcp__linear__save_comment` with `issueId` and `body`.
- **Links:** `mcp__linear__save_issue` with `id` and
  `links: [{url, title}]` for the PR and the plan doc. Do not use
  `create_attachment`; it uploads files.
- **Needs you:** `P hand-item` already sets the board's needs-you mark. When the
  board is not there, add the label your team uses for it with `addLabels`.
- **Blocker issue:** a blocker shared by items, found and debugged in the sweep,
  gets its own issue: `mcp__linear__save_issue` with `team`, `title`,
  `description` (what fails, how you saw it, who owns it) and `relatedTo` the
  blocked item's issue key. Then record the wait with `P set-waiting <item>
  --blocker`.

Voice: plain words for a busy reader. One or two short sentences. Say what
changed and what happens next. No internal ids (no item ids, prompt ids,
watcher ids, rule ids), no process narration.

## Never write proof

The PM never writes:

- a state whose type is completed or canceled (Done, Canceled, Duplicate,
  Closed, or a team's own name for one), and never marks an issue a duplicate;
- a comment that says "root cause" or "root-cause".

Why: the recorded check reads exactly these two things as proof that the work
is done. Proof comes from a worker or Shawn. If the PM wrote them, the check
would confirm the PM's own claim.

A hook enforces this for the driving session: such a call is denied with a
one-line reason and journaled. A denial means the item needs its owner to
close it. Tell the worker or hand it to Shawn; do not reword the call to get
past the guard.

## When the tracker cannot be read

When the board and the API key both fail, the sweep reads the remit's issues
through `mcp__linear__get_issue` (or `list_issues`) and records them:

```sh
P record-issues <<'JSON'
[{"key": "AI-753", "title": "...", "state": "In Review", "state_type": "started",
  "state_id": "<the state's id>", "url": "https://linear.app/..."}]
JSON
```

That sets the tracker available with provider `linear-mcp`. The watcher stays
on its own reads and keeps reporting the tracker as unavailable; that is
expected while the provider is `linear-mcp`. The recorded check never uses this
data; it reads the tracker itself.
