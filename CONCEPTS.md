# Concepts

Shared domain vocabulary for this project — entities, named processes, and status concepts
with project-specific meaning. Seeded with core domain vocabulary, then accretes as
ce-compound and ce-compound-refresh process learnings; direct edits are fine. Glossary
only, not a spec or catch-all.

## Memory

### Store
The single directory holding every memory body, shared by every project and session on the
machine. There is exactly one — memories do not scatter per-repo — so a fact learned in one
project is reachable from all of them.

### Memory
One durable fact in its own file: a short body, plus declared metadata describing what it is
and when it was last used. A memory is written to be read on its own, by a reader who has
none of the context that produced it.

### Scope
Whether a memory applies everywhere or only inside one repository. Global memories surface
anywhere; a repo-scoped one surfaces in its own repository and in repositories nested
inside it, while a *sibling* repository's memories are suppressed — so one project's
conventions never leak sideways into another's. A worktree resolves to its parent
repository rather than counting as a separate scope.

### Index
The auto-loaded list of pointers to memories — one line each, never bodies. It is a
projection of the store under a load budget, not the store itself: what it omits is still
present and still reachable.

## Recall

### Recall
Looking a memory up and returning its body. Layered: declared triggers first, then semantic
search, then a local keyword index when search is unavailable. The layer that answered is
always reported, so a degraded lookup is never mistaken for an empty one.

### Trigger
A typed pattern declared on a memory itself that names a machine-recognizable
situation the memory applies to — a command shape, an error string, a tool name. Every
entry declares whether it is a literal or a regular expression; an untyped one is rejected
rather than guessed at, because the two readings differ silently.

A memory without a trigger is not incomplete — it is served by Recall's search layers
instead.

### Nudge
A pointer to a memory surfaced automatically because one of its triggers matched what just
happened — title and how to fetch it, never the body. Deduplicated within a session, so the
same memory does not interrupt twice.

### Manifest
The compiled form of every declared trigger in the store, rebuilt when the store changes and
read on each match. Compiling once is what makes matching cheap enough to run on every
command.

### Prefilter
A deliberately widened projection of the manifest into a form a plain line-oriented matcher
can evaluate, used only to reject. It may answer "maybe" when the truth is no — that costs
time — but must never answer "no" when the truth is yes, because a rejection happens before
anything that could report it. When any pattern cannot be projected safely, no prefilter is
written at all rather than a narrower one.

## Activation

### Activation
How reachable a memory currently is, raised by using it and decaying with disuse. It orders
the index, so use restores a memory to the loaded tier and neglect lets it fall out.

### Hot tier / Cold tier
Hot memories are the ones the index currently carries; cold ones are everything else. Cold
is not deleted and not lost — the body is on disk and still reachable by recall — it is
simply not preloaded. A cold memory returns to hot when its activation rises.

### Retirement
Deleting a memory because it is *wrong* — contradicted by a newer one, or a duplicate
absorbed into a stronger entry. Capacity is never a reason to delete; that is what the
hot/cold split is for.

## Flagged ambiguities

- "Recall" had been used both for the layered lookup and for the automatic surfacing that
  follows a trigger match — these are distinct: the latter is a Nudge.
