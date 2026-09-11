---
name: new
description: File a new Linear issue in the current project and open a session to work it in — the issue, a git worktree, and a pane, in one step. Use when starting a new piece of work alongside what you are already doing.
disable-model-invocation: true
---

# New issue, and somewhere to work it

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

Filing a ticket and then separately making somewhere to work on it are two acts
that always happen together, so this is one command: the issue is created, a
worktree is made and bound to it, and a pane opens in that worktree.

**"Current project" is derived, not asked for.** It comes from the issue this
worktree is bound to, or from the project the herdr workspace is bound to.

```bash
R="${CLAUDE_PLUGIN_ROOT}"
for f in contain secrets sanitize binding linear reconcile description herdr-read herdr-write repos start context create; do
  source "$R/lib/$f.sh"
done

CTX="$(herdr_linear::current_context "$PWD" "$(herdr_linear::workspace_id)")"
herdr_linear::context_fields "$CTX" project_id team_id team_name identifier
```

One tab-separated line: the project id, the team id, the team's name, and the
issue this worktree is bound to. **State the team's name and its id, and where
they came from, before you file** — "Team: Web, the only team on project AI
Canvas Tools".

An empty team field means the fact is unresolved, not that the answer is
unknowable. Ask which, and name the candidates:

```bash
herdr_linear::project_teams "$(herdr_linear::context_fields "$CTX" project_id)"
```

Each line is `ID<TAB>NAME`. Several lines is a fork — ask, using the host's
blocking question tool, and file nothing until answered. No project at all means
there is nothing to derive from: bind this worktree (`/work:bind`), or bind the
workspace to a project. **Never pick a team yourself** — filing into the wrong
one is a thing somebody has to notice and undo.

## Write the description first

A HIGHER bar than an edit: this description is composed fresh, so the
`## Problem` / `## Solution` / `## Proposal` spine is required, in that order.
`/work:describe` explains the shape. A ticket filed with a thin description is
a ticket somebody has to come back to.

## The first write from this directory asks once

Writes to Linear are opened by an answer, not by a file somebody edits.

```bash
CTX="$(herdr_linear::current_context "$PWD" "$(herdr_linear::workspace_id)")"
FIELDS="$(herdr_linear::context_fields "$CTX" team_id project_id)"
TEAM="$(printf '%s' "$FIELDS" | cut -f1)"
PROJECT="$(printf '%s' "$FIELDS" | cut -f2)"
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

**No is an answer too.** It answers the same proposal, so it carries the same
nonce -- a decline clears the deferred-write notice, and nothing may clear that
by answering a question nobody asked:

```bash
herdr_linear::consent_decline "$PWD" "$TEAM"  "$PROJECT" "$nonce"
```

Declining records no answer: it clears the question and the deferred-write
notice, and the verb still runs in shadow. There is no "no" on file, because an
unanswered question and a refused one both mean do not write.

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
| 1 | refused — no title, no description, or a bad description |
| 2 | no team could be derived; nothing was created |
| 3 | shadow mode: nothing was created, local or remote |
| 4 | the issue exists but something after it failed; stderr says what to run |

**Exit 4 is not a rollback.** The issue is real. Deleting a freshly filed ticket
to tidy up is worse than leaving it and finishing by hand.

Follow the conventions for the title, and ask about anything they list under
"Not yet settled" rather than defaulting:

```bash
cat "${CLAUDE_PLUGIN_ROOT}/docs/linear-conventions.md"
```
