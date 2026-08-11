---
name: reflect
description: Silent memory hygiene and session consolidation. Reviews memories saved during this session, updates timestamps for memories used, merges overlapping entries, auto-prunes stale ones via deterministic rules, captures learnings. Auto-triggers on PR open/merge, ExitPlanMode, and TodoWrite all-done. Operates without user involvement — logs to REFLECT.log only. Run manually with `/reflect` (silent) or `/reflect verbose` (prints full output).
---

# /reflect — Silent session consolidation

## The output contract — two visible units, and nothing else

This is the first rule, because it is the one most often broken. A reflect run shows the
user **exactly two things**:

```
⏺ Reflecting on <subject matter>
```

…then the work happens out of sight, then **one** closing summary. Nothing in between.

- `<subject matter>` names what this run is consolidating, in the user's terms — what the
  session was about ("the grep prefilter work", "the WEB-2845 detector fix"), not the
  machinery ("passes 1-10", "17 memories").
- **Do the work in ONE batched call, or dispatch it to a background agent.** Ten passes is
  not ten visible tool calls. A pass that needs several shell steps needs one script, not
  one call per step.
- **Never narrate the passes.** No "now updating timestamps", no "checking merge
  candidates", no per-pass tallies on screen, no thinking-out-loud between steps. The
  REFLECT.log line is the record; the closing summary is the report.
- **The closing summary is short**: what changed, plus anything that genuinely needs the
  human — the three exception conditions below. Never a pass-by-pass transcript.

The measured failure this exists to prevent (2026-08-11): a `/reflect` run produced ~25
narrated tool calls with commentary between each. The user's correction: *"there's a lot of
the agent talking through what it's doing instead of using the tool then providing a single
response."* Memory work is plumbing for the actual task — narrating it displaces the thing
the user is trying to follow, and the volume buries the one line that matters (an exception,
a halted cleanup) instead of surfacing it.

`/reflect verbose` is the ONLY mode that prints the pass-by-pass detail.

---

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

Drive it with `scripts/scoped-memory/reflect_cli.py`: `recall`, `save
--scope <repo:.|repo:slug|global>`, `promote`/`rescope` (the move-between-scopes
escape hatch for a mis-scoped memory), and `list [--here|--scope]`. The shared
`scope.py` (resolver + qmd-path scope match + `select_scoped`) is the single source
of truth the hook and tools both use. The archived per-repo stores are restored
tagged via `scripts/scoped-memory/reimport.py`; go-forward native writes are
scoped best-effort by `scripts/scoped-memory/backfill.py` (run from `setup.sh`).

## Mid-session recall — one call, and when to make it

```
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/scoped-memory/reflect_cli.py recall \
  --query "<what you are up against>" [--here] [--deliberate] [--cwd D] [--store D]
```

The query can also be a bare positional argument. That one call runs the whole
layered path itself — declared triggers, then `qmd vsearch`, then the local BM25
index when qmd was skipped, wedged, or empty — returns **bodies**, and always ends
with a status line naming which layer answered. `--here` scopes to this repo (its own
memories plus ancestors and globals, never a sibling repo's) and says so when you are
not in a repo. `--deliberate` widens K and relaxes the local confidence gate; use it
when a human explicitly asked. It exits 0 even on no match — read the output, not the
exit code. A wedged qmd is named in the status line, never silently skipped.

**When to make the call mid-session** — the measured misses all had one of these tells:

- a **successful** command returned a surprising or thin result (nothing errored, but
  the output doesn't explain what you're seeing);
- you're about to touch an **unfamiliar external system** — a CLI, a service, another
  team's repo;
- an action was **denied**, or a tool behaved in a way you didn't expect;
- you're about to **re-derive something that smells previously solved**.

`/memories <topic>` is the same call made deliberately on a named topic, with the
recording and trigger-proposing steps around it. `/reflect-regroup` is its no-argument
counterpart: a human invokes it mid-task, and it stops first.

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
- Append one line per **applied** memory to `MEMORY_USE.log` in the memory dir: `<timestamp> <memory-name> applied [session:<id>] [trigger]` — `[session:unknown]` when the session id isn't known, never a guess. `applied` is the only token you write here: `written` (saved) and `reflect` (batch timestamp bump) are machine records, and only `applied` raises activation, so logging a mere save would let a memory reinforce itself for having been written down. Surfacing events belong in `RECALL.log`, not here.
- Memories where the session revealed nuance or contradiction: edit content to incorporate it (this counts as reinforcement — touch the file's mtime)
- Corrections that emerged but aren't yet memories: save now as `feedback_*.md`

This use-tracking is the activation signal: `last_used` and `MEMORY_USE.log` count feed the render's ranking (Pass 6), so using a cold memory bumps it back toward the hot tier. Recording use here is what makes accessibility self-reversing. An **absent** `last_used` means "unknown", not "never used" — the activation function seeds it at a neutral value, so a valuable-but-never-cited memory is never sunk purely for missing telemetry.

**Declare a trigger where the situation is machine-recognizable.** For each memory saved or reinforced this session, ask: is there a *concrete signal* that says "you are in this situation right now" — a command shape (`gh pr view --json`), an error string (`mergeable=CONFLICTING`), a tool or file name? If yes, add a `triggers:` block to its frontmatter:

```yaml
triggers:
  - regex: gh\s+pr\s+view\b
  - literal: statusCheckRollup
  - regex: mergeable\s*=\s*CONFLICTING
```

Every entry is typed — `literal:` (matched verbatim) or `regex:` (Python `re`, case-insensitive, unanchored). A bare untyped string is rejected, never guessed at.

A `literal:` matches as a contiguous substring, so write it as one only when the words really are adjacent: `literal: gh pr view --json` does **not** fire on `gh pr view 29 --json`, because the PR number sits between. For a command shape with arguments in the middle, use a `regex:` with `\s+`, or a `literal:` on the one distinctive token (a flag, a subcommand, an error string).

**Skip it when the situation isn't machine-recognizable, and never force one.** A memory with no declared trigger is served by ranked search — that is the design, not debt. A vague trigger is worse than none: it fires on unrelated work, gets ignored, and teaches the agent to ignore the next one too.

**Trigger lifecycle check** — run the report, then act on it with judgment:

```
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/scoped-memory/triggers.py report
```

- **Backfill candidates** — memories with 2+ distinct application days, plus the pinned and hot-index tier (~200 in the live store). Work a few per reflect, not all at once: read the body, and declare a trigger only where the situation is crisply recognizable. Memories outside this list are deliberately not backfilled — a big-bang pass over everything manufactures low-conviction triggers that decay into noise.
- **Never-acted-on triggers** — a trigger that fired 3+ times with zero same-session applications. Prune it or sharpen it. Firing without ever helping is the failure mode this field has; leaving it is how the whole mechanism becomes noise.

**Write triggers into an existing memory with the tool, never by hand:**

```
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/scoped-memory/triggers.py add \
  --memory feedback_gh_conflicting_blocks_ci_silently.md \
  --regex 'gh\s+pr\s+view\b' --regex 'mergeable\s*=\s*CONFLICTING'
```

It validates each pattern before writing, refuses to clobber an existing block without `--replace`, recompiles the manifest, and **preserves the file's mtime**. That last part is why hand-editing is wrong: activation reads mtime as "last reinforcement", so hand-editing 200 files would spike 200 activations, reshuffle the index's hot/cold cut and lower those memories' recall floors — surfacing them more for no reason but the write. The same rule holds for any future bulk frontmatter edit.

Tally: `updated=N saved=M triggers_declared=T triggers_pruned=P`.

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

### 5. Compound pass — always fires when there is a repo

**Run `/ce-compound`. The only skip is mechanical: there is no git repo to write into.**

- If the session cwd is inside a git repo → **run `/ce-compound`, every time, unconditionally.**
- If it is not (bare `~`, a scratch dir) → skip; `docs/solutions/` has no home. Tally `compounded=0` and move on.

Do **not** gate this on your own judgment of whether a learning "counts." That gate was the
previous wording ("did any technical learnings emerge… skip if the session was meta-work")
and it fired **3 times in 148 runs** — the judgment call collapsed to "no" almost always,
so solution docs never accumulated. `/ce-compound` is itself the thing that decides what is
worth writing; reflect's job is to *invoke* it, not to pre-screen for it. An invocation that
finds nothing worth recording is cheap and correct. A skipped invocation is a silent loss.

Meta-work is **not** a skip reason. Plugin, harness, and tooling work done inside a repo is
project-scoped technical work like any other, and its learnings belong in that repo's
`docs/solutions/`.

Tally: `compounded=N` (count invocations that produced or updated a doc; a run that found
nothing is still a run — note it as `compounded=0`, not as a skip).

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

Append one line to `<memory-dir>/REFLECT.log`. The field set is extended additively with `index_tightened=`, `captured=`, `embedded=`, and Pass 2's `triggers_declared=` / `triggers_pruned=` (any REFLECT.log parser must be updated for the new fields):

```
<ISO8601 timestamp> <trigger> updated=N saved=M merged=K retired=L compounded=C index_tightened=I captured=X embedded=Y worktrees_removed=W triggers_declared=T triggers_pruned=P
```

The two trigger fields go last so every existing positional reader keeps working. `triggers_declared` counts memories given a `triggers:` block this pass — authored at save time or backfilled — and `triggers_pruned` counts never-acted-on triggers removed or sharpened. Both are `0` on a pass that declared none, which is a normal and expected outcome, not a skip.

Examples:
```
2026-05-08T18:42:13-07:00 manual updated=2 saved=0 merged=0 retired=1 compounded=0 index_tightened=1 captured=0 embedded=1 worktrees_removed=0 triggers_declared=0 triggers_pruned=0
2026-05-08T19:15:00-07:00 PR_event updated=0 saved=1 merged=0 retired=0 compounded=1 index_tightened=0 captured=2 embedded=2 worktrees_removed=2 triggers_declared=1 triggers_pruned=0
```

In verbose mode (`/reflect verbose`): also print the full pass-by-pass summary to screen, ending with the log line.

In silent mode (the default): the log line is written to `REFLECT.log`, and the screen gets
the two units from **The output contract** at the top of this file — the `⏺ Reflecting on
<subject matter>` line, then one closing summary. The passes themselves never appear.

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
