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
| space | project, and the view already bound to it | session id + `workspace_id` |
| tab | issue | the worktree binding, with the tab recorded on it |

**A level may only narrow.** A space may bind a project that spans several teams, as long as the session's team is one of them — Linear projects do span teams, and the plugin already says so (`project_teams`, `no_team_reason`). An issue is inside the context when its project is the space's project **and**, when a session team is declared, its team is that team. Both halves are needed: without the second, a Web issue inside a Web-and-Product project passes the guard in a Product session.

**Reads are filtered, not forbidden; writes are contained.** Listing issues, projects or views inside a session shows that team's, and a read that reaches outside it is answered and labelled as outside. A record write — a space's project, a tab's issue, a worktree — is refused outside the resolved context, naming what would have to change. Cross-team reading is ordinary; cross-team recording is the accident this exists to stop.

**Filing outside the context is allowed, and the surface says so.** A person in a Product session who names the Web team and confirms files that issue into Web; no worktree and no binding are recorded, so nothing outside the context is committed to. What makes it safe is that it is visible: the surface holding work its context does not cover is titled `UNBOUND: <title>` — the pane, the tab or the space, whichever the plugin owns the title of. The prefix clears when the surface is bound to what it is working on: the state is legible from the surface, not from a record somebody has to query.

It marks a surface holding work the context does not cover — not an empty one. A fresh tab holds no work at all, and nothing in the plugin observes a tab a person opened by hand; branding every such tab would need a sweep over surfaces that are none of this plugin's business, and a warning that appears everywhere is one people stop reading.

**The intended shape is one herdr session per team.** A session that hosts several teams' work leaves its team undeclared and gets space- and tab-level filtering only. Working as another team means attaching a different session, not re-pointing this one — which is what makes the settled decision below affordable.

**One resolver, one guard.** Every read path consults one function that resolves session → space → tab into a single filter, and one that answers whether a given team, project or issue is inside it. `herdr_linear::current_context` (`lib/context.sh`), which resolves worktree → issue → project → team today, becomes the fallback the resolver calls when no level is declared; its callers in `lib/create.sh` move onto the new resolver. Two resolvers with different answers is the failure this must avoid.

## Why now

The repository for a piece of work is recorded per project-and-team pair (#91). A resolved context of one team and one project names that pair record, which answers the repository whenever it holds exactly one path — several remains the question it is today.

## Changes

Ordering: **5 ships first** (the space half of the declare verb, on the record that already exists), because it is the motion that is missing today. The session level, the resolver and `expected_cwd` follow.

### 1. Space records are keyed by session and space

`workspaces/<id>.json` is keyed by the workspace id alone, and herdr workspace ids are per server: two sessions on this machine each hold a space called `w1`, verified live. Two spaces in two sessions therefore share one project binding, one view and one state **today**, before any of this plan. Key the record `workspaces/<session-id>/<workspace-id>.json`, and migrate an existing flat record into the session that holds that id, else leave it readable in place.

This is a bug fix the rest of the plan depends on: inheritance makes a shared space record resolve to whichever session read it last.

### 2. A session identity (`lib/herdr-read.sh`)

`herdr_linear::session_id` reads `HERDR_SOCKET_PATH`, which herdr exports into every pane:

| Socket | Id |
|---|---|
| `…/sessions/<name>/herdr.sock` | `<name>`, through `is_safe_identifier` |
| `<herdr config dir>/herdr.sock` | the literal `default` |
| unset | no session level; nothing is filtered |

The board's own derivation answers nothing for the default socket, which is the session most work happens in — copying it unchanged would ship a feature that only works in named sessions.

### 3. The session record (`lib/context-filter.sh`, new)

`contexts/session-<id>.json`, written through `propose`/`confirm` the way a workspace record is: binding-shaped, the team id where a workspace record carries its project id, the team key in a display field. That gives the record the `unbound` / `proposed` / `bound` / `misplaced` states the settled decision below needs, with no new machinery. The bare `{team_id, team_key}` shape the pair cannot write is gone.

The space level is the existing workspace record — no second file for a value it already holds. `workspace_confirm` additionally records the project's team ids on it, so the guard and the lazy check compare locally instead of making a Linear call per read.

The tab's issue is the worktree binding. `/work:bind` records the current tab on it (`binding_set_tab`), which only `lib/herdr-write.sh` does today, so a hand-opened tab has no tab-to-issue link at all.

### 4. The resolver and the guard (`lib/context-filter.sh`)

`herdr_linear::context` prints the effective filter — team, project, issue, and which level each came from. `herdr_linear::context_allows <kind> <id>` answers the guard question, including the two-part issue test above. Absent levels are absent, not empty: a session with no team filters nothing, which is today's behaviour and stays the default.

### 5. Verbs that read it

- **The declare verb** sets a space's project, and a session's team, **without requiring a worktree** — the missing motion that started this.
- `/work:new` files into the session's team when one is declared; otherwise today's derivation from the space's project stands (its single team, or a question when it spans several).
- `/work:start` resolves the repository from the context's project and team, skipping the question whenever the pair record holds one path.
- `/work:bind`'s candidate list is filtered by the context, using the same two-part test.

### 6. The UNBOUND surface prefix

One place decides the prefix and one place spells it, so a title cannot drift from the record: a surface whose work its context does not cover is titled `UNBOUND: <title>`, and the prefix is removed when it is bound. `_tab_label` applies it to a tab the plugin creates; `retitle_tab` applies or clears it on a tab that already exists, through `herdr tab rename`, reading the current title back first so a failed read cannot invent a prefix. It fires on the four transitions that change the answer: a binding recorded `misplaced`, that state clearing, a tab bound to its issue, and a filing outside the context, which titles the tab the person is sitting in. Best-effort, like every other herdr mutation here.

### 7. Expected working directory

`herdr_linear::expected_cwd` resolves what the pane's directory should be: the bound issue's worktree — found from the pane's own directory first, else from the binding whose recorded tab matches this tab — else the repository the project-and-team pair names, else nothing. The path check stops refusing and starts correcting. It states and offers; it never relocates on its own, because standing somewhere else on purpose is legitimate.

## Out of scope

- Any change to herdr itself. The session, space and tab ids all exist today.
- The board's Linear mode, beyond reading the same records if it wants them later.
- Sharing a context between machines; the store is local, as it is now.

## Settled decisions

**A space inherits its session's team; it does not restate it.** (user-directed, over each level holding its own copy — one value in one place, and a space that moves between sessions takes the new session's team rather than carrying a stale one.)

**A binding that contradicts its parent is broken, and broken is a state to resolve, not to live in.** (user-directed, over marking it outside the filter and keeping it readable — a half-true binding makes it impossible to know what is what.) An **attended** run stops and offers exactly two ways forward:

1. **Re-point it** — a project of the session's team, an issue of the space's project.
2. **Unbind it** — the space's record returns to `unbound`, the worktree's binding is cleared.

Cancelling the change that caused the conflict stays available. Proceeding with the contradiction recorded does not.

An **unattended** read has nobody to ask — `hooks/ground.sh` fails open and never prompts, `hooks/reconcile.sh` never prompts, subagents have no question tool. There the check records the existing `misplaced` state on the affected record and suspends writes, exactly as `check_placement` already does for a tab-versus-space contradiction; the grounding hook surfaces it the way it surfaces `misplaced` today, and the next attended verb offers the two ways forward. `context_allows` becomes the one comparison behind both, so a single contradiction has a single detector.

## Settled: filing outside the context

**Filing a Linear issue outside the context is allowed when the person names the target and confirms; the surface carries an `UNBOUND:` title prefix while it holds work its context does not cover.** (user-directed, over refusing the write and making the person attach another session — the deliberate case needs a path that touches no other record, and the accidental case is caught by the prefix being visible rather than by a refusal.) A record write stays refused outside the context.

## Settled: consent stays per worktree

**Declaring a session's team does not grant write consent; the per-worktree fence stands.** (user-approved, over a declared team counting as consent for that team — the session answers "who am I working as" and consent answers "may I write here", and keeping them separate holds the blast radius of a wrong answer to one directory.) `consent_covers` is unchanged, and a new worktree asks once, as it does today.

## Open question

- Is a filter ever set per pane, or is the tab the leaf? The tab is the leaf until something needs otherwise.

## Verification

- A pane in the **default** session declares a team, and `herdr_linear::context` reports it.
- Two sessions each holding a space with the same workspace id resolve to their own project and team; an existing flat record still reads.
- A session with a team, a space whose project has no such team: the write is refused and names the conflict.
- A space bound to a project spanning two teams, in a session that is one of them: allowed. An issue of the other team in that project: outside the context.
- Changing a session's team under a bound space stops and offers re-point or unbind; unbind leaves the space `unbound` and its view cleared; cancel leaves every record as it was.
- A `SessionStart` in a tab whose issue fell outside its space's project exits 0, records `misplaced`, and shows the suspension.
- A read of another team's issue inside a filtered session: answered, and labelled outside.
- `/work:new` in a Product session naming the Web team files into Web, records no worktree and no binding, and leaves the surface titled `UNBOUND: …`; the same run without naming a team files into Product and changes no title.
- A tab standing in no worktree carries the `UNBOUND:` prefix; binding it to its issue clears the prefix.
- `/work:new` with a declared team files into it; with no declared team and a space bound to a single-team project, it files into that project's team, as today.
- `/work:start` asks no repository question when the pair record holds one repository; several stays the question it is today.
- `/work:bind`'s candidates in a filtered session exclude another team's issues.
- `expected_cwd`: in a fresh tab of a bound space, the repository the pair names; in a tab bound to an issue, that issue's worktree; in neither, nothing.
- A session with no context behaves exactly as the plugin does today.

## Done when

A person opens a session, says "this is Product", and every space, tab and pane inside it files, lists and builds inside Product **without deriving the team again** — while a worktree remains one checkout of one issue, and no record is written outside the context that was declared. The write-consent question still asks once per worktree and branch, as it does today.
