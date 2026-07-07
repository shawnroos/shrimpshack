---
name: reflect
description: Silent memory hygiene and session consolidation. Reviews memories saved during this session, updates timestamps for memories used, merges overlapping entries, auto-prunes stale ones via deterministic rules, captures learnings. Auto-triggers on PR open/merge, ExitPlanMode, and TodoWrite all-done. Operates without user involvement — logs to REFLECT.log only. Run manually with `/reflect` (silent) or `/reflect verbose` (prints full output).
---

# /reflect — Silent session consolidation

Reflect operates without user involvement. Output goes to `REFLECT.log` in the canonical memory dir — the `$HOME`-derived store `~/.claude/projects/-Users-<you>/memory/` (e.g. `~/.claude/projects/-Users-shawnroos/memory/`) — as a single line per run. This is one fixed store regardless of which project you're working in: `setup.sh` pins Claude Code's native auto-memory directory there via the `autoMemoryDirectory` setting, so a session started inside a project repo doesn't scatter memories to a git-root-derived per-project store. Only interrupt the user for genuine exception conditions (see end of file).

## Repo-scoped recall (plan 003)

Memories carry a **scope** encoded in their storage path within the one store:
global memories live flat at the root; repo-scoped memories live under
`_scope/<repo-slug>/`. The `seeded-recall` hook resolves the current repo (git
root, worktrees folded to parent), reads each candidate's scope from the qmd
result `file` path (free — no extra fetch), and **adds** the single best
current-repo memory above a relevance floor (`SEEDED_RECALL_REPO_MIN_SCORE`) as an
extra item alongside the usual top-K globals — never displacing a global, and
suppressing other repos' memories. Outside any repo, only globals surface. The
behavior degrades to today's exact recall when the scope module is absent.

Drive it with `scripts/scoped-memory/reflect_cli.py`: `recall --here`, `save
--scope <repo:.|repo:slug|global>`, `promote`/`rescope` (the move-between-scopes
escape hatch for a mis-scoped memory), and `list [--here|--scope]`. The shared
`scope.py` (resolver + qmd-path scope match + `select_scoped`) is the single source
of truth the hook and tools both use. The archived per-repo stores are restored
tagged via `scripts/scoped-memory/reimport.py`; go-forward native writes are
scoped best-effort by `scripts/scoped-memory/backfill.py` (run from `setup.sh`).

Run when:
- The user types `/reflect` or "reflect now" → silent mode
- The user types `/reflect verbose` → print full 10-pass output to screen
- A flag file at `~/.claude/.reflect-pending` exists (auto-trigger from completion hooks). Read it to determine the trigger reason, then delete the flag. Always silent.

## Coalesce window

If `~/.claude/.reflect-pending` was written within the last 10 minutes of the previous reflect run, treat as part of an existing cluster and skip — append a "skipped: coalesced" line to REFLECT.log and exit. The hook script handles timestamp checks; you handle the skip logic by reading the flag content.

## The passes

Run passes 1–10 in order. Skip a pass only if it's genuinely empty (e.g., no new memories saved → skip merge pass). Each pass appends counts to a tally that becomes the REFLECT.log line at the end.

The write-side passes (6 index-budget, 7 capture, 8 reconcile+embed) MUST run before the worktree-cleanup pass (9), so durable docs are copied out of a worktree before it is removed.

> Plugin note: the seeded-recall and reflect-trigger hooks wire automatically from the plugin manifest — nothing here wires hooks. The one-time live edits (migrating an existing `MEMORY.md`, patching the Memory Protocol) are opt-in via the `/reflect-setup` command, not done in this pass.

### 1. Session inventory (internal)
- What was built or changed in this session?
- What corrections did the user give? Were any repeated (same correction twice = memory worth saving)?
- What surprised you — patterns, gotchas, system behaviors that didn't match expectations?

This pass produces an internal mental model only. Never surface to the user except in verbose mode.

### 2. Memory update pass
- Memories applied during this session: update `last_used:` in frontmatter to today's date
- Append one line per used memory to `MEMORY_USE.log` in the memory dir: `<date> <memory-name> [trigger]`
- Memories where the session revealed nuance or contradiction: edit content to incorporate it (this counts as reinforcement — touch the file's mtime)
- Corrections that emerged but aren't yet memories: save now as `feedback_*.md`

This use-tracking is the activation signal: `last_used` and `MEMORY_USE.log` count feed the render's ranking (Pass 6), so using a cold memory bumps it back toward the hot tier. Recording use here is what makes accessibility self-reversing. An **absent** `last_used` means "unknown", not "never used" — the activation function seeds it at a neutral value, so a valuable-but-never-cited memory is never sunk purely for missing telemetry.

Tally: `updated=N saved=M`.

### 3. Memory merge pass
- Scan `MEMORY.md` for entries with overlapping topics (same subject area, similar guidance)
- Merge candidates into the stronger / more general entry; absorb content from the weaker
- Update `MEMORY.md` index to remove merged entries
- Delete the absorbed memory files

Tally: `merged=N`.

### 4. Accessibility & retirement pass — silent, automatic, deterministic

Memories are **not deleted for capacity.** Accessibility decays with disuse and is restored by use, the way memory itself works. The index (Pass 6) is the activation-ranked hot tier; a memory that falls past the budget cut becomes *cold* — it stays on disk and in QMD, reachable by recall, and re-enters the hot tier when its activation rises (use bumps `last_used` / `MEMORY_USE.log` in Pass 2). Nothing is lost. There is no capacity-driven delete, no `.trash/`, no recoverability question. `type: idea` memories follow the same decay as everything else — ideas you don't return to fade; ideas you reinforce stay hot.

Deletion is reserved for **correctness, not capacity:**
- **Contradiction:** if a memory is explicitly contradicted by a newer one (one says "always use X", another "never use X" with a more recent `last_used`), retire the older — prefer the newer.
- **Duplication:** exact or near-duplicates collapse via the merge pass (Pass 3).

Retire by deleting the file — the same way Pass 3 deletes an absorbed memory. A contradicted or duplicate memory is *wrong*, and archiving it inside the store would leave it QMD-indexed and able to resurface in recall, which is exactly what retirement prevents. `pin: true` is never retired. A merely-old, uncontradicted memory is never retired; it fades via activation instead — that is the case the user's "why delete at all?" was about, and the answer is: it isn't deleted, it fades.

Tally: `retired=N`.

### 5. Compound pass
- Did any technical learnings emerge that belong in `docs/solutions/` for the current project?
- If yes and a project context applies, run `/ce-compound` for those
- Skip if the session was meta-work (no project-scoped technical learning)

Tally: `compounded=N`.

### 6. Index render pass — silent, automatic

- Run `${CLAUDE_PLUGIN_ROOT}/scripts/memory-index-render.py` to project `MEMORY.md` as the activation-ranked, budget-truncated hot tier. The highest-activation memories (pinned, plus recently and frequently used) fill the load budget; the rest are cold — on disk and in QMD, omitted from the index. The render is idempotent and never deletes a body.
- Run `${CLAUDE_PLUGIN_ROOT}/scripts/memory-index-lint.sh` to confirm the rendered index is under budget. The binary nags at ~80% of its ~24.4 KB cap; the render targets the ~17.1 KB compact point, so a passing lint guarantees the nag never fires.
- This self-heals silently and caps the auto-load size regardless of total memory count. The render runs every reflect trigger; a save-time render (the memory-write hook) keeps the index honest between triggers.

Tally: `index_tightened=0|1`.

### 7. Document capture pass — silent, automatic

- Classify documents produced this session or sitting in active worktrees. **Durable** (capture): brainstorms (`docs/brainstorms/`), handoffs (`docs/handoff.md` / `*handoff*`), and `docs/solutions/`. **Ephemeral** (leave in place, ages out with its worktree): scratch plans, working notes, review logs. No author marker — this is reflect's judgment by the heuristic.
- Copy each durable doc into the matching central store subdirectory: `~/.claude/doc-store/{brainstorms,handoffs,solutions}/`. Preserve the filename; skip if an identical copy is already present.
- **Ordering is load-bearing:** this runs before Pass 9 (worktree cleanup), so a durable doc authored inside a worktree is copied out before the worktree is removed.

Tally: `captured=N`.

### 8. Reconcile + embed pass — silent, automatic

- Run `${CLAUDE_PLUGIN_ROOT}/scripts/qmd-reconcile-collections.sh` to ensure the Claude-owned QMD collections exist (`claude-memory` for the memory dir + one `claude-<type>` per doc-store subdirectory) and re-embed them with collection-scoped `qmd embed -c <name>`. This makes memories saved and docs captured this session findable next session (seeded recall depends on it).
- Only `claude-`-prefixed collections are touched. The ~24.8k-doc global backlog and foreign collections (openclaw, Slate) are never embedded here.
- **If `qmd` is not installed, this pass is a clean no-op** (the script skips and exits 0). Memory still works: the budgeted pointer index loads, and bodies are read directly via their file pointers — only search-based and seeded recall stay dormant until `qmd` is installed.

Tally: `embedded=N`.

### 9. Work cleanup pass — silent, automatic

- Worktrees whose PR has merged: remove them automatically (apply the conservative-cleanup rule from `feedback_worktrees_automatic.md`)
- **Exception**: if a worktree slated for cleanup has uncommitted changes, halt cleanup for that worktree and surface to the user (this is a true exception — losing work is unrecoverable)
- Background agents still running: list in REFLECT.log, don't kill

Tally: `worktrees_removed=N`.

### 10. Log

Append one line to `<memory-dir>/REFLECT.log`. The field set is extended additively with `index_tightened=`, `captured=`, and `embedded=` (any REFLECT.log parser must be updated for the new fields):

```
<ISO8601 timestamp> <trigger> updated=N saved=M merged=K retired=L compounded=C index_tightened=I captured=X embedded=Y worktrees_removed=W
```

Examples:
```
2026-05-08T18:42:13-07:00 manual updated=2 saved=0 merged=0 retired=1 compounded=0 index_tightened=1 captured=0 embedded=1 worktrees_removed=0
2026-05-08T19:15:00-07:00 PR_event updated=0 saved=1 merged=0 retired=0 compounded=1 index_tightened=0 captured=2 embedded=2 worktrees_removed=2
```

In verbose mode (`/reflect verbose`): also print the full pass-by-pass summary to screen, ending with the log line. In silent mode: only the log line is written; nothing prints to screen unless an exception is raised.

## Exception conditions — when to interrupt the user

Only surface to the user (break silence) for these:

1. **Malformed memory file**: a file in the memory directory can't be parsed (broken frontmatter, missing required fields). Print: "Reflect halted: <file> is malformed. Fix or delete?"
2. **Unresolvable contradiction**: two memories directly contradict and merge logic can't determine which is canonical (e.g., same `last_used` date, same topic, opposite guidance). Print: "Reflect needs your call: <name1> vs <name2> contradict. Which wins?"
3. **Worktree with uncommitted changes**: as in Pass 9. Print: "Worktree <path> has uncommitted changes; skipped cleanup."

Routine pruning, merging, and updates never surface. Trust the rules.

## What /reflect is not

- Not a session recap for the user
- Not a place to do code work — purely memory + meta
- Not a substitute for `/ce-compound` (that's for technical project learnings; reflect is for cross-session preferences and workflow patterns)
- Not interactive — never ask questions, never request confirmations, except for the three exception conditions above
