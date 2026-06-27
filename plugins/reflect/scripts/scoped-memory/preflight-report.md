# U1 pre-flight report — repo-scoped memory (plan 003)

**Date:** 2026-06-27  ·  **Verdict: BUILD** (full, with native-tagging as
best-effort backfill — *not* a real-time hook).

U1 gates U2–U7. It measured the two things the feature's value rests on — the
recall-match **mechanism** and tagging **coverage** — against real data and real
qmd output. Results below; `scripts/scoped-memory/scope.py` is the shared module
U2/U4 import (built + verified here).

## 1. Recall mechanism (the highest risk) — WORKS

The load-bearing F-A question (round-3 catch): does scope parsed from a real qmd
`file` value string-match the resolver's slug? qmd rewrites the path
(`_scope`→`scope`, strips the leading `-`, adds `qmd://<coll>/`), so a naive compare
never fires.

- **F-A: PASS.** `scope_matches("qmd://fa/scope/Users-shawnroos-projects-slate-web-app/conv.md",
  "-Users-shawnroos-projects-slate-web-app") == True` after normalization (drop URI
  prefix, accept `scope`/`_scope`, strip leading `-`/`_` both sides).
- **Resolver: PASS.** From this worktree (`…/worktrees/memory-path-pin`) the resolver
  folds to the **parent repo** `/Users/shawnroos/projects/reflect` →
  `-Users-shawnroos-projects-reflect`, via `git rev-parse --path-format=absolute
  --git-common-dir`. Outside a repo → `global`. Ancestry correct (home ⊃ repo;
  siblings unrelated).
- Cost: scope is read from the `file` field already in the search JSON — **no
  per-candidate `qmd get`** (F6 resolved).

So recall can read and match scope cheaply and correctly. This was the make-or-break
mechanism; it holds.

## 2. Tagging coverage — partial, with a safe floor

- **Re-import of the archived 280 (U6): ~100% taggable** — scope comes from the
  archive **directory name** (`_archived-memory/<slug>/`), no provenance lookup
  needed. This is the bulk of the immediate value and is robust. (265/280 also carry
  `originSessionId`, but U6 doesn't need it.)
- **Go-forward native auto-memory writes: backfill-only.** No native-write hook
  exists (Claude Code exposes no memory-write hook event). Tagging go-forward native
  writes relies on a `/reflect`-pass backfill keyed on `originSessionId` → transcript
  path → cwd-slug.
  - Measured resolution: **67%** (78/116 canonical memories with a parseable
    `originSessionId` resolve via an extant transcript; 33% have pruned transcripts).
  - Many that *do* resolve point at `-Users-shawnroos` (the home/global slug) —
    correct: those memories were saved outside a repo and **should** be global.
  - The session-start cwd ≠ save-time cwd in multi-repo sessions (an approximation),
    and transcript retention bounds it over time.
- **Safe floor:** untagged ⇒ flat/global. A native memory that can't be tagged is
  signal-safe (still recallable everywhere), just not boosted in its repo. The
  feature is never *wrong* for these — only un-boosted.

## 3. Verdict and what it means for U2–U7

**BUILD**, because the two value sources that work *independently of perfect native
coverage* both check out:
- the recall mechanism (U2 resolver / U3 tagging / U4 boost) is proven, and
- the re-import of the 280 (U6) + the four tools (U5) deliver value with robust
  (dir-name) tagging.

**Adjust one thing for execution (carry into U3/KTD4):** go-forward native-write
tagging is a **best-effort `/reflect` backfill**, not a real-time hook (no hook
exists) — accept ~67% + global-safe-default; do not build a hook. The plan already
allows this (KTD4 "hook *or* backfill"; reduced-scope fallback) — this report
resolves it to **backfill**.

**Not reduced-scope / not stop:** reduced-scope (tools + re-import only) would drop
the recall boost, but the boost mechanism is exactly the part that verified cleanly,
and the 280 re-import gives it immediate material to surface. Stop is unwarranted —
nothing here falsified the value.

## Artifacts
- `scripts/scoped-memory/scope.py` — resolver + qmd-path scope parse/match/ancestry
  (the shared module; F-A + resolver verified).
- Harness: `== scope module (U1/U2) ==` section asserts the F-A match against the
  real qmd-output format, worktree→parent resolution, and ancestry.
