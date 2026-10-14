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

## Spawn teams

### Cause
Why a member of a team run did not succeed, composed only of facts the plugin itself
established — the supervisor's own account, the child's exit code, and the reasons it
recorded for degrading. It is written into the run record, so it outlives the member's
worktree and the job record that worktree held. The model's own narrative is not part of
it; that is the child's text, not the plugin's finding.

### Attempt
One retired try at a member's work: the round it ran in, the job it ran as, the outcome it
reached and the cause it carried. A member accumulates attempts; nothing a retry replaces
is discarded.

### Rotation
Retiring a member's current try into its attempt history and returning the member to the
roster. It is one write, not a sequence, because a reader that catches it half-applied sees
a member that is neither finished nor retryable.

## Herdr and Linear

### Binding
The link between one git worktree and one Linear issue. The herdr board holds it, against
the worktree, never against a pane or tab, so rearranging the layout does not lose it. An
agent links it through the board's `bind` tool, or the person links it on the board.

### Unbound
A worktree with no binding. It is a supported state, not an error — work often starts before
the issue exists — and nothing requires an issue to be created for it.

### Misplaced
A bound worktree whose herdr workspace does not correspond to its issue's Linear project.
The board does not compute this state yet; when it does, it reports it and never picks which
side was wrong.

### Stale
A binding whose issue has been closed in Linear while the worktree is still in use. The board
does not compute this state yet; when it does, it reports it and leaves it alone, never
reopening an issue on its own.

### Mapping
What a herdr space, tab and pane each correspond to. The current meanings — a space is a
project, a tab is a piece of work, a pane is a session — are one mapping among possible
ones, not the only one.

### Scheme
A named way of composing one kind of name — a worktree, branch or tab. The set
of schemes is fixed and each is rendered by the plugin, so a name is chosen from an
enumeration rather than written as a template.

## Peek

### Reader page
Peek's text rendering of a remote item or web page: its title, details and readable body,
fetched once and refreshed, with no scripts running. It is the default way any link opens.

### Live view
The real web page, rendered by a browser engine outside the pane and drawn into the pane as
a stream of pictures, with scrolling, clicks and typing sent back to it. It replaces the
reader page only while the person asks for it, and holds site data in memory only.

Typing reaches the page only while a click has put focus on an editable field; a
navigation or leaving live view returns the keys to peek.

### Group
A titled, described set of items of any type (files, links, tasks), optionally split
into sections, that the agent makes for the person and that lasts across sessions of one
project. The agent creates and edits it; the person stars it and adds or removes items.
An item the person removed stays removed until the agent forces it back, whatever the
group's rule says.

A group may carry a **rule**: props every member must equal, joined by "and". Rule
members are worked out from the current tasks each time the group is read and are never
stored, so the group fills and empties as props change. A group may also carry a
**split**: one prop whose values divide its members into sections. Status sections are
the split by status.

### Frame budget
The cap on how many bytes of pictures live view sends into the pane each second. The pane
path stalls above a measured rate without telling the sender, so the cap is fixed ahead of
time and enforced where frames are made: unchanged pages send nothing, and a busy page gives
up frame rate first and picture size second to stay under it.

### View definition
One markdown file that defines how one kind of item is drawn: its frontmatter declares
the type's name, which items it matches, and their props and required-prop rules; its
body is the page's template of markdown, placeholders and blocks. It holds no loops,
expressions or code, so it runs nothing. Peek's own definitions ship with the plugin; the
person's and agents' live in one user-level folder. Two definitions with the same type
name are both refused rather than one overriding the other.

### Layout block
A fenced block in markdown whose language starts with `peek-`. A collection block
selects items by their props and draws them as cards, a list, a tree, sections, a board
or focus; a record block draws one part of a remote page's record. Collection blocks
draw on markdown file pages, in group descriptions and on the Tasks page; record blocks
draw only on remote pages. The person can switch a collection block's layout in place,
and peek remembers it for that block.

### Task
A markdown doc with a status that the person or an agent tracks in peek: a captured
to-do, a deliverable, a mirrored agent item, or a takeover doc. The person's own tasks
live in one tasks folder per repo, in the main checkout, shared by every worktree, or in
one user-level folder outside any repo. Its creator is recorded by peek, never taken
from the agent.

### Deliverable
A doc anywhere in a repo that is a task because its frontmatter says `isTask: true`. It
stays where it is, is read only from the session's own worktree, and must carry every
task prop; a missing one flags it rather than hiding it.

### Status
A task's state: `todo`, `doing`, `done` or `cancelled`. Every change, from the pane, a
tool, mirroring or a hand edit, goes through one path that writes the doc and one
change-log entry outside the repo, and does nothing when the status already matches.
Status is never inferred from code, branches or pull requests.

### Agent list (mirrored)
One agent session's own task list, as Claude Code keeps it, followed by peek and copied
into peek-owned records the first time each item is seen. The records outlive Claude
Code's files, belong to the repo the session ran in, and form one rule group per list.
A list counts as over when every item is closed, its session ended or it was cleared;
an over list leaves Recent, and its group is removed some hours later.

### Takeover
The task doc peek writes in the list's repo when the person or an agent changes a
mirrored item, or the person adopts one. It keeps the agent session as creator and
points back to the item, so the agent's later updates still reach it; the latest change
wins. Peek never writes Claude Code's own task files.
