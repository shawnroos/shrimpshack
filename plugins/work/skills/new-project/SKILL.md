---
name: new-project
description: Create a Linear project and the herdr workspace that is its space, bound together. Use when starting a body of work large enough to hold its own issues and milestones.
disable-model-invocation: true
---

# New project, and the space it lives in

A Linear project and a herdr workspace are the same thing seen from two sides.
This makes both and binds them, so every worktree opened in that space knows
which project it belongs to.

```bash
R="${CLAUDE_PLUGIN_ROOT}"
for f in contain secrets binding linear reconcile description herdr-read herdr-write start create; do
  source "$R/lib/$f.sh"
done

herdr_linear::new_project "AI Canvas Tools" /tmp/content.md "$TEAM_ID"
```

Prints `PROJECT_ID<TAB>WORKSPACE_ID`.

## Before running it

**A project is a bigger claim than an issue.** It is a body of work with its own
milestones, spanning many issues over months. `docs/linear-conventions.md` lists
*when a project is created rather than a parent issue* as **not yet settled** —
so ask. Do not decide it because a project was the thing that was mentioned.

The content file is the project's own document — what this body of work is for,
what is in and out. Not a description of the first ticket.

| Exit | Meaning |
|---|---|
| 0 | project and space created and bound |
| 1 | refused — no name, no team, no content file, or a worktrees root that is missing or outside the Slate root |
| 3 | shadow mode: nothing created, local or remote |
| 4 | nothing was created — the request never reached Linear, or Linear refused it |
| 5 | the project exists but the space does not; stderr says which |

**Exit 4 means no project.** Do not tell anybody one was made.

**Exit 5 leaves a usable project.** Without herdr the project still exists and
works; only the space is missing. Bind it later with `/work:bind`.

**Creating a project is allowlist-gated on the worktrees root.** That root must
be listed by name in `$HERDR_LINEAR_WRITE_ALLOWLIST`; an entry for a single
worktree does not grant it. The fourth argument is the herdr workspace label and
defaults to the project name.
