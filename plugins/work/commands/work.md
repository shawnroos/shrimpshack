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
source "$R/lib/linear.sh"; source "$R/lib/reconcile.sh"

herdr_linear::contains "$PWD" || echo "outside the Slate root — this plugin does nothing here"
herdr_linear::binding_state "$PWD"
herdr_linear::binding_identifier "$PWD" 2>/dev/null
```

Then say, in one or two lines, what state it is in and the single most useful
next step:

| State | Say |
|---|---|
| outside the Slate root | this plugin does nothing here. Stop. |
| `unbound` | not bound. `/work:bind` to bind it, or `/work:start` for new work elsewhere |
| `proposed` | a candidate was offered and not confirmed. `/work:bind` to finish |
| `bound` | name the issue, its state, and whether anything is waiting (below) |
| `misplaced` | the workspace's project is not the issue's. `/work:bind` to move either side |
| `stale` | the issue is closed and this worktree is not. Nothing was changed |

When bound, also report:

```bash
# anything recorded for this session to see
herdr_linear::binding_read "$PWD" | python3 -c 'import sys,json;d=json.load(sys.stdin);j=d.get("pending_judgment");print(j["text"] if j else "nothing waiting")'
# whether writes are on for this worktree, and what shadow mode has been saying
herdr_linear::writes_enabled "$PWD" && echo "writes ENABLED here" || echo "shadow mode (nothing is sent)"
tail -5 "${HERDR_LINEAR_SHADOW_LOG:-$HOME/.claude/work/shadow.log}" 2>/dev/null
```

## With an issue identifier

`/work WEB-3318` means *start on this*. Hand off to `/work:start`, which creates
the worktree and binds it. That path writes nothing to Linear.

## With `status`

The same report, plus the credential and the write allowlist:

```bash
bash "$R/bin/migrate-credential.sh" report
cat "${HERDR_LINEAR_WRITE_ALLOWLIST:-$HOME/.claude/work/write-enabled}" 2>/dev/null || echo "no worktree has writes enabled"
```

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
