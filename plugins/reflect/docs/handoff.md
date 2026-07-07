# Spinoff: make the memory-index budget self-heal (stop the MEMORY.md nag for good)

> This handoff is directional — author intent and a starting point, enough to orient and begin, not a spec to execute literally. The code and tests are the source of truth: validate against them and expect to refine.

> **Directional handoff.** Intent + grounding, not a spec. Diagnosis below is
> verified, but the "resolves-itself" architecture has real forks — brainstorm them,
> don't just implement the first option. Validate against the reflect code.

## Goal
Make the auto-memory index (`MEMORY.md`) budget **self-managing and silent** so Shawn
is never again interrupted by "compact MEMORY.md" warnings. The system should keep the
index under the load limit automatically — prune/tighten on its own — and the nag
should simply stop happening because the index never gets big enough to trigger it.

## Shawn's two questions, answered up front
- **"Is this even a real issue?"** *Yes.* As of 2026-06-27 the index is **25,096
  bytes / 152 lines** — already **past the native ~24.4 KB read limit**. Claude Code
  auto-loads `MEMORY.md` and **silently truncates** past the cutoff, so the
  lowest-listed memories are at risk of dropping out of recall. The hard cap is real;
  losing the tail is the actual cost.
- **"It should resolve itself."** *Agreed — that's the whole point of this workstream.*
  Reflect already has the passes for it (Pass 4 prune, Pass 6 index-tighten) but they
  can't currently keep up / run safely (see blockers). The fix is to make budget
  management automatic and safe, not to nag the user.

## Key facts established (verified 2026-06-27)
- **The nag is NATIVE, not reflect.** The warning ("…approaching the 24.4 KB read
  limit. Compact it to under 17.1 KB now…") appears in **no plugin, hook, or settings
  file** — grep came up empty across `~/.claude/plugins`, `~/.claude/hooks`,
  `settings.json`, `~/.cc-cmux`, and the reflect repo. It's emitted by the Claude Code
  binary's memory system. **Implication: we cannot mute it from a plugin**
  (cf. memory `native-commands-live-in-the-binary-not-just-plugin-dirs` — verify by
  grepping the binary). The ONLY lever is keeping the index small enough that it never
  fires.
- **Prune is currently neutered.** Reflect's deterministic prune (Pass 4) would shrink
  the index, but the memory dir `~/.claude/projects/-Users-shawnroos/memory/` is
  **git-UNTRACKED** (`~/.claude` is a git repo but the memory files aren't tracked), so
  deletions aren't recoverable. Earlier this session the prune was deliberately skipped
  for safety — which is why the index keeps growing and the nag keeps returning.
- **17.1 KB is unreachable by tightening alone.** With ~150 entries, the per-line
  scaffold (`- [title](file.md) — hook`) alone exceeds the target; you can't hit 17 KB
  without either removing entries (needs safe prune) or shortening
  titles/filenames (renames break QMD parity). Tightening hooks already happened this
  session and only bought ~4 KB.
- **Reflect repo:** `~/projects/reflect`, `main` in sync with origin (`cb20c1d`) —
  branch off current HEAD.
- **Adjacent in-flight work:** `feature/memory-path-pin` (spun off earlier today, same
  reflect repo) fixes WHERE memories get written (canonical store). This budget work is
  the sibling "how big does the loaded index get" problem — coordinate / may want to
  land in sequence.

## Open questions / the "resolves-itself" architecture (the real design work)
1. **Unblock safe prune — git-track vs recoverable trash?**
   - (a) `git init` the memory dir (or track it within `~/.claude`) → prune deletions
     become recoverable + you get full history/undo of every memory edit. Strongest.
   - (b) A `.trash/` move-instead-of-delete with TTL → recoverable without git.
   Pick one so Pass 4 can actually run.
2. **Two-tier index (the durable "never nags again" answer).** Only HOT pointers
   (pinned + recently-used N) live in the auto-loaded `MEMORY.md`; the long tail lives
   in QMD only (still searchable via seeded-recall, just not auto-loaded). This caps
   the auto-load size **regardless of total memory count** — the structural fix.
   Inclusion rule for "hot"? (pin:true + last_used within X days + cap at K lines?)
3. **Cadence — does reflect run often enough to self-heal before the native nag?**
   Reflect triggers on PR/ExitPlanMode/TodoWrite-done. Budget can blow past those
   boundaries (this session did). Consider a lightweight save-time tighten/prune so the
   index self-heals right after each save.
4. **Prune signal quality.** ~25 entries match the 90/30 rule but mostly because
   `last_used` is ABSENT (use-tracking is inconsistently written), NOT because they're
   stale. Fix use-tracking and/or prune by age-only — don't nuke valuable-but-never-
   cited memories. (This bit us this session.)
5. **Raise/retune the lint budget** (`scripts/memory-index-lint.sh`, currently 25600 /
   200 lines) to match whatever the real native cutoff is, and make `/reflect` enforce
   it automatically rather than surfacing it.

## Starting point
- Reflect repo `~/projects/reflect` (branch from `main` `cb20c1d`):
  `skills/reflect/SKILL.md` (Pass 4 prune, Pass 6 index-tighten — the self-heal
  passes), `scripts/memory-index-lint.sh` (budget enforcement), `scripts/migrate-
  memory-index.py`, `.claude/hooks/hooks.json` (trigger cadence),
  `hooks/seeded-recall.sh` (how the tail is recalled from QMD — relevant to two-tier).
- Live data: `~/.claude/projects/-Users-shawnroos/memory/` — 152 entries, `MEMORY.md`
  25 KB, untracked. This is the thing to make self-healing.
- Confirm the native nag's exact threshold by grepping the claude binary (per the
  native-commands memory) so the lint budget matches reality.

## Recommended next step
`/ce-brainstorm` — the intent is unambiguous (self-healing, no nag) but the
architecture has genuine forks (git-track vs trash for safe prune; two-tier hot/cold
index; self-heal cadence). Brainstorm the shape, then `/ce-plan`. The fastest path to
"stop the bleeding" is option 1(a) git-track + let Pass 4 prune run; the durable path
is the two-tier index (2). Per global CLAUDE.md, offer post-brainstorm handoff choices
rather than auto-writing a requirements doc.

## Source session
Transcript: `/Users/shawnroos/.claude/projects/-Users-shawnroos/dde8ee69-bcee-40bd-a003-27e56020f197.jsonl`
Resume:     `cd /Users/shawnroos && claude -r dde8ee69-bcee-40bd-a003-27e56020f197`
