---
name: start
description: Start work on a Linear issue that has no worktree yet, or start something new that has neither a worktree nor a ticket. Creates the worktree at a path derived from the ticket — worktrees root, organisation, project or team, then the identifier and title — in a repository read from what was recorded for that project, asking which repository when that is a choice. Names the branch so the issue is findable from it forever after, and binds the two. Use at the beginning of a piece of work.
disable-model-invocation: true
---

# Start a piece of work

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

Binding assumes a worktree already exists, which is the uncommon case. Work
usually starts one of two other ways:

| | Ticket exists | No ticket |
|---|---|---|
| **Worktree exists** | `/work:bind` | `/work:bind`, then its create step |
| **No worktree** | **here — the common one** | **here** |

## The board first

Before this command's own work, bring the herdr board up to date with Linear and
deal with what it is waiting on. With no board configured this prints nothing;
carry straight on.

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/contain.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/secrets.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/sanitize.sh"
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

## From a ticket

**This writes nothing to Linear.** It reads the issue, creates a local worktree
and records a local binding — so it works before the credential has been rotated
and before anybody has answered the write question, and it cannot damage a board.

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/contain.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/secrets.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/sanitize.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/binding.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/linear.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/schemes.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/reconcile.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/description.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/repos.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/herdr-read.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/board-store.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/states.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/herdr-write.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/start.sh"

herdr_linear::start_from_issue WEB-3318
```

It prints the worktree path. `cd` there and work.

**A session is opened only when the switch asks for one.** This path opens none
by default, which is what it has always done. Pass the worktree it printed:

```bash
herdr_linear::place_session "$WORKTREE" none
```

`none` is what this path does when the switch is unset. The switch is
`HERDR_LINEAR_OPEN_SESSION` in `docs/settings.md`: set it to `true` and this
opens a pane in the space bound to the ticket's project, printing its id. A
session that could not be opened is reported on stderr and costs nothing else —
the worktree is made and bound either way.

**The path comes from the ticket, never from where you are standing.** It is
`<worktrees-root>/<org>/<project or team>/<IDENTIFIER>-<title-slug>` — for
example `~/worktrees/<org>/ai-canvas-tools/WEB-3318-ai-tools-drawer-is-blank-when-a-still`.
The worktrees root is `$HOME/worktrees` unless `HERDR_LINEAR_WORKTREES_ROOT`
says otherwise, and it is kept apart from `~/projects` so deleting all of it
only ever loses uncommitted work. Nobody supplies the name, so nothing can drop
the identifier out of it.

**The branch is the directory name behind the prefix:**
`feature/WEB-3318-ai-tools-drawer-is-blank-when-a-still`. The identifier is in
both, so the worktree is findable from its branch forever after. Pass a second
argument to use `bugfix` or `task` instead of `feature`.

## A ticket the board reserved

**Try this first, before `start_from_issue`.** When the herdr board shows a
ticket nobody has started, it holds a reserved pane for it: a shell outside any
worktree, under a worktree name and branch fixed when the pane was made. Starting
through the board makes the worktree under that reserved name, opens a pane in it
where the reserved pane is, starts the agent there, and closes the reserved pane.
A session started by hand in a reserved pane is told to come here; run this from
that pane and the pane is replaced once your shell has finished.

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/contain.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/secrets.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/sanitize.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/binding.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/linear.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/schemes.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/reconcile.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/description.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/repos.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/herdr-read.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/board-store.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/states.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/herdr-write.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/start.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/board-config.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/board-linear.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/board-plan.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/board-herdr.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/board-sync.sh"

herdr_linear::board_start_reserved WEB-3318
```

It prints the worktree path and the new pane's id, separated by a tab. Do not
call `place_session` after it: the board already gave the ticket its pane. **The
name and branch are the reservation's, not the title's:** a ticket renamed since
it was reserved keeps its reserved name. The project segment and the repository
are read now, so a ticket moved to another project since then lands under that
project.

| Exit | Meaning |
|---|---|
| 0 | started; the worktree and the pane id are on stdout |
| 1–4 | as in the table under **Which repository**; the board changed nothing |
| 6 | which repository is a choice; nothing was made and the reserved pane stays. Ask, then pass the answer as a second argument |
| 7 | no reserved pane is waiting for this ticket, so nothing was done. Start it with `start_from_issue` above |
| 8 | a board sync kept the board busy past its wait; nothing was done. Run this again |
| 9 | the worktree is made and bound, but the pane or its agent is not confirmed; stderr says which. Say so to the person |

**Exit 7 is the ordinary answer when there is no board**, or when the ticket has
no reserved pane, including one somebody closed by hand. It is not an error.

**A reserved pane somebody else is using is left open.** When another agent runs
in it, or it has focus, the start still happens and stderr says the pane was
left open. Tell the person, so they can close it.

## Which repository

A project touches several repositories, so the repository is read from what was
recorded for the issue's project — or its team, when it has no project — never
from the directory you are in. `start_from_issue` reads the candidates itself,
through `herdr_linear::scope_repos`; to see them for an issue you already have
the ids for:

```bash
herdr_linear::scope_repos "project-$PROJECT_ID" "team-$TEAM_ID"
```

- **One candidate:** `start_from_issue` uses it and says so on stderr — the
  repository, the record file it was read from, and that it was the only one
  recorded. Repeat that line to the person.
- **Several, or none:** it creates nothing and exits 6.
  `herdr_linear::no_repo_reason` is what it printed: it names every candidate.
  **Ask**, naming every candidate, using the host's blocking question tool. The
  directory you are standing in is never the tiebreaker. When it is a worktree
  bound to another issue in the same project, its repository is a strong default
  to *offer* in the question — say that it is where you are, and still ask.
- **Then retry with the answer, as an absolute path.** A relative path is
  refused, because resolving it would let the current directory decide again:

```bash
herdr_linear::start_from_issue WEB-3318 "" "$PWD" /Users/me/projects/web-app
```

The answer is recorded for the project and for its team, so the question is
never asked again for that scope. **A wrong answer is undone by deleting the
scope's record file** under `scopes/` in the store
(`$HERDR_LINEAR_STORE_DIR/scopes/project-<id>.json`, and the `team-<id>.json`
beside it). There is no verb for that yet.

| Exit | Meaning |
|---|---|
| 0 | created; the path is on stdout, and stderr says which repository and why |
| 1 | refused — no such issue, a naming scheme this plugin does not render (stderr names the valid ones), a name that cannot become a safe path, a relative or non-repository answer, or a worktrees root that overlaps `~/projects`, `/` or `$HOME` |
| 2 | a directory of that name already exists; nothing was touched |
| 3 | Linear was unreachable; nothing was created |
| 4 | the issue was read, but the worktree or its binding failed; a directory may exist |
| 6 | which repository is a choice; nothing was created. Ask, then retry with the answer |

**Exit 2 is never overridden.** That directory may be somebody's live work, and
adopting it would silently re-home it. Say whose it is and stop.

**Running it again is safe.** A path already bound to this same issue exits 0
with that path; a path that exists but is unbound gets bound. That is the
recovery when the worktree was made and the binding was not. A worktree whose
directory was deleted is made again on the same branch.

**Exit 4 may leave a directory behind.** Look at the path before retrying.

## The first write from this directory asks once

Writes to Linear are opened by an answer, not by a file somebody edits.

```bash
herdr_linear::has_consent "$PWD" && echo "already answered here" || echo "ask first"
```

Name `$TEAM` — there is no project yet — and the title, and ask, using the
host's blocking question tool. Record only what that tool returns, in two steps,
because `consent_confirm` requires the nonce `consent_propose` hands back:

```bash
nonce="$(herdr_linear::consent_propose "$PWD" "$TEAM"  "")"
herdr_linear::consent_confirm "$PWD" "$TEAM"  "" "$nonce"
```

**No is an answer too.** It answers the same proposal, so it carries the same
nonce -- a decline clears the deferred-write notice, and nothing may clear that
by answering a question nobody asked:

```bash
herdr_linear::consent_decline "$PWD" "$TEAM"  "" "$nonce"
```

Declining records no answer: it clears the question and the deferred-write
notice, and the verb still runs in shadow. There is no "no" on file, because an
unanswered question and a refused one both mean do not write.

**Never supply the answer yourself.** A prompt that is refused, a hook, or a
headless `claude -p "/work:start … yes"` records nothing — the verb then runs in
shadow and reports what it would have sent. That is the right outcome, not
something to work around.

The answer is scoped to what the question named: a write deriving a different
team, or made from a different branch, asks again.

## From nothing

`herdr_linear::start_new` files the issue and makes the worktree. It is a write,
so it asks first — about the team, since there is no project yet to name — and
runs in shadow until somebody answers.

| Exit | Meaning |
|---|---|
| 0 | created; the path is on stdout |
| 1 | refused, and nothing was filed — no title, no team, a description that fails strict validation (the Problem/Solution/Proposal spine is required here), or a naming scheme this plugin does not render |
| 4 | the issue was filed but the worktree or binding failed; stderr says which |
| 5 | shadow mode: nothing created, local or remote; the sentence is on stderr |
| 6 | the issue was filed, and which repository is a choice; stderr names the identifier and every candidate |

**Exit 5 is not success.** Only exit 0 puts a path on stdout.

**Exit 4 and exit 6 mean the issue exists.** stderr names its identifier. On 6,
ask the repository question above, then retry with `start_from_issue` on that
identifier and the answer — or pass the answer to `start_new` as a fifth
argument up front when it is already known.

Prefer **`/work:new`**. It derives the team and project from where you are,
where this would make you supply them by hand — and getting that wrong files a
ticket somebody has to notice and undo.

`/work:new-project` when the thing you are starting is big enough to hold its
own issues.

## After either

The worktree is bound, so the next session started in it is grounded
automatically. Nothing else is required.
