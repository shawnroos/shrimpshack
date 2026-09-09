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

## The template

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/contain.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/secrets.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/sanitize.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/binding.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/linear.sh"
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
cat "${CLAUDE_PLUGIN_ROOT}/docs/linear-conventions.md"
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
