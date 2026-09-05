---
name: doc
description: Publish a markdown document to the Linear issue this worktree is bound to — a diagnosis, findings, an implementation log, a reference. Use for anything that would otherwise be written to a gitignored /docs directory and die with the worktree.
disable-model-invocation: true
---

# Publish a document to the issue

Slate's web-app ignores `/docs`, so a document written on a branch dies with the
worktree. This is where it should go instead: attached to the issue, outliving
the branch, readable by people who do not have the repository.

**This is also where working history belongs.** The description is the latest
source of truth and never a diary — if you want a record of what happened, it
goes in a document, not the ticket body.

## Publishing

```bash
R="${CLAUDE_PLUGIN_ROOT}"
source "$R/lib/contain.sh"; source "$R/lib/secrets.sh"; source "$R/lib/binding.sh"
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

| Scope | Kinds |
|---|---|
| issue | `diagnosis` `findings` `regression-report` `implementation-log` `reference` `test-plan` |
| project | `RFC` `PRD` `plan` `development-plan` `architecture-overview` `codebase-exploration` `design-references` |

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
| 1 | refused — unbound, outside the Slate root, unknown kind, or no such file |
| 2 | shadow mode: the title is printed, nothing sent |
| 3 | the API refused it, or reported success with no document |

Full conventions, derived from 40 real documents rather than invented, are in
`docs/linear-conventions.md`.
