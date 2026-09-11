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
source "${CLAUDE_PLUGIN_ROOT}/lib/reconcile.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/description.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/repos.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/start.sh"

herdr_linear::start_from_issue WEB-3318
```

It prints the worktree path. `cd` there and work.

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
| 1 | refused — no such issue, a name that cannot become a safe path, a relative or non-repository answer, or a worktrees root that overlaps `~/projects`, `/` or `$HOME` |
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
| 1 | refused — no title, no team, or a description that fails strict validation (the Problem/Solution/Proposal spine is required here) |
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
