---
name: start
description: Start work on a Linear issue that has no worktree yet, or start something new that has neither a worktree nor a ticket. Creates the worktree under the project's own worktrees directory, names the branch so the issue is findable from it forever after, and binds the two. Use at the beginning of a piece of work.
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
| 4 | the issue was read, but the worktree or its binding failed; a directory may exist |

**Exit 2 is never overridden.** That directory may be somebody's live work, and
adopting it would silently re-home it. Pick another name.

**Running it again is safe.** A path already bound to this same issue exits 0
with that path; a path that exists but is unbound gets bound. That is the
recovery when the worktree was made and the binding was not.

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

**Exit 5 is not success.** Only exit 0 puts a path on stdout.

**Exit 4 means the issue exists.** stderr names its identifier; retry with
`start_from_issue` on that identifier.

Prefer **`/work:new`**. It derives the team and project from where you are,
where this would make you supply them by hand — and getting that wrong files a
ticket somebody has to notice and undo.

`/work:new-project` when the thing you are starting is big enough to hold its
own issues.

## After either

The worktree is bound, so the next session started in it is grounded
automatically. Nothing else is required.
