---
title: "feat: port recipes onto the refactored peek and add recipe-backed blocks"
type: feat
status: active
date: 2026-10-14
authors: Claude
project: shrimpshack/peek
topics: [peek, recipes, view definitions, blocks]
---

# Port recipes and add recipe-backed blocks

## Goal

Recipes (PR #106) let an agent add page types for links, which the person approves. They were built before the peek refactor (PR #104) and cannot merge onto the current stack. This work ports recipes onto `feature/peek-markdown-views` (PR #107) and then builds the last unit of the markdown-views plan: a block that draws records from an approved recipe without running it on every draw (R4, U13 in `docs/plans/2026-10-13-1345-feat-peek-markdown-views-plan.md`).

Source of truth for recipe behaviour: PR #106, branch `feature/peek-view-builder` (worktree `worktrees/peek-view-builder`), including its own plan and tests. Port map with file-by-file homes: `/Users/shawnroos/.claude/jobs/04b1befa/tmp/work/recipes-port-map.md`.

## Scope

In: recipe modules, the page vocabulary and its drawing, recipe runs (script and MCP), approval in the pane, draft runs, the opted-in refresh timer, the `open` and `check_recipe` agent tools, the peek-recipes skill and builder agent, recipe-backed blocks.

Out: inline video in the live view (5 commits on PR #106). It is a separate feature and stays on PR #106 / `feature/peek-inline-video` for its own port. Slack, groups and the hoist refactor from PR #106 are already on this stack in another form and are skipped.

## Decisions

- **D1. Port, do not merge.** A trial merge stops on 14 conflicts, and 2 of the files it changes no longer exist. Each recipe change moves to the module that now owns that responsibility (port map §2). Recipe behaviour and every PR #106 test expectation stay the same; only homes, imports and fixtures change.
- **D2. Two block systems stay separate.** The recipe page vocabulary (JSON blocks with inline data) and the `peek-` blocks (items selected by props) share names (cards, list, fields, media) but not data shapes. They share low-level widgets only. CONCEPTS.md names both and how they differ.
- **D3. Types live in `types/recipes.d.ts`** with prefixed names, because PR #106's `Block`, `Section`, `ListItem`, `Picture`, `Action` and `TableBlock` collide with current exports.
- **D4. `$` never crosses an import.** Recipe modules take ports. New port members: `statResolved` (fs.stat with resolve), `envGet`, `toolCheck`, `mcpCall` returning structured content, `storeGet`, `pluginRoot`; `NavIo` gains `recipesIo()` and `runIo()`. Check: no parameter typed `EngineInterface` outside `register.tsx`.
- **D5. Recipe records come from page rows.** A recipe returns a page. A recipe-backed block turns every row with a link in that page's cards, list and table blocks into an item: name from the row title, href from its link, props `recipe` (the recipe id) and `section` (its section title). Rows with no link are skipped. No new recipe output kind.
- **D6. The block names its recipe and link.** Fence: `peek-<layout> recipe=<id> url=<link>` plus the usual rule options. `url` is required: a recipe always runs against a link. `match: { recipe }` in a definition stays reserved and matches nothing (README already says so).
- **D7. A cache filled only by allowed runs.** Key: recipe id + link. Value: recipe digest, records, fetched time. Stored under peek's state folder (`~/.local/share/claude-peek/recipe-cache/`), capped. Written when a recipe page run succeeds (open, refresh, opted-in timer) and when `check_recipe` runs one. Never written by a draw.
- **D8. Blocks never run recipes.** A block draws cached records with a dim "fetched … ago" line. With no cache, or a cache from another recipe digest, it draws one "Open to load" row whose Enter opens the link, which routes to the recipe page, which runs it once (in-flight dedupe) and fills the cache. A recipe that is a draft or missing draws one error row naming it. So R4's triggers are exactly the recipe page's own.

## Units

| Unit | What | Depends on | Files (primary) |
|---|---|---|---|
| P1 | Pure recipe modules, types, pure tests | — | `hooks/recipes/*` (page, recipes, run), `types/recipes.d.ts`, `format.ts`/`net.ts` helpers, tests page/recipes/recipe-run |
| P2 | Ports | P1 | `hooks/ports.ts`, `navigation.ts` (NavIo), `register.tsx` wiring |
| P3 | Agent tools and the store guard | P2 | `hooks/recipes/tools.ts`, `group-tools.ts` TOOLS table, tests recipe-tools |
| P4 | Session logic and navigation | P2 | `hooks/recipes/session.ts`, `navigation.ts` show/refresh/tick, `refresh.ts` notePageTitle, constants |
| P5 | Drawing: page body, approval panel, view dispatch | P4 | `pane/screens/view/recipe.tsx`, `view/index.tsx`, cursor; tests page-view, recipe-pane, recipe-approval |
| P6 | Skill, builder agent, manifest, docs | P3, P5 | `skills/peek-recipes`, agent, plugin manifest, README, CONCEPTS.md, tests skill-examples, recipe-builder-agent |
| U13 | Recipe-backed blocks and the cache | P4, P5 | `hooks/views/recipe-source.ts`, prose items provider, cache write in the recipe page load, `tests/recipe-source.test.ts` |

Parallel: P3 and P4 after P2 (disjoint files). P6 and U13 after P5.

## Test scenarios

- P1–P6: every PR #106 test passes with unchanged expected values, moved to current paths and fixtures. Tree assertions are re-derived only where the refactored pane draws the same content differently, and each such change is listed in the unit report.
- U13 (from the markdown-views plan, plus D5–D8):
  - Opening a group whose description holds a recipe block does not run the recipe.
  - Opening the block's own page (Enter on "Open to load") runs it once; opening it twice at once still runs once.
  - After that run, the block draws the page's linked rows as items, with "fetched … ago".
  - A block naming a draft recipe draws an error row, not data, and never runs.
  - A cache written under an older recipe digest draws "Open to load", not stale rows.
  - The opted-in timer refreshes the cache while the recipe page is open; nothing refreshes it otherwise.
  - Rows without a link are skipped.

## Verification

From `plugins/peek`, one at a time: `claude plugin test .`, `npx -y -p typescript@5.6 tsc -p .` (read the exit code), `claude plugin validate .`; no `.js` under `hooks/` or `tests/`; the PR page baseline hashes unchanged; no `EngineInterface` parameter outside `register.tsx`. Test-first with observed red and one mutation check per new rule (U13); ported tests pass unchanged (P1–P6). A manual pane check on a real recipe page before the PR is marked ready.
