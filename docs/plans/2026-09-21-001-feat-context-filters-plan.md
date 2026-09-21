# Context cascades down the herdr session; work hangs off it

Date: 2026-09-21 · Plugin: `work` · Branch: `feature/work-context-filters` (on `main`)

## Problem

Identity flows the wrong way. Today everything is derived from the directory the pane happens to be in: the path signal finds a worktree, the worktree names an issue, the issue names a project, the project names a team. Stand anywhere else — a fresh tab, `~`, a second repo — and every one of those is empty. A session cannot say what it is for, and "bind this session to the Product team" has nowhere to be recorded.

It should flow down. A herdr session says which team is being worked as. A space inside it says which project. A tab says which issue. The worktree is what gets made from that, not what defines it.

## The model

Three levels, each narrowing the one above, in the shape of a Linear view:

| Level | Carries | Identified by |
|---|---|---|
| herdr session (the server, holding the spaces) | team | the session's socket path |
| space | project, and the view already bound to it | `workspace_id` |
| tab | issue | `tab_id`, via the worktree binding that already exists |

**A level may only narrow.** A space cannot name a project outside its session's team; a tab cannot name an issue outside its space's project. This is the whole invariant, and it is what makes the cascade predictable.

**Reads are filtered, not forbidden; writes are contained.** Listing issues, projects or views inside a session shows that team's, and a read that reaches outside it is answered and labelled as outside. A write — filing an issue, recording a binding, making a worktree — is refused outside the resolved context, naming what would have to change. Cross-team reading is ordinary; cross-team writing is the accident this exists to stop.

**One resolver, one guard.** Every read path consults one function that resolves session → space → tab into a single filter, and one that answers whether a given team, project or issue is inside it. Scattering either is how this rots.

## Why now

The repository for a piece of work is already recorded per project-and-team pair (#91). So a resolved context of one team plus one project names exactly one repository — which means the expected working directory is derivable, with nothing to ask. That was not true a week ago.

## Changes

### 1. A session identity (`lib/herdr-read.sh`)

`herdr_linear::session_id` — derived from the herdr socket path, the way the board derives a session name from it, sanitised into a safe identifier. Every other level already has an id.

### 2. Context records (`lib/context-filter.sh`, new)

One record per level in the existing store, beside `scopes/`:

- `contexts/session-<id>.json` → `{"team_id", "team_key"}`
- `contexts/space-<id>.json` → `{"project_id"}` (the view stays where it is, on the workspace record)
- the tab's issue is the worktree binding that exists today; no new record

Written through the plugin's propose/confirm pair, like every other record, so nothing is recorded without a person answering. Refuse a write that widens: a project whose team is not the session's team, an issue whose project is not the space's project.

### 3. The resolver (`lib/context-filter.sh`)

`herdr_linear::context` prints the effective filter — team, project, issue, and which level each came from, so a caller can say where a value was decided. `herdr_linear::context_allows <kind> <id>` answers the guard question. Absent levels are absent, not empty: a session with no team filters nothing, which is today's behaviour and stays the default.

### 4. Verbs that read it

- `/work:new` files into the session's team instead of deriving one from a project that may not exist.
- `/work:start` resolves the repository from the context's project and team, and skips the question the pair already answers.
- The candidate list in `/work:bind` is filtered by the context rather than by the branch name alone.
- A new verb declares a session's team and a space's project **without requiring a worktree** — the missing thing that started this.

### 5. Expected working directory

`herdr_linear::expected_cwd` resolves what the pane's directory should be: the bound issue's worktree, else the repository recorded for the project-and-team pair, else nothing. The path check stops refusing and starts correcting: it names where the work belongs. It states and offers; it never relocates on its own, because standing somewhere else on purpose is legitimate.

## Out of scope

- Any change to herdr itself. The session, space and tab ids all exist today.
- The board's Linear mode, beyond reading the same records if it wants them later.
- Sharing a context between machines; the store is local, as it is now.

## Open questions

- Does a space inherit its session's team, or restate it? Inheriting is less to keep in sync; restating survives a space moving between sessions.
- What happens when a session's team changes under spaces already bound to another team's projects: refuse the change, or mark those spaces as outside it and keep them readable?
- Is a filter ever set per pane, or is the tab the leaf? The tab is the leaf until something needs otherwise.

## Verification

- A session with a team, a space with a project of another team: the space write is refused and names the conflict.
- A tab bound to an issue outside its space's project: refused the same way.
- A read of another team's issue inside a filtered session: answered, and labelled outside.
- `/work:new` in a session with a team and no project files into that team.
- `/work:start` in a resolved context asks no repository question, and the one it would have asked is answered by the pair record.
- `expected_cwd` in a fresh tab of a bound space names the recorded repository; in a tab bound to an issue, that issue's worktree; in neither, nothing.
- A session with no context behaves exactly as the plugin does today.

## Done when

A person opens a session, says "this is Product", and every space, tab and pane inside it files, lists and builds inside Product without being told again — while a worktree remains one checkout of one issue, and nothing is written outside the context that was declared.
