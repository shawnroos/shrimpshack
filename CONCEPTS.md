---
editors: claude
---

# Concepts

Shared domain vocabulary for this project — entities, named processes, and status concepts
with project-specific meaning. Seeded with core domain vocabulary, then accretes as
ce-compound and ce-compound-refresh process learnings; direct edits are fine. Glossary
only, not a spec or catch-all.

Memory, recall and retro vocabulary moved to the reflect repo (`shawnroos/reflect`, CONCEPTS.md).

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

## Programme

### Programme
An Otto run in which a PM coordinates work under an accepted agreement and checked stop rules.
Its persistent home sits outside disposable code worktrees.

### Recovery packet
A revision-bound view of a Programme's retained agreement, decisions, requirements, actions, and results.
It restores context without creating approval authority.

### Archive
A read-only retained Programme record whose preservation and resource-release checks have passed.
Archival does not mean every requirement passed or authorize deletion.

### Successor
A new Programme linked to an archived Programme.
It needs its own accepted agreement and does not reopen the archive.

### Promotion
The one-way move of a Programme's home from plain files to its durable store.
After promotion the store is the only source of truth and the files are exports rebuilt from it.
A writer that chose the plain-file path before promotion must check again under the lock before it writes.
A Ruling change never lands on the plain-file path: once its checks pass there, it promotes the home and runs again in the store, and refuses, changing nothing, when promotion cannot run.
Prompts carried across the move approve nothing new, but what they approved on the plain-file home stays in force.

### Foreign write
A change found in a promoted Programme's exports that the store did not make.
Appended rows are absorbed into the store as a record of what happened, but they never count as approval; rewritten files are set aside.

### Agreement
What is specific to one Programme, in two sections: Scope and Rulings. Only the human's own
typed messages change it. Authority and Done standards are not part of it; every Programme
reads them live from the protocol.

### Scope
The agreement section that says what a Programme covers: the remit, when the PM may stop,
cadence and budget, the sources watched (tools of record) and the preferred tools.

### Preferred tool
A Scope entry naming an existing skill or tool to prefer for a kind of job, with the evidence
it came from. It is a preference, not a permission: it grants no access and never says who
decides.

### Ruling
One of the human's dated, scoped orders or decisions: their words, a decision kind, an effect
(decided, grant or restrict), the items it applies to, its limits, until when, and its revision
history. It binds only when a prompt the human typed accepts it, and a revision that gives the
PM more needs a new typed prompt naming what it adds. A casual typed correction ("that didn't
need me") is a Ruling that applies at once.

### Authority
The protocol's one table of who decides each decision kind and at what level (act, act and
tell, propose, never), across the plugin, personal and project layers. It is the standing
answer; a Ruling may widen or narrow it for named items until its end date.

### Protected kind
A decision kind fixed in code as the human's: production deploys, releases, spend over the cap,
merging around a gate and refused permissions. Neither Authority nor a Ruling can hand one to
the PM.

### Done standards
The protocol rules that say, for each kind of change, the required deliverables and evidence
bar. They carry no level; who decides is Authority's job.

### Accepted marker
The mark written when the human accepts a Programme's agreement. Until it exists, product calls
stay with the human; it gates nothing else.

### Decision log
The flat list of choices made while a Programme runs (`log-decision`, answered asks, the accepted agreement):
who decided, the decision kind, and the Ruling or preferred tool it cited, or that it was silent. It is a
record of calls made, not a Ruling, and it approves nothing.

### Carry-over store
A per-machine file that keeps the Rulings the human picks at a Programme's end, so the next
Programme on the same project starts with them pending until the human names their items.

It is a cache, not the record. The approval row journaled when the human picks the Rulings
holds every entry it adopts, and when a new Programme's remit is set, before its agreement is
accepted, the store is refilled from those rows, so an entry a crash lost after its approval row still arrives. A refill never
overwrites a later carry of the same Ruling and never stores an entry twice.

### Permission proposal
A request for the human to apply a narrow native permission that resolves blocked read-only work. It does not grant permission itself. Programme protocol proposals instead concern completion rules and evidence requirements.

### Trajectory
A work item's path as the PM sees it at one sweep: steps done, the current step, the planned
steps and the finish. It belongs to the work item, not the session doing it, and the PM
rewrites it every sweep, so a changed plan is a recorded difference rather than a surprise.

A trajectory records when the PM wrote it, and it fades once it is older than about two
expected sweep gaps. Its age belongs to the moment it is shown, not the moment it was
written: a display must measure it against the current clock, because one that fixes it at
write time freezes exactly when the PM stops sweeping, and shows stalled work as fresh.

### Clause
What a step relies on: a Scope term, a Done standard or an active Ruling. A step with no
clause is allowed and shown as such; it is a warning, never a block.

Instructions, decision records, project terms as a who-decides source, corrections, the
agreement's autonomy term and the contract stamp are retired; the Otto repo's `CONCEPTS.md` (shawnroos/otto)
shows how older records name them.

### Tools of record
The programme-wide set of tools where work and evidence live and that the PM checks each
sweep. It replaces the agreement's "sources" term.

### Behaviour
Standing guidance on how the PM or its workers go about the work: when a situation is
true, what to do and not do, which skills, tools and agents to prefer, how to communicate,
and when to stop. It lives at the personal, repo or programme layer, and the narrower layer
wins. It carries no authority and no done bar; Authority, Done standards and Rulings answer
those. The Otto glossary (`CONCEPTS.md` in shawnroos/otto) holds its full entry.

### Driver pane
The terminal pane the person uses to drive a Programme. Only the person types into it: no
other session may send to it, and no other session may name it in a command, because a
command that names a pane cannot be reliably told from one that types into it. Which pane
this is comes from the live terminal host rather than from a session's own environment,
since a session can inherit a stale pane from whatever started it.

### Send
Any command that could put text or keystrokes into a pane. A send is judged by where each
word sits, never by what follows it: the program being run, a plain argument, and the pane
being targeted are three positions with three different rules. A send whose target cannot
be proven to be some other session's pane is refused.

### Runtime-built command
A command whose program name the shell only resolves as it runs, because the name comes
from a variable, a substitution, a pattern or a path lookup. Such a name is refused by
default, since nothing in the rest of the command reveals what it will run. The single
exception is a name set to a plain literal earlier in the same command, where the shell
could not have reached any other value.

## Peek

Peek moved to its own repo; its vocabulary lives in https://github.com/shawnroos/peek/blob/main/CONCEPTS.md.
