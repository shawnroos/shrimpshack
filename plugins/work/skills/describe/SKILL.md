---
name: describe
description: Write or rewrite the Linear description for the issue this worktree is bound to, following the Problem / Solution / Proposal template. Use when a ticket has no description, when the description no longer matches what the work turned out to be, or when asked to bring a ticket up to date.
disable-model-invocation: true
---

# Write the issue description

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

The library owns the template, the validation and the write. **You write the
prose**, because nothing in the repository can: Problem and Solution are about
the actor, and Proposal is about intent. A branch name and a commit count are
not a description, and a description assembled from them is the diary this
template exists to prevent.

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
| `cap` | place the tickets held back by the pane limit? | places them |
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

## The template

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/contain.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/secrets.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/sanitize.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/binding.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/linear.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/board-store.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/reconcile.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/description.sh"

herdr_linear::description_template > /tmp/desc.md
```

**The template is where a NEW description starts. It is not a cage.** A ticket
that has earned its own headings keeps them — the conventions document walks
through `WEB-3214` as the worked example, which uses none of the three spine
headings and is better for it, because a heading that carries the point beats a
heading that carries a category.

So: `description_validate <file>` reports a missing spine as a **note** and
refuses only real defects. Pass `strict` as a second argument when you composed
from the template and want the spine held.

Full rules ship with the plugin:

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/documents.sh"
P="$(herdr_linear::conventions_path)" && cat "$P"
```

The three that decide whether a description is any good:

| Section | Written for | The mistake to avoid |
|---|---|---|
| **Problem** | the actor — user, customer, internal staff | stopping at the first-order effect. The second order is usually what makes it matter: they retry, they lose the work, they stop trusting the tool |
| **Solution** | the same actor, **implementation neutral** | describing the mechanism. Say what their world looks like without the problem, not how it gets fixed |
| **Proposal** | a non-technical reader | fluff and management theatre. Say what is being built |

`### Key Requirements` carries the framing and decisions shaping the work.
`### Constraints` carries technical, business and UX limits. Sections after
Proposal are decided per ticket.

## The first write from this directory asks once

Writes to Linear are opened by an answer, not by a file somebody edits.

```bash
CTX="$(herdr_linear::issue_context "$(herdr_linear::binding_identifier "$PWD")")"
TEAM="$(printf '%s' "$CTX" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("team_id",""))')"
PROJECT="$(printf '%s' "$CTX" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("project_id",""))')"
TEAM_KEY="$(printf '%s' "$CTX" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("team",""))')"
PROJECT_NAME="$(printf '%s' "$CTX" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("project",""))')"
herdr_linear::has_consent "$PWD" && echo "already answered here" || echo "ask first"
```

**Name the team and the project the way a person reads them.** `$TEAM_KEY` and
`$PROJECT_NAME` come out of the same `issue_context` read as the two ids, so
this costs no extra query. A question naming two opaque uuids is a question
nobody can answer, and R4 wants the fact and where it was read together.

Name `$TEAM_KEY`, `$PROJECT_NAME` and the issue, and ask, using the host's blocking
question tool. Record only what that tool returns, in two steps, because
`consent_confirm` requires the nonce `consent_propose` hands back:

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
headless `claude -p "/work:describe … yes"` records nothing — the verb then runs in
shadow and reports what it would have sent. That is the right outcome, not
something to work around.

The answer is scoped to what the question named: a write deriving a different
team or a different project, or made from a different branch, asks again.

## Never a diary

**The description is always the latest source of truth.** It is not a log, not a
progress record, not a running commentary. This is the rule you will break first,
because appending is easier than rewriting.

The validator refuses:

- two or more dated headings
- entries opening `Update:`, `Progress:`, `Session N:`, `Today:`
- any description that *starts with the whole of the current one* — an append,
  whatever the words say

Working history belongs in a Linear document (`/work:publish-doc`).
Status belongs in the issue's state. Neither belongs here.

When the work changed what you understand about the problem, **rewrite the
Problem section**. Do not add a note saying it changed.

## Reading the branch before you write

Problem and Solution need what the work turned out to be, and the branch's
history is where that is written. It is also the largest thing you would read
all session, and almost none of it belongs in this context.

**Dispatch a subagent to read it.** Give it a scratch path — your session's
scratchpad directory when the harness gives you one, otherwise a path carrying
this worktree's name, never a shared one. Brief it with this and nothing more:

```text
Read this branch's commits and its diff against the base branch. Write to
<scratch path>: what changed, why, and anything that contradicts the issue's
current description. Write nothing to Linear and run no git command that moves
HEAD. Name anything you could not tell from the history. Reply with the path and
at most ten lines of gist.
```

Compose the description from that gist and the description already on the issue.
Open the file only when you need a detail the gist does not carry.

**The subagent reads; it never asks and it never records.** It has no prompt
channel, so a question handed to it is a decision lost. Ambiguity comes back as
a line in the file, and you ask here. The write question above is asked in this
session, by a person, and nothing a subagent returns stands in for that answer.

## Writing it

Read the current description first and keep what is still true — you are
rewriting a document, not starting a new one. Then:

```bash
herdr_linear::describe "$PWD" /tmp/desc.md
```

| Exit | Meaning |
|---|---|
| 0 | written; the prior version is saved |
| 1 | identical to what is there; nothing sent |
| 2 | refused — unbound, misplaced, or stale |
| 3 | shadow mode: the rendered description is printed, nothing sent |
| 4 | the Linear fetch or the write itself failed — a network or API error, not a validation problem. Retry |
| 5 | a real defect — an empty section, a leftover placeholder, or a diary. stderr says which. A missing spine is only a note and does not land here |
| 6 | refused as a diary |

On 5 or 6, fix the text and try again. Do not work around the validator — it is
enforcing the one rule that keeps these tickets readable.

## Undoing one

Every write saves the prior description first.

```bash
herdr_linear::describe_backups WEB-3318      # what is saved
herdr_linear::describe_restore WEB-3318      # prints the newest
```

`describe_restore` prints; it does not push. Review it, then write it back with
`describe` if that is what you want.
