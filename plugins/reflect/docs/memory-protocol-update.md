# U6 — Memory Protocol update for `~/.claude/CLAUDE.md`

This is the source artifact for U6. The "## Memory Protocol" section is in the live
user-global `~/.claude/CLAUDE.md`, which is **outside this worktree's git tree**, so
it is delivered here as a reviewable artifact rather than edited out-of-band from an
unmerged branch.

**Applied automatically** by `scripts/apply-memory-protocol.sh` (invoked from
`scripts/setup.sh` / reflect Pass 0) on the first reflect after merge — it replaces
the existing "## Memory Protocol" section with the version below, idempotently and
with a backup. No manual step. (If `~/.claude/CLAUDE.md` has an ambiguous structure
— zero or multiple "## Memory Protocol" headings — the script skips and leaves it for
manual application.)

The change documents the QMD-backed pointer-index discipline so the save convention
stays correct. Memory **types** are unchanged.

---

## Memory Protocol

**Save aggressively.** After any correction (explicit or implicit), non-obvious
confirmation, preference revealed in passing, or external-system fact that wasn't
already in code — save a memory. Default to saving. Memory is cheap; missing context
is expensive.

**The index is a pointer index, kept under budget.** `MEMORY.md` is the only memory
artifact auto-loaded each session, and Claude Code truncates it at ~25 KB **and**
~200 lines — anything past the cutoff is silently dropped. So `MEMORY.md` holds
exactly **one concise line per memory**: `- [Title](file.md) — ≤1-line hook`. The
verbose detail does **not** go in the index — it lives in the memory's body file,
where QMD indexes and searches it. `scripts/memory-index-lint.sh` enforces the budget;
`/reflect` Pass 6 tightens the index if it drifts over.

**Saving = body file + pointer line.** Write the memory's body as its own `.md` file
in the memory dir (with the standard frontmatter), then add one pointer line to
`MEMORY.md`. Put the recall-worthy detail in the body, not the index hook.

**QMD is the recall layer.** Full bodies are retrieved through QMD search, not by
loading them all into context. `/reflect` re-embeds the `claude-memory` collection
each pass (collection-scoped `qmd embed -c claude-memory`) so memories saved this
session are findable next session. A `UserPromptSubmit` seeded-recall hook surfaces
the few most relevant bodies on the first prompt of a session. When QMD is
unavailable, the index pointer is a working file path — read the body directly.

**Recall mid-session, not only at session start.** Run `/memories <topic>` — or, in a
subagent that can't invoke a command, the reflect plugin's one recall call
(`scripts/scoped-memory/reflect_cli.py recall --query "<what you are up against>"`,
plus `--here` to scope it to this repo). It returns bodies and names which layer
answered. Reach for it when a **successful** command returns a surprising or thin
result, before touching an **unfamiliar external system**, after an action is
**denied** or a tool behaves unexpectedly, and before **re-deriving anything that
smells previously solved**.

**Reinforce on overlap.** Before saving, search `MEMORY.md` for an existing entry on
the same topic. If found, update and extend it instead of creating a duplicate.
Overlapping saves are signal — they mean the rule is real and recurring.

**Track use — `applied` only.** When you **apply** a memory in reasoning, append one
line to `~/.claude/projects/-Users-shawnroos/memory/MEMORY_USE.log`:
`<timestamp> <memory-name> applied [session:<id>] [note]` — use `[session:unknown]`
when you don't know the session id, never a guess. On reinforced memories, also
update `last_used:` in the frontmatter. `applied` is the **only** token you write:
`written` (saved) and `reflect` (batch timestamp bump) are machine records, and only
`applied` raises a memory's activation, so logging a mere save would let a memory
reinforce itself for having been written down. Surfacing events (what recall showed
you) go to `RECALL.log`, written by machines — never log those here.

**Consolidate via /reflect.** Eager save during work; bulk synthesis at completion
boundaries. `/reflect` does the housekeeping pass — update timestamps, merge overlaps,
surface stale entries, keep the index under budget, capture durable docs, and re-embed
the QMD collections.

**Memory types:** `user`, `feedback`, `project`, `reference`, `idea` — unchanged.

**Capture ideas via `/idea`.** Unchanged.
