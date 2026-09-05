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
| **Worktree exists** | `/herdr-linear:bind` | `/herdr-linear:bind`, then its create step |
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

**Exit 2 is never overridden.** That directory may be somebody's live work, and
adopting it would silently re-home it. Pick another name.

## From nothing

Neither a ticket nor a worktree. Write the description first — the same bar as
any other, `/herdr-linear:describe` explains the shape — then:

```bash
herdr_linear::start_new "Improve AI tools analytics" /tmp/desc.md "$TEAM_ID" ai-analytics
```

This one **does** write to Linear, so it is shadow-gated like every other write.
In shadow mode it creates no worktree either: one bound to an issue that was
never filed is a dangling reference pointing at nothing.

Follow `docs/linear-conventions.md` for the title, and **ask about anything it
lists under "Not yet settled"** — who is assigned, whether `ready-for-ai`
applies, whether this should be a project rather than an issue. Those are
decisions, not defaults.

## After either

The worktree is bound, so the next session started in it is grounded
automatically. Nothing else is required.
