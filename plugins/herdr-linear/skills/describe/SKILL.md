---
name: describe
description: Write or rewrite the Linear description for the issue this worktree is bound to, following the Problem / Solution / Proposal template. Use when a ticket has no description, when the description no longer matches what the work turned out to be, or when asked to bring a ticket up to date.
disable-model-invocation: true
---

# Write the issue description

The library owns the template, the validation and the write. **You write the
prose**, because nothing in the repository can: Problem and Solution are about
the actor, and Proposal is about intent. A branch name and a commit count are
not a description, and a description assembled from them is the diary this
template exists to prevent.

## The template

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/contain.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/secrets.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/binding.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/linear.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/reconcile.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/description.sh"

herdr_linear::description_template > /tmp/desc.md
```

Full rules in `docs/linear-conventions.md`. The three that decide whether a
description is any good:

| Section | Written for | The mistake to avoid |
|---|---|---|
| **Problem** | the actor — user, customer, internal staff | stopping at the first-order effect. The second order is usually what makes it matter: they retry, they lose the work, they stop trusting the tool |
| **Solution** | the same actor, **implementation neutral** | describing the mechanism. Say what their world looks like without the problem, not how it gets fixed |
| **Proposal** | a non-technical reader | fluff and management theatre. Say what is being built |

`### Key Requirements` carries the framing and decisions shaping the work.
`### Constraints` carries technical, business and UX limits. Sections after
Proposal are decided per ticket.

## Never a diary

**The description is always the latest source of truth.** It is not a log, not a
progress record, not a running commentary. This is the rule you will break first,
because appending is easier than rewriting.

The validator refuses:

- two or more dated headings
- entries opening `Update:`, `Progress:`, `Session N:`, `Today:`
- any description that *starts with the whole of the current one* — an append,
  whatever the words say

Working history belongs in a Linear document (`/herdr-linear:publish-doc`).
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
| 2 | refused — unbound, misplaced, stale, or outside the Slate root |
| 3 | shadow mode: the rendered description is printed, nothing sent |
| 5 | the description does not follow the template; stderr says which part |
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
