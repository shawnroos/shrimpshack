---
name: doc
description: Publish a markdown document to the Linear issue this worktree is bound to — a diagnosis, findings, an implementation log, a reference. Use for anything that would otherwise be written to a gitignored /docs directory and die with the worktree.
disable-model-invocation: true
---

# Publish a document to the issue

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

Plenty of repositories gitignore `/docs`, so a document written on a branch
dies with the worktree. This is where it should go instead: attached to the issue, outliving
the branch, readable by people who do not have the repository.

**This is also where working history belongs.** The description is the latest
source of truth and never a diary — if you want a record of what happened, it
goes in a document, not the ticket body.

## The board first

Before this command's own work, bring the herdr board up to date with Linear and
deal with what it is waiting on. With no board configured this prints nothing;
carry straight on.

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/contain.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/secrets.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/sanitize.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/session.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/session-binding.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/scope-linear.sh"
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
source "$R/lib/contain.sh"; source "$R/lib/secrets.sh"; source "$R/lib/sanitize.sh"
source "$R/lib/binding.sh"
source "$R/lib/linear.sh"; source "$R/lib/reconcile.sh"; source "$R/lib/documents.sh"
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
headless `claude -p "/work:doc … yes"` records nothing — the verb then runs in
shadow and reports what it would have sent. That is the right outcome, not
something to work around.

The answer is scoped to what the question named: a write deriving a different
team or a different project, or made from a different branch, asks again.

## Publishing

```bash
R="${CLAUDE_PLUGIN_ROOT}"
source "$R/lib/contain.sh"; source "$R/lib/secrets.sh"; source "$R/lib/sanitize.sh"
source "$R/lib/binding.sh"
source "$R/lib/linear.sh"; source "$R/lib/reconcile.sh"; source "$R/lib/documents.sh"

herdr_linear::doc_publish "$PWD" diagnosis "texture leak on image swap" ./notes.md
```

Or take the subject from a file's own first heading:

```bash
herdr_linear::doc_publish_file "$PWD" findings ./docs/analysis.md
```


## Kinds

An unlisted kind is refused, not passed through. A new kind is a decision, and
a shared vocabulary only works if the title tells you what you are about to read.

| Scope | Kinds | Publishable here |
|---|---|---|
| issue | `diagnosis` `findings` `regression-report` `implementation-log` `reference` `test-plan` | yes |
| project | `RFC` `PRD` `plan` `development-plan` `architecture-overview` `codebase-exploration` `design-references` | **no** |

`doc_publish` always resolves the issue this worktree is bound to and always
writes `issueId` — there is no `projectId` path. A project-scoped kind is
refused rather than silently attached to the wrong issue. Whether an agent may
create a project-scoped document at all is listed under "Not yet settled" in
the conventions document; that is a question for Shawn to answer, not one this
skill implements a path around.

Titles are built for you: `WEB-3127 diagnosis: texture leak on image swap`.
`:mag:` is applied to `diagnosis` and `findings`; everything else gets no icon,
which is what 22 of 40 documents in the workspace do.

## Re-publishing

A document this plugin created is **updated in place** on the next publish under
the same title — the id is recorded against the binding. So re-publishing as
work progresses does not litter the issue with near-duplicates.

A document the plugin did not create is never modified. That list is never read
back from Linear: asking the tracker which documents are on an issue would let
anyone who can attach one move it into the writable set.

| Exit | Meaning |
|---|---|
| 0 | published; the document id is on stdout |
| 1 | refused — unbound, unknown kind, project-scoped kind, or no such file |
| 2 | shadow mode: the title is printed, nothing sent |
| 3 | the API refused it, or reported success with no document |

Full conventions, derived from 40 real documents rather than invented, ship
with the plugin:

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/documents.sh"
P="$(herdr_linear::conventions_path)" && cat "$P"
```
