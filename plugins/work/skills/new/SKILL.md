---
name: new
description: File a new Linear issue in the current project and open a session to work it in — the issue, a git worktree, and a pane, in one step. Use when starting a new piece of work alongside what you are already doing.
disable-model-invocation: true
---

# New issue, and somewhere to work it

Filing a ticket and then separately making somewhere to work on it are two acts
that always happen together, so this is one command: the issue is created, a
worktree is made and bound to it, and a pane opens in that worktree.

**"Current project" is derived, not asked for.** It comes from the issue this
worktree is bound to, or from the project the herdr workspace is bound to.

```bash
R="${CLAUDE_PLUGIN_ROOT}"
for f in contain secrets binding linear reconcile description herdr-read herdr-write start create; do
  source "$R/lib/$f.sh"
done

herdr_linear::current_context "$PWD" "$(herdr_linear::workspace_id)"
```

If that prints no `team=`, stop and say so. Bind this worktree first
(`/work:bind`), or bind the workspace to a project. **Do not pick a team** —
filing into the wrong one is a thing somebody has to notice and undo.

## Write the description first

Same bar as any other: `/work:describe` explains the shape. A ticket filed with
a thin description is a ticket somebody has to come back to.

## Then

```bash
herdr_linear::new_issue "$PWD" "The title" /tmp/desc.md "$(herdr_linear::workspace_id)" short-name
```

Prints `IDENTIFIER<TAB>WORKTREE<TAB>PANE`.

**Ask for the short name.** Every worktree here is called something a person
chose — `cue-read`, `wcs-paper`. The derived fallback is mechanical and worse.

| Exit | Meaning |
|---|---|
| 0 | filed, worktree made, pane opened |
| 1 | refused — no title, no description, bad description, outside the Slate root |
| 2 | no team could be derived; nothing was created |
| 3 | shadow mode: nothing was created, local or remote |
| 4 | the issue exists but something after it failed; stderr says what to run |

**Exit 4 is not a rollback.** The issue is real. Deleting a freshly filed ticket
to tidy up is worse than leaving it and finishing by hand.

Follow `docs/linear-conventions.md` for the title, and ask about anything it
lists under "Not yet settled" rather than defaulting.
