---
name: new-project
description: Create a Linear project and the herdr workspace that is its space, bound together. Use when starting a body of work large enough to hold its own issues and milestones.
disable-model-invocation: true
---

# New project, and the space it lives in

## Act or ask

- **Mechanically derivable** — the team a single-team project has, the project a
  worktree's path names, an unambiguous default — **resolve it yourself** and
  carry on.
- **A genuine fork** — which of three teams, which side of a misplaced binding
  to move, whether this is a project or a parent issue — **ask**, name every
  candidate, and change nothing until it is answered.
- **When you cannot tell which of the two it is, ask.** The default for a
  substantive choice is ask, not resolve.

**Say every resolution out loud before you act on it**, naming three things:
the fact, where you read it, and how you derived it.

> Team: Web — the only team on project AI Canvas Tools, read from Linear.

That one line lets a reader catch a wrong answer and its cause without opening a
log. And nothing here refuses: a reader answering `outside`, `negative` or
`unknown` is a signal to weigh and to say, never a reason to stop.

A Linear project and a herdr workspace are the same thing seen from two sides.
This makes both and binds them, so every worktree opened in that space knows
which project it belongs to.

## The first write from this directory asks once

Writes to Linear are opened by an answer, not by a file somebody edits.

```bash
R="${CLAUDE_PLUGIN_ROOT}"
for f in contain secrets sanitize binding linear reconcile description herdr-read herdr-write start create; do
  source "$R/lib/$f.sh"
done
herdr_linear::has_consent "$PWD" && echo "already answered here" || echo "ask first"
```

Name `$TEAM` — there is no project yet — and the title, and ask, using the
host's blocking question tool. Record only what that tool returns, in two steps,
because `consent_confirm` requires the nonce `consent_propose` hands back:

```bash
nonce="$(herdr_linear::consent_propose "$PWD" "$TEAM"  "")"
herdr_linear::consent_confirm "$PWD" "$TEAM"  "" "$nonce"
```

**Never supply the answer yourself.** A prompt that is refused, a hook, or a
headless `claude -p "/work:new-project … yes"` records nothing — the verb then runs in
shadow and reports what it would have sent. That is the right outcome, not
something to work around.

The answer is scoped to what the question named: a write deriving a different
team, or made from a different branch, asks again.

```bash
R="${CLAUDE_PLUGIN_ROOT}"
for f in contain secrets sanitize binding linear reconcile description herdr-read herdr-write start create; do
  source "$R/lib/$f.sh"
done

herdr_linear::new_project "AI Canvas Tools" /tmp/content.md "$TEAM_ID"
```

Prints `PROJECT_ID<TAB>WORKSPACE_ID`.


## Before running it

**A project is a bigger claim than an issue.** It is a body of work with its own
milestones, spanning many issues over months. The conventions list *when a
project is created rather than a parent issue* as **not yet settled** — so ask.
Do not decide it because a project was the thing that was mentioned.

```bash
cat "${CLAUDE_PLUGIN_ROOT}/docs/linear-conventions.md"
```

The content file is the project's own document — what this body of work is for,
what is in and out. Not a description of the first ticket.

| Exit | Meaning |
|---|---|
| 0 | project and space created and bound |
| 1 | refused — no name, no team, or no content file |
| 3 | shadow mode: nothing created, local or remote |
| 4 | nothing was created — the request never reached Linear, or Linear refused it |
| 5 | the project exists but the space does not; stderr says which |

**Exit 4 means no project.** Do not tell anybody one was made.

**Exit 5 leaves a usable project.** Without herdr the project still exists and
works; only the space is missing. Bind it later with `/work:bind`.

**Creating a project asks about the team only**, because a project has no
project of its own to name. The answer is recorded for the directory the command
is run from, which needs no binding. The fourth argument is the herdr workspace
label and defaults to the project name.
