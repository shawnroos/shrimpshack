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

> Team: Web — the only team on project Frame Effects, read from Linear.

That one line lets a reader catch a wrong answer and its cause without opening a
log. And nothing here refuses: a reader answering `outside`, `negative` or
`unknown` is a signal to weigh and to say, never a reason to stop.

Filing a ticket and then separately making somewhere to work on it are two acts
that always happen together, so this is one command: the issue is created, a
worktree is made and bound to it, and a pane opens in that worktree.

**"Current project" is declared, or derived.** The session's team comes first
when one has been declared — `/work:declare` is how — then the space's project,
and then today's derivation from the issue this worktree is bound to or the
project the space holds. The resolver answers all three, and says which level
each value came from.

```bash
R="${CLAUDE_PLUGIN_ROOT}"
for f in contain secrets sanitize binding linear schemes reconcile description herdr-read states herdr-write repos start context context-filter create; do
  source "$R/lib/$f.sh"
done

CTX="$(herdr_linear::context "$PWD" "$(herdr_linear::workspace_id)")"
herdr_linear::context_fields "$CTX" project_id team_id team_name identifier
```

One tab-separated line: the project id, the team id, the team's name, and the
issue this worktree is bound to. The same JSON carries `team_source` and
`project_source` — `session`, `space`, `tab`, `derived` or `none` — and that is
what you say out loud beside the value. **State the team's name and its id, and where
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

## Filing into a team the context does not cover

Sometimes the ticket genuinely belongs to another team. That is allowed, and it
is deliberate: **the person names the team and confirms**, and nothing local is
recorded for it — no worktree, no binding, no pane.

```bash
herdr_linear::new_issue_outside "$PWD" "The title" /tmp/desc.md "$TEAM" "$PROJECT"
```

It prints the identifier and nothing else, and its exits are the table below
minus the worktree rows. `$PROJECT` is optional and is the target's own project,
never the context's — a project of this team may not carry that one.

**Ask first, every time.** Never infer the team from the title, and never reach
for this because the resolver came back empty; an empty team is a question to
ask, not a reason to file elsewhere. The write question is unchanged: it is
answered per worktree, for the team and project this names.

**Say that the surface is now UNBOUND.** A tab holding work its context does not
cover is titled `UNBOUND: <identifier>` when this plugin makes it. This path
makes none, so say in the report that this session is holding work outside its
context, and what would bind it.

## Write the description first

A HIGHER bar than an edit: this description is composed fresh, so the
`## Problem` / `## Solution` / `## Proposal` spine is required, in that order.
`/work:describe` explains the shape. A ticket filed with a thin description is
a ticket somebody has to come back to.

## The first write from this directory asks once

Writes to Linear are opened by an answer, not by a file somebody edits.

```bash
CTX="$(herdr_linear::context "$PWD" "$(herdr_linear::workspace_id)")"
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
OUT="$(herdr_linear::new_issue "$PWD" "The title" /tmp/desc.md "$(herdr_linear::workspace_id)")"; RC=$?
IFS=$'\t' read -r IDENTIFIER WORKTREE PANE <<< "$OUT"
```

Prints `IDENTIFIER<TAB>WORKTREE<TAB>PANE`. The worktree's path and name come
from the new ticket, exactly as `/work:start` derives them; nobody supplies a
name.

| Exit | Meaning |
|---|---|
| 0 | filed, worktree made, and a pane opened unless the session switch says otherwise |
| 1 | refused, and nothing was filed — no title, no description, a bad description, or a naming scheme this plugin does not render |
| 2 | no team could be derived; nothing was created |
| 3 | shadow mode: nothing was created, local or remote |
| 4 | the tracker call failed; nothing was filed |
| 5 | the issue exists but its worktree did not follow; stderr says what to run, and may carry the repository question |

**The pane opens in the space bound to the issue's project, never beside the
focused pane.** A tab is a piece of work: the new ticket gets its own tab in
that space. When `PANE` is empty and stderr says which space is a question,
nothing was opened. Ask it, using the host's blocking question tool:

**`PANE` is also empty when the session switch is set to `false`**, and then
stderr carries no question, because nothing went wrong. The switch is
`HERDR_LINEAR_OPEN_SESSION` in `docs/settings.md`; unset, this path opens a
session as it always has.

- **This space has no binding:** propose binding it to `$PROJECT`, the
  project the issue was filed into. Record only what the person answers:

```bash
nonce="$(herdr_linear::workspace_propose "$(herdr_linear::workspace_id)" "$PROJECT")"
herdr_linear::workspace_confirm "$(herdr_linear::workspace_id)" "$PROJECT" "$nonce"
herdr_linear::place_session "$WORKTREE" open
```

- **This space is bound to a different project:** that is Misplaced. Say both
  sides, offer to move either one, and do not pick which was wrong.
- **Several spaces are bound to the project:** name each and ask which.

A space's label is never the answer, even when it names the project.

**Exit 5 is not a rollback.** The issue is real. Deleting a freshly filed ticket
to tidy up is worse than leaving it and finishing by hand. When stderr names
several repositories, or none, that is the repository question: run
`/work:start <identifier>`, which asks it properly and records the answer.

Follow the conventions for the title, and ask about anything they list under
"Not yet settled" rather than defaulting:

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/documents.sh"
P="$(herdr_linear::conventions_path)" && cat "$P"
```
