---
description: Report where this git worktree stands — which Linear issue it is bound to, what state that binding is in, whether anything is waiting for a decision, and whether writes are enabled. With an issue identifier, start work on it instead.
argument-hint: "[WEB-1234] | [status] | nothing"
allowed-tools: Bash, Skill, AskUserQuestion
---

Where this worktree stands, and what to do next.

## With no argument

Report the state of the worktree you are in. Read it, do not guess it:

```bash
R="${CLAUDE_PLUGIN_ROOT}"
source "$R/lib/contain.sh"; source "$R/lib/secrets.sh"; source "$R/lib/binding.sh"
source "$R/lib/linear.sh"; source "$R/lib/reconcile.sh"; source "$R/lib/sanitize.sh"
source "$R/lib/description.sh"; source "$R/lib/herdr-read.sh"
source "$R/lib/herdr-write.sh"; source "$R/lib/start.sh"; source "$R/lib/create.sh"

herdr_linear::scope_signals "$PWD" "$(herdr_linear::workspace_id)"
herdr_linear::binding_state "$PWD"
herdr_linear::binding_identifier "$PWD" 2>/dev/null
```

`scope_signals` prints two lines and never refuses. `path=` says whether this
directory sits under a known projects root; `project=` names the tracker project
it maps to, or `negative` when none does, or `unknown` when the tracker could not
be reached. **Report both and carry on.** `outside` and `negative` together mean
nothing here maps to tracked work, which is worth saying and is not a reason to
stop. `unknown` is not `negative` — an unread signal is not an absent one.

Then say, in one or two lines, what state it is in and the single most useful
next step:

| State | Say |
|---|---|
| `unbound` | not bound. `/work:bind` to bind it, or `/work:start` for new work elsewhere |
| `proposed` | a candidate was offered and not confirmed. `/work:bind` to finish |
| `bound` | name the issue, its state, and whether anything is waiting (below) |
| `misplaced` | the workspace's project is not the issue's. `/work:bind` to move either side |
| `stale` | the issue is closed and this worktree is not. Nothing was changed |

When bound, also report:

```bash
# anything recorded for this session to see
herdr_linear::binding_read "$PWD" | python3 -c 'import sys,json;d=json.load(sys.stdin);j=d.get("pending_judgment");print(j["text"] if j else "nothing waiting")' | herdr_linear::sanitize_stream
# whether anyone has answered the write question for this directory
herdr_linear::has_consent "$PWD" && echo "an answer is recorded here" || echo "no answer recorded — the first write will ask"
herdr_linear::binding_pending_consent "$PWD" 2>/dev/null | herdr_linear::sanitize_stream
# The shadow log holds issue titles and API error bodies, both written by
# whoever files the tickets. It never reaches the terminal unfiltered.
tail -5 "${HERDR_LINEAR_SHADOW_LOG:-$HOME/.claude/work/shadow.log}" 2>/dev/null | herdr_linear::sanitize_stream
```

## With an issue identifier

`/work WEB-3318` means *start on this*. Hand off to `/work:start`, which creates
the worktree and binds it. That path writes nothing to Linear.

## With `status`

The same report, plus the credential and the recorded answer:

```bash
bash "$R/bin/migrate-credential.sh" report
herdr_linear::binding_read "$PWD" 2>/dev/null \
  | python3 -c 'import sys,json;c=json.load(sys.stdin).get("consent");print(json.dumps(c) if c else "no answer recorded for this directory")'
```

**There is no allowlist file.** Writes are opened by answering the question the
first write asks, and the answer is scoped to the team, project and branch it
named. A different team, a different project, or a different branch asks again.

## The rest

| Command | For |
|---|---|
| `/work:start` | begin work — from a ticket, or from nothing |
| `/work:bind` | bind a worktree that already exists |
| `/work:describe` | write the issue description |
| `/work:doc` | publish a document to the issue |
| `/work:layout` | build a herdr tab and its columns from an issue |

**Never invent state.** If a command fails or Linear is unreachable, say so.
A confident wrong answer about what a worktree is bound to is worse than "I
could not read it".
