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
for f in contain secrets sanitize binding linear reconcile description herdr-read herdr-write start create; do
  source "$R/lib/$f.sh"
done

herdr_linear::current_context "$PWD" "$(herdr_linear::workspace_id)"
```

If that prints no `team=`, stop and say so. Bind this worktree first
(`/work:bind`), or bind the workspace to a project. **Do not pick a team** —
filing into the wrong one is a thing somebody has to notice and undo.

## Write the description first

A HIGHER bar than an edit: this description is composed fresh, so the
`## Problem` / `## Solution` / `## Proposal` spine is required, in that order.
`/work:describe` explains the shape. A ticket filed with a thin description is
a ticket somebody has to come back to.

## The first write from this directory asks once

Writes to Linear are opened by an answer, not by a file somebody edits.

```bash
CTX="$(herdr_linear::current_context "$PWD" "$(herdr_linear::workspace_id)")"
TEAM="$(herdr_linear::_ctx_field "$CTX" team)"
PROJECT="$(herdr_linear::_ctx_field "$CTX" project)"
herdr_linear::has_consent "$PWD" && echo "already answered here" || echo "ask first"
```

Name `$TEAM`, `$PROJECT` and the issue — or the title, when the write **is** the
creation — and ask, using the host's blocking question tool. Record only what
that tool returns, in two steps, because `consent_confirm` requires the nonce
`consent_propose` hands back:

```bash
nonce="$(herdr_linear::consent_propose "$PWD" "$TEAM"  "$PROJECT")"
herdr_linear::consent_confirm "$PWD" "$TEAM"  "$PROJECT" "$nonce"
```

**Never supply the answer yourself.** A prompt that is refused, a hook, or a
headless `claude -p "/work:new … yes"` records nothing — the verb then runs in
shadow and reports what it would have sent. That is the right outcome, not
something to work around.

The answer is scoped to what the question named: a write deriving a different
team or a different project, or made from a different branch, asks again.

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
