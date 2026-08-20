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

## Retro

### Retro item
A record of tool friction: a plugin, skill, hook, script or harness behaviour that got in
the way and would get in the way again unchanged. It answers "what should we fix", where a
Memory answers "how should I work". Items live in a dot-directory inside the Store, so
nothing indexes, recalls or triggers on them — they are review-time reading.

### Backlog
Every retro item whose Disposition is still `open`. It is worked down by
`/reflect:reflect-retro`, never filtered by recency: staleness is sort order, because a
recent window would hide the item that has been re-derived most often.

### Disposition
A retro item's state: `open`, `fixed`, `culled`, or `wontfix`. An item leaves the Backlog
only by moving out of `open`, and only with a recorded proof of what closed it.

### Probe
A shell check stored on a retro item that proves the friction is gone. It proves it by
printing a token carrying a nonce generated for that one execution — never by exiting
zero, which on this machine proves nothing. Probes run only inside the manual retro
session, and only after the operator has approved the text.

### Vent pass
The part of a reflect run that asks what got in the way and writes retro items. It writes
nothing when the answer is nothing.

## Flagged ambiguities

- "Recall" had been used both for the layered lookup and for the automatic surfacing that
  follows a trigger match — these are distinct: the latter is a Nudge.
- Retirement and a `culled` Disposition are different acts on different things.
  Retirement deletes a *memory* because it is wrong. Culled records that a *tool* was
  deleted — the retro concluded the thing itself should go. Neither is about capacity.
