---
date: 2026-06-23
topic: reflect-qmd-store
---

# Reflect as a QMD-backed memory + document store

## Summary

Grow `/reflect` from a silent memory-hygiene pass into the engine for a QMD-backed
memory + document store. `MEMORY.md` drops to a thin, always-loaded pointer index;
full memory bodies stay as git-tracked files on disk that QMD indexes and a
session-start hook surfaces on demand; and reflect copies durable documents
(brainstorms, handoffs, `docs/solutions/`) into a central store before merged
worktrees are cleaned up.

## Problem Frame

The index-in-context model has stopped scaling. `MEMORY.md` is the only memory
artifact loaded into context each session, and it has grown to ~55KB — past the
~24KB load limit — so its tail is silently dropped and anything below the cutoff
is invisible to the agent. Today's reflect pass enforces no size budget, so the
file only grows.

Two deeper gaps sit behind that bug. First, recall is all-or-nothing: the whole
index loads or nothing does, with no way to hold full bodies out of context while
keeping them retrievable. Second, the documents agentic coding generates — plans,
brainstorms, handoffs like the one that spawned this work, `docs/solutions/` —
are scattered across repos and worktrees and forgotten. Many are authored inside
worktrees that get removed after their PR merges, so the artifact disappears with
the worktree.

QMD already sits on the memory directory plus ~25k other markdown docs and offers
lexical + semantic search. It is the natural backing store: lean on search instead
of cramming everything into one loaded file. The current state needs attention
though — the index is ~25 days stale with ~24.8k docs pending embedding, and the
memory collections are not yet populated. Freshness has to be designed in, not
assumed.

## Key Decisions

- **QMD is the source of truth; files on disk are the durable copy.** Memory
  bodies and captured docs live as git-tracked `.md` files; QMD indexes them for
  retrieval. Nothing exists only inside QMD's index, so a stale or unavailable
  QMD degrades recall but never loses anything.

- **Tiered recall over pure on-demand.** Keeping memory proactive matters more
  than the leanest possible mechanism. The thin index always loads (the "what
  exists" surface), a session-start step injects the few most-relevant full
  bodies, and the agent searches QMD for the rest. Pure on-demand was rejected
  because a memory the agent never thinks to look up goes unused.

- **Centralize durable docs over index-in-place.** Reflect copies durable docs
  into a central store rather than pointing QMD at scattered in-place dirs. The
  copy step is the cost; surviving worktree cleanup is the gain. Index-in-place
  was rejected because worktree-authored docs would vanish at merge.

- **Reflect owns the write side; a session-start hook owns the read side.** All
  capture, embedding, and index hygiene happen inside the reflect pass ("when
  reflect runs, this happens"). Proactive recall injection necessarily fires at
  session start, not reflect time, so it is a separate hook — the one place the
  mechanism splits across two triggers.

- **The size budget is solved structurally, not by compaction rules.** Because
  the index holds one line per memory, it stays under budget by construction. The
  handoff's deterministic-vs-model-driven compaction question largely dissolves —
  there is no longer a body of prose fighting to fit.

## Requirements

**Memory index and recall**

- R1. `MEMORY.md` is a thin pointer index — one line per memory (title +
  one-line description + a pointer to its file) — and stays under the session
  load budget by construction.
- R2. Full memory bodies remain individual git-tracked `.md` files on disk that
  QMD indexes. No memory body exists only inside QMD's index.
- R3. At session start the full thin index loads, and a hook runs a QMD search
  seeded by session context (branch, handoff doc, opening prompt) and injects the
  top-K most relevant full bodies into context.
- R4. Mid-session the agent can retrieve any memory body on demand via QMD search,
  or by reading the file its index pointer names when QMD is unavailable.

**Document store**

- R5. Reflect captures durable docs (brainstorms, handoffs, `docs/solutions/`) by
  copying them into a central store at `doc-store/` under the `~/.claude` root,
  which QMD indexes. The store is type-segmented — `doc-store/{brainstorms,handoffs,solutions,…}/` —
  one subdirectory per doc-type.
- R5a. Each doc-type subdirectory is its own QMD collection (`claude-brainstorms`,
  `claude-handoffs`, …), so search can scope to a single doc-type. The collections
  are defined **programmatically** by an idempotent reconciler that derives one
  collection per doc-type directory under the store (plus the memory collection),
  ensures each exists in QMD's config, and keeps it embedded. New doc-types
  auto-register with no manual `index.yml` editing.
- R6. Capture runs during the reflect pass and before reflect's worktree-cleanup
  step removes a merged worktree, so worktree-authored durable docs are preserved.
- R7. Ephemeral / working docs are not captured; they remain in place and age out
  with their worktree.
- R8. Reflect classifies durable vs ephemeral at its own discretion using the
  heuristic — brainstorms, handoffs, and `docs/solutions/` are durable; scratch
  plans, working notes, and review logs are ephemeral. No author marker is
  required or read.

**Reflect engine and freshness**

- R9. At the end of each pass, reflect re-embeds the memory and doc-store QMD
  collections — scoped to those collections, not the global corpus — so memories
  saved and docs captured this session are findable next session.
- R10. QMD staleness or unavailability degrades recall (slower, less semantic) but
  never loses a memory or document; the file-on-disk copies are authoritative.
- R11. The existing `MEMORY.md` and the ~132 current memory files are migrated
  into the new shape: index rewritten to pointer form, bodies confirmed present as
  files, and the memory collection embedded.

## Key Flows

- F1. Session-start recall (read side)
  - **Trigger:** A new session starts.
  - **Steps:** Thin index loads in full → a hook builds a QMD query from session
    context → top-K relevant full bodies are injected → agent proceeds with the
    "what exists" surface plus the most relevant bodies.
  - **Covered by:** R1, R3, R4

- F2. Memory save and index update
  - **Trigger:** A memory is saved or reinforced during work.
  - **Steps:** Body written as a file on disk → a one-line pointer entry added to
    or updated in the index → reflect later re-embeds the memory collection so the
    new body is searchable next session.
  - **Covered by:** R1, R2, R9

- F3. Durable doc capture before worktree cleanup (write side)
  - **Trigger:** Reflect runs and a durable doc exists, possibly inside a worktree
    slated for cleanup.
  - **Steps:** Reflect classifies the doc → copies durable ones into the central
    store → embeds the doc-store collection → only then runs worktree cleanup.
  - **Covered by:** R5, R6, R7, R8

## Acceptance Examples

- AE1. **Covers R4, R10.** QMD is unavailable mid-session. The agent still reads a
  needed memory body directly from the file its index pointer names. No memory is
  reported missing.
- AE2. **Covers R5, R6.** A brainstorm doc authored in a worktree whose PR just
  merged is copied into the central store during the reflect pass, and is still
  searchable after the worktree is removed.
- AE3. **Covers R7, R8.** A scratch working note in the same worktree is not
  copied; it disappears with the worktree and is never indexed.
- AE4. **Covers R3, R9.** A memory saved this session is surfaced by seeded
  auto-recall in the next session because reflect embedded the memory collection at
  the end of the prior pass.

## Scope Boundaries

- Ephemeral and working docs are not captured — only durable docs enter the store.
- QMD's global embedding backlog (~24.8k pending docs) is left alone; only the
  memory and doc-store collections are kept fresh.
- QMD itself is not re-architected; this work consumes the existing CLI and
  collection model.
- The memory-type taxonomy and save protocol in `CLAUDE.md` are unchanged in
  intent — only the index's shape (full entries → pointers) and the storage/recall
  mechanism change.

## Dependencies / Assumptions

- The `qmd` CLI is available and is the integration surface, preferred over the
  MCP server (the MCP server dropped mid-session in the source work; the CLI did
  not).
- Memory bodies and captured docs are git-tracked, so capture and migration are
  reversible.

**Verified during planning (research corrections to brainstorm premises):**

- **QMD does not currently index the Claude memory dir.** The existing `memory-dir`/
  `memory-root` QMD collections point at `~/.openclaw/workspace`, not
  `~/.claude/projects/-Users-shawnroos/memory/`. "QMD already sits on the memory dir"
  was wrong — the plan must create new, correctly-pointed Claude-owned collections
  (memory + per-doc-type) and leave the openclaw collections untouched.
- **`MEMORY.md` is already a pointer index**, not full bodies — `## heading` +
  `- See [file.md] — hook` per entry. It is ~55KB because each hook is multi-sentence.
  So R1 is *tightening* entries to fit the budget and relocating the verbose hooks into
  QMD-searchable bodies, not redesigning the format. This is only safe because seeded
  recall (R3) backfills the recall signal the shortened hooks lose.
- **`MEMORY.md` loading and its ~25KB / 200-line truncation are Claude Code built-ins**,
  not user-controllable. The auto-memory block is injected before any hook fires and
  cannot be enlarged. Keeping the index small is the only lever. Seeded auto-recall
  (R3) must inject bodies via a hook's added-context channel, not by altering the
  built-in load.
- **Recall-injection point (default decision):** a `UserPromptSubmit` hook firing
  once per session (guarded by a session flag), seeded by the first prompt plus git
  branch. `SessionStart` cannot see the user's prompt and the built-in auto-memory
  load cannot be hooked, so `UserPromptSubmit` is the richest available seed.
- **QMD embedding is manual** (`qmd embed -c <collection>`); there is no watch/daemon.
  Reflect running scoped `qmd embed -c <collection>` per pass is the freshness
  mechanism (R9); `-c` scoping avoids touching the ~24.8k-doc global backlog.
- **Dev-loop caveat:** the live `/reflect` loads from the real `~/.claude/skills/`,
  not this worktree, so the edited skill only goes live after merge to `main`. The
  new reflect behavior cannot be exercised by running `/reflect` inside this
  worktree; plan validation accordingly.

## Outstanding Questions

**Deferred to planning**

- The exact pointer scheme in the index (R1): file path vs QMD docid vs both.
- Top-K size and the precise seeding inputs for the session-start query (R3).
- The doc-store collection configuration and directory layout under `doc-store/`
  (R5).
- The session-start hook's injection mechanism (R3) — how bodies are placed into
  context.
- Migration sequencing for the existing index and ~132 files (R11).

## Sources / Research

- `skills/reflect/SKILL.md` — the current silent 7-pass reflect skill (no size
  budget, no QMD touchpoint today).
- `CLAUDE.md` "Memory Protocol" — memory types, save/reinforce/reflect rules,
  `MEMORY_USE.log` tracking.
- `projects/-Users-shawnroos/memory/MEMORY.md` — the loaded index, currently ~55KB
  (the load-cutoff bug); ~132 files in the memory directory.
- `qmd status` findings — global index ~25 days stale, ~24.8k docs pending embed,
  memory collections not yet populated. Confirms freshness must be designed in.
- `docs/handoff.md` — the spinoff brief that framed the three threads and the
  decisions already made.
