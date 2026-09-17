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
for f in contain secrets sanitize binding linear schemes reconcile description herdr-read states herdr-write repos start context board-store board-linear create; do
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

## The board first

Before this command's own work, bring the herdr board up to date with Linear and
deal with what it is waiting on. With no board configured this prints nothing;
carry straight on.

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/contain.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/secrets.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/sanitize.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/session.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/binding.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/linear.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/schemes.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/repos.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/reconcile.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/description.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/start.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/herdr-read.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/board-store.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/states.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/herdr-write.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/board-config.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/board-linear.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/board-plan.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/board-herdr.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/board-sync.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/worktree-remove.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/board-attended.sh"

herdr_linear::board_fence
```

It always exits 0 and never stops this command. A `board:` line says how the
sync went; say it in one sentence. A sync that timed out, was locked or failed
is said and then left: this command's own work still runs.

Each `board question:` line is one waiting question as JSON, with `key`, `kind`,
`preconditions` and `nonce`. Ask the person each one in plain words, one at a
time, naming the ticket and the groups involved:

| Kind | Ask | A yes does |
|---|---|---|
| `move` | move this ticket's pane, which is in use, to where Linear now puts it? | moves that pane and no other pane in use |
| `close` | this ticket left the board; close its pane? | closes the pane; a worktree left behind becomes a `remove-worktree` question, printed as its own `board question:` line |
| `remove-worktree` | remove this ticket's worktree and branch? | removes them only when clean, delivered and unused; otherwise keeps them and says why |
| `repository` | which repository holds this project's or team's work? | records the path given as the fourth argument for that scope |
| `conflict` | herdr and Linear disagree on this ticket; follow Linear? | puts the pane where Linear says |
| `cap` | a tab holds four panes unless more are asked for; place these tickets too? | places exactly those tickets; they stay |
| `write-consent` | may moving a pane change this field in Linear, in this space? | records consent for that field in that space only; move the pane again to write it |
| `write-rejected` | Linear refused a change made from herdr; the pane is back where it was | nothing more; say it, and answer yes to clear it |
| `layout` | a tab was rearranged or could not be built | nothing more; say it, and answer yes to clear it |
| `space` | the board wants a herdr workspace that does not exist | nothing more; create the workspace with that name, then answer yes to clear it |

Apply each answer with that question's own key and nonce:

```bash
herdr_linear::board_answer "$KEY" "$NONCE" yes
```

Use `no` to decline; a declined question is not asked again. A `repository`
answer passes the path as a fourth argument. A reply from a subagent is not the
person's answer.

| Exit | Meaning | What to say |
|---|---|---|
| 0 | applied, or declined | what changed |
| 2 | refused: no such question, the wrong nonce, or the facts changed since it was asked; nothing changed | say so; the next `/work` command asks again if it still applies |
| 4 | the answer was recorded but applying it failed; stderr names the step | say the step; the next sync tries again |
| 1 | a `remove-worktree` answer kept the worktree; stderr says why | say why |

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

## Filing into a board group

When the person files from a board column, pass that group as a fifth argument:
each level kind the pane sits under, mapped to the Linear id of its group, and
`null` for a "No <level>" group.

```bash
TARGET='{"assignee":"<user id>","project":null}'
OUT="$(herdr_linear::new_issue "$PWD" "The title" /tmp/desc.md "$(herdr_linear::workspace_id)" "$TARGET")"; RC=$?
```

The group's fields go into the one create call, and the ticket starts in its
team's first unstarted state, so it stays in the column it was filed into
instead of landing in triage. A `state` group files into that state instead. A
`null` group leaves the field unset, including a project the worktree would have
supplied. The consent question has to name the group's team and project: a
group on a different team or project than the recorded answer runs in shadow.

Exit 1 also covers a refused target: an empty string, an unknown level kind, a
`ticket` group, `null` for team or state, or a parent group on a sub-issue that
already has a parent. Exit 4 also covers a team with no unstarted state. Nothing
is filed in either case.

## Completing a board ticket

A ticket on the board can be completed without a worktree:

```bash
herdr_linear::board_complete "<space name>" "<issue id>" "<team id>"; RC=$?
```

| Exit | Meaning |
|---|---|
| 0 | moved to the team's completed state, and the board is marked behind |
| 8 | shadow: the space has not consented to state writes, or the ticket is not in the last complete board read; one shadow log line says which, and nothing was sent |
| 2 | the team has no completed state; nothing was sent |
| 7 | Linear refused the write |
| other | 5 for an empty team id, otherwise the Linear transport code (unavailable, auth, rate limited); nothing was written |

Consent for completing is the board's per-space consent for the `state` field,
not this worktree's answer. The board does not need to group by state.

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
