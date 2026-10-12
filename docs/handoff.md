# Spinoff: Peek view builder skill

> This handoff is directional — author intent and a starting point, not a spec.
> The code and tests are the source of truth; validate against them and refine.

## Goal
A skill, shipped with code, that lets an agent design and build new peek views (new screens or page types in the peek side pane) from the building blocks peek already has, so a new view is composed from proven pieces instead of hand-written into a 3,800-line `register.tsx`.

## Why now / context
Peek grew fast over the last few sessions: remote pages (Linear, GitHub, web via Defuddle), a live WebKit view, media embeds, a Groups tab + group page + expandable group cards, and (on a separate branch) Slack thread pages. Each one re-did the same work by hand: a new `Mode` or `View` kind, card grids, row lists, the hover layer, ⌃k entries, status line, test world. The patterns are now stable enough to name and reuse. Shawn wants an agent to be able to say "build a view for X" and get it right using those primitives.

## Key decisions already made
- Base is `feature/peek-groups` (65ffb80 + whatever lands after) — it has every primitive; `main` has none of PRs #99/#100/groups.
- Engine rule: the engine handle `$` cannot be passed across an import (`claude plugin validate` rejects it), so modules take io ports (`remoteIoOf`, `liveIoOf`, `groupsIoOf`). Any reusable view code must follow this.
- Engine rule: the engine refuses UI state writes while a render hook draws — handler data lives in module variables, state changes only in key/message handlers.
- Comments are why-only. Test-first with observed red and mutation checks is the house standard.
- An Image tree is capped at 2 MiB per pane render; pictures are converted to 800 px and budgeted (`IMAGE_TREE_BUDGET`).
- A peek plugin can call MCP tools via `$.mcp.call(server, tool, args)` (found on the Slack branch) — views can source data from MCP servers.
- Footer is status text + accent `⌃k menu` only; every action must be reachable via ⌃k and a key (hidden `footer-keys` Buttons).

## Open questions / not yet decided
- What "the primitives" are, exactly: inventory candidates — `cardGrid`/`groupCards`, `rowList`/rows.tsx, hover-layer.tsx (pointer overlay with payloads), tabs.tsx header chips, `header()`/crumbs, `rule()` section headers, `menuFor`/⌃k `commands`, status/footer, `mediaBlock`/`markdownChunks`/`fitsPane`, remote page DETAILS/MESSAGE/COMMENTS blocks, refresh cache + `tickRemote`, the Mode/MODES/View plumbing, the pane test world in tests/*.test.ts.
- Skill shape: a pure-prose SKILL.md that teaches the recipe, vs. a SKILL.md plus a small extraction of reusable view modules (a "view kit") the skill tells the agent to compose, vs. a scaffold generator script. Shawn said "a skill with code" — so likely some real reusable code, not just prose.
- How much refactoring of `register.tsx` this requires first (code review already flagged it: 2,821 → 3,774 lines; groups logic should move behind `GroupsIo`).
- Where the skill lives: inside `plugins/peek/skills/` (can a mod plugin carry a skill? the groups skill+hook follow-up plan has the same open question) or as a standalone skill.
- How the agent verifies a view it built: pane tests via `claude-code/testing` `$.ui.mount`, plus a live look after `/reload-plugins` (live copy at `~/.claude/mods/peek`, synced by rsync).

## Starting point
- `plugins/peek/hooks/register.tsx` — everything; search `Mode`, `MODES`, `cardGrid`, `groupCards`, `rowList`, `header(`, `footer`, `menuFor`, `commands`, `frame(`.
- `plugins/peek/hooks/{rows,grid,tabs,hover-layer,theme,lib,groups,remote,refresh,sources}.ts(x)`.
- `plugins/peek/tests/{pane,groups-pane,remote-pane,media-pane}.test.ts` — the test world patterns.
- `plugins/peek/.claude-plugin/types/claude-code/index.d.ts` — engine API (authoritative; gitignored, copy from the main checkout if missing).
- Plans: `docs/plans/2026-10-12-1002-feat-peek-groups-plan.md`, `docs/plans/2026-10-09-1605-feat-peek-live-browser-plan.md`, `docs/plans/2026-10-08-2153-feat-peek-remote-pages-plan.md`.
- `CONCEPTS.md` (Peek section), `plugins/peek/README.md`.
- Related in-flight work (don't collide): `feature/peek-groups` is still being finished (expandable group cards + PR) in the main checkout; `feature/peek-slack-threads` worktree adds Slack pages; a groups skill + end-of-work hook plan is pending.

## Recommended next step
`/ce-brainstorm` — the scope (prose skill vs. view kit vs. generator, and how much of `register.tsx` to extract first) is genuinely open and is a product/shape call Shawn should weigh in on before planning.

## Source session
Transcript: `/Users/shawnroos/.claude/projects/-Users-shawnroos-projects-herdr-linear-board-worktrees-tui-design/04b1befa-7bf3-4e11-8a58-129666ae59b4.jsonl`
Resume:     `cd /Users/shawnroos/projects/herdr-linear-board/worktrees/tui-design && claude -r 04b1befa-7bf3-4e11-8a58-129666ae59b4`
