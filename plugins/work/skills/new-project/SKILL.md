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

## The first write from this directory asks once

Writes to Linear are opened by an answer, not by a file somebody edits.

```bash
R="${CLAUDE_PLUGIN_ROOT}"
for f in contain secrets sanitize binding linear schemes reconcile description herdr-read states herdr-write repos start context board-store board-linear create; do
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
headless `claude -p "/work:new-project … yes"` records nothing — the verb then runs in
shadow and reports what it would have sent. That is the right outcome, not
something to work around.

The answer is scoped to what the question named: a write deriving a different
team, or made from a different branch, asks again.

```bash
R="${CLAUDE_PLUGIN_ROOT}"
for f in contain secrets sanitize binding linear schemes reconcile description herdr-read states herdr-write repos start context board-store board-linear create; do
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
source "${CLAUDE_PLUGIN_ROOT}/lib/documents.sh"
P="$(herdr_linear::conventions_path)" && cat "$P"
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
