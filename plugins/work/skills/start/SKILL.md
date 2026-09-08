---
name: start
description: Start work on a Linear issue that has no worktree yet, or start something new that has neither a worktree nor a ticket. Creates the worktree under Slate's worktrees directory, names the branch so the issue is findable from it forever after, and binds the two. Use at the beginning of a piece of work.
disable-model-invocation: true
---

# Start a piece of work

Binding assumes a worktree already exists, which is the uncommon case. Work
usually starts one of two other ways:

| | Ticket exists | No ticket |
|---|---|---|
| **Worktree exists** | `/work:bind` | `/work:bind`, then its create step |
| **No worktree** | **here — the common one** | **here** |

## From a ticket

**This writes nothing to Linear.** It reads the issue, creates a local worktree
and records a local binding — so it works before the credential has been rotated
and before any worktree is in the write allowlist, and it cannot damage a board.

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/contain.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/secrets.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/binding.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/linear.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/reconcile.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/description.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/start.sh"

herdr_linear::start_from_issue WEB-3318 drawer-blank
```

It prints the worktree path. `cd` there and work.

**Ask for the short name** rather than deriving one, when there is somebody to
ask. Every worktree here is called something a person chose — `cue-read`,
`wcs-paper` — not a ticket slug. With no name given it derives a short one from
the title, which is a fallback, not the goal.

**The branch is not the worktree name.** It is `feature/` plus the branch name
Linear supplies, so it carries the identifier: `feature/web-3318-ai-tools-drawer-is-blank…`.
That is deliberate — most branches here carry no identifier, which is why
matching a branch to an issue only ever worked for about a fifth of worktrees.
One started this way is findable forever after. Pass a third argument to use
`bugfix` or `task` instead.

| Exit | Meaning |
|---|---|
| 0 | created; the path is on stdout |
| 1 | refused — no such issue, or a name that cannot become a safe path |
| 2 | a directory of that name already exists; nothing was touched |
| 3 | Linear was unreachable; nothing was created |
| 4 | the issue was read, but the worktree or its binding failed; a directory may exist |

**Exit 2 is never overridden.** That directory may be somebody's live work, and
adopting it would silently re-home it. Pick another name.

**Running it again is safe.** A path already bound to this same issue exits 0
with that path; a path that exists but is unbound gets bound. That is the
recovery when the worktree was made and the binding was not.

**Exit 4 may leave a directory behind.** Look at the path before retrying.

## From nothing

`herdr_linear::start_new` files the issue and makes the worktree. It is a write,
so it is allowlist-gated: the worktrees root itself must be listed in
`$HERDR_LINEAR_WRITE_ALLOWLIST`, by name. Otherwise it runs in shadow.

| Exit | Meaning |
|---|---|
| 0 | created; the path is on stdout |
| 1 | refused — no title, no team, or a description that fails validation |
| 4 | the issue was filed but the worktree or binding failed; stderr says which |
| 5 | shadow mode: nothing created, local or remote; the sentence is on stderr |

**Exit 5 is not success.** Only exit 0 puts a path on stdout.

**Exit 4 means the issue exists.** stderr names its identifier; retry with
`start_from_issue` on that identifier.

Prefer **`/work:new`**. It derives the team and project from where you are,
where this would make you supply them by hand — and getting that wrong files a
ticket somebody has to notice and undo.

`/work:new-project` when the thing you are starting is big enough to hold its
own issues.

## After either

The worktree is bound, so the next session started in it is grounded
automatically. Nothing else is required.
