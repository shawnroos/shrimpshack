---
title: "Repo-scoped memory with walk-up-the-tree recall"
status: requirements
date: 2026-06-26
type: feat
related:
  - docs/plans/2026-06-26-001-fix-pin-auto-memory-directory-plan.md
  - docs/plans/2026-06-26-002-feat-consolidate-scattered-memory-stores-plan.md
---

# Repo-scoped memory with walk-up-the-tree recall

## Problem

A memory tied to a repo is highly relevant *when you're in that repo* but
low-signal everywhere else. In a single flat memory pool, that repo memory
competes against the entire store on every recall — so when you're actually in
the repo and it *is* relevant, it can be buried by higher-scoring but
less-relevant noise. The user named this directly: **signal loss for
repo/worktree-tied memories.**

Two extremes have both been lived and both fail:
- **Native per-repo silos** (Claude Code's default — each git repo gets its own
  memory directory): protects repo signal, but a global preference learned in one
  repo is invisible in all others, and the silos *are* the scatter we just cleaned
  up (plan 001/002).
- **One flat global pool** (plan 001's pin consolidated everything into the
  canonical store): no scatter, recallable everywhere — but every repo memory now
  competes against the whole pool, which is the deluge/signal-loss risk.

Neither is right. We want repo memories protected in their own context **and**
global memories available everywhere, on the single consolidated store (no
scatter), with the capability driven by **tools**, not just a passive hook.

## Actors

- **A1 — The agent (Claude).** Saves memories (auto-tagged by where they're born),
  receives scoped recall at session start, actively recalls a repo's memories
  mid-session via a tool, and re-scopes mis-tagged memories.
- **A2 — The operator (Shawn).** Inspects and manages scoped memory via CLI, saves
  with an explicit scope, and promotes/demotes memories between scopes.

## Goals & Success Criteria

- In a repo session, **that repo's memories reliably surface** in recall, even when
  global memories score higher on the prompt (signal protected).
- **Global / cross-cutting memories still surface in every repo** — never hidden.
- **Nothing is trapped:** a memory at a broader scope is an ancestor of every
  narrower context, so it always remains eligible as you walk up the tree.
- The **280 archived repo memories are recovered** and protected in their own repos
  again, instead of lost.
- The agent **and** operator can drive scoping through **tools** (recall, save,
  re-scope, list) — agent-native parity, not hook-only behavior.

## Requirements

- **R1 — Scope = birth path, auto-detected.** Every memory carries a scope equal to
  the directory it was born in, auto-detected from cwd at save (git repo root;
  worktrees fold to the parent repo). No agent "is this global?" judgment at save
  time — provenance is recorded, not classified.
- **R2 — Recall walks up the tree.** Recall starts at the current repo (deepest,
  most specific) and walks up toward `~/`; the current repo's memories get protected
  priority, broader scopes fill in behind, closer scope ranks higher.
- **R3 — The canonical store is the global node.** The existing canonical store
  (`-Users-shawnroos`, the `~/` slug) is the top-of-tree / global scope — an
  ancestor of every repo under it. "Global" is not a special case, it's the root of
  the walk.
- **R4 — No signal loss in either direction.** Repo memories are protected when
  in-repo (the core ask); global memories are always eligible (they're ancestors),
  so a broadly-useful memory is never hidden by scoping.
- **R5 — One physical store; scope is a property.** Scope is metadata, not a
  separate directory per repo. The plan-001 pin stays; this must not re-introduce
  per-repo scatter.
- **R6 — Tool coverage (agent-callable + CLI).** First-class primitives for all of:
  (a) **active scoped recall** — query this repo's memories on demand, walking up
  the tree, beyond the passive session-start injection; (b) **save with explicit
  scope** — pin a memory to a chosen scope, overriding the cwd default; (c)
  **promote / demote (re-scope)** — move a memory between scopes (the escape hatch
  that makes auto-tag-at-birth safe); (d) **inspect / list by scope** — see what's
  stored for a repo or globally.
- **R7 — Re-import the archived corpus, tagged.** Restore the 280 archived memories
  (`~/.claude/projects/_archived-memory/`), each tagged with its origin repo's
  scope, after a light triage to drop obvious cruft, as the seed corpus.
- **R8 — Repo granularity only.** Worktrees fold to their parent repo; no
  worktree-level scope, no expiry/promotion lifecycle.

## Key Flows

- **F1 — Save (auto-scoped).** Agent saves a memory while in repo X → auto-tagged
  `scope: repo:X` (birth path). Saved outside any repo (home dir) → global (`~/`).
- **F2 — Recall (walk up the tree).** Session starts in repo X → recall surfaces
  X's memories (protected) plus ancestor scopes up to global, closest-first.
- **F3 — Active recall.** Mid-session, the agent calls the recall tool to pull this
  repo's memories on demand (not just the session-start injection).
- **F4 — Re-scope.** A memory tagged `repo:X` turns out cross-cutting → agent or
  operator promotes it to global; it now surfaces everywhere. (Demote is the
  inverse.)
- **F5 — Re-import.** The archived store for repo X is triaged, re-tagged
  `scope: repo:X`, and returned to the store — surfacing again when in X, protected.

## Acceptance Examples

- **AE1 (R2, R4 / F2).** Working in `slate-web-app`, a Slate-specific convention
  memory appears in recall even when global memories score higher on the prompt.
- **AE2 (R3, R4).** A global preference ("prefer rebase over merge") surfaces in
  *every* repo session, because it sits at the `~/` ancestor node.
- **AE3 (R6 / F4).** A memory auto-tagged `repo:slate-web-app` that's actually a
  general preference → operator runs the promote tool → it now surfaces everywhere.
- **AE4 (R7 / F5).** After re-import, `slate-web-app`'s recovered memories surface
  when in Slate and stay quiet when in `ai-editor-backend`.
- **AE5 (R6 / F3).** The agent calls the recall tool during a repo session and gets
  that repo's memories ranked above ancestor-scope memories.

## Key Decisions & Rationale

- **Hierarchical, path-anchored scope over flat repo-vs-global** — mirrors how
  Claude Code already loads `CLAUDE.md` (walk up the dir tree, closest wins) and
  makes "global" just the top node, so the model needs no special-casing and
  supports intermediate levels later (e.g. an all-Slate-repos node) without forcing
  them now. (User: "walk up the tree.")
- **Auto-tag by birth path, no classify-at-save** — avoids forcing a fragile
  repo-vs-global judgment on every save; the re-scope tool (R6c) corrects the rare
  mis-tag. (User: "work backwards from the current repo.")
- **Repo-level only** — worktrees are ephemeral; folding them to the parent repo
  avoids expiry/promotion lifecycle and matches native worktree grouping. (User
  selected repo-level over worktree granularity.)
- **Tools are a requirement, not a detail** — agent-native parity, and the re-scope
  tool is what makes auto-tagging safe. (User: "we need to cover this with tools.")
- **Re-import the archived 280 tagged** — they're the exact repo-tied memories
  currently fully lost; re-importing tagged recovers them *with* protection rather
  than back into a flat pool. Ties directly to the stated problem.

## Scope Boundaries

**In scope:** the scope property + auto-tagging, walk-up-the-tree recall, the four
tools (recall / save-scoped / re-scope / list), and the tagged re-import of the
archived corpus.

### Deferred for later
- **Intermediate scope nodes** (e.g. a shared `~/projects/Slate` node spanning all
  Slate-* repos) — the tree-walk supports them; defining them is a later opt-in.
- **Whether injected context visually labels scope levels** ("## This repo" vs
  "## General") — a recall-presentation refinement.
- **Curated pointer promotion** into `MEMORY.md` — orthogonal index concern.

### Outside this product's identity
- **Worktree-level scope** — deliberately rejected (R8).
- **Deleting the archive** — re-import reads it; deletion stays a separate manual
  call.
- **Changing or removing the plan-001 pin** — the single store is foundational here.
- **Per-memory global classification at save** — replaced by birth-path tagging +
  re-scope tool.

## Dependencies & Assumptions

- The plan-001 `autoMemoryDirectory` pin is in place (single canonical store).
- qmd indexes the store by `**/*.md` glob; **scope must be a frontmatter field**
  readable at recall (assumption to confirm in planning — the memory files use flat
  and nested `metadata:` frontmatter; a top-level `scope:` / `origin_repo:` field
  is the natural carrier).
- `hooks/seeded-recall.sh` can be extended to read scope and rank by the
  current-repo walk within its ~6s wall budget. Plan 002's review established the
  relevant feasibility (resolving the current repo from git root, normalizing
  worktrees to parent, reading frontmatter via the `qmd get` the hook already does,
  and bounded multi-pass search) — this builds on that groundwork.
- Current-repo resolution reuses the worktree→parent normalization worked out in
  plan 002.

## Open Questions (for planning)

- **Recall mechanism** for "protected priority": reserved slots for current-repo
  memories vs. a ranking boost vs. a per-scope search that's merged — the user
  explicitly left this to planning ("whatever the mechanism").
- **Physical representation of scope:** a `scope:` frontmatter field on the single
  flat store (ancestor-match at recall) vs. per-scope subdirs/collections (plan
  002's two-collection idea generalized to the tree). Flat-store-plus-field is
  likely simpler; planning should weigh it against recall performance.
- **Triage bar** for the re-import (what counts as "obvious cruft").
- **Tool delivery surface:** a `reflect` CLI the agent calls via Bash vs. MCP tools
  vs. both — guided by the user's "prefer CLI over MCP" default.
- **Migration/relationship to plan 002:** this supersedes plan 002's flat-pool
  consolidation analysis (which correctly concluded archive-and-forget *for a flat
  pool*); the archive step already ran, and this re-imports tagged. Planning should
  fold in plan 002's verified mechanism findings rather than re-deriving them.
