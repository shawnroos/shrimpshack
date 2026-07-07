---
title: "feat: Recover scattered auto-memory stores (premise-gated, scoping-aware)"
status: active
date: 2026-06-26
type: feat
origin: docs/plans/2026-06-26-001-fix-pin-auto-memory-directory-plan.md
---

# feat: Recover scattered auto-memory stores (premise-gated, scoping-aware)

## Summary

Plan 001 pinned the native auto-memory directory so **future** memories land in
the canonical store. It surfaced a backlog: **280 orphaned memory body files
across 12 per-project stores** (largest: `Slate-web-app` 186, `ai-editor-backend`
29, `brand-foundry-backend` 25, `Arras` 17) that are invisible to recall from any
other project.

The naive move — bulk-import them into the canonical store — is a **net-negative**
on its own recall mechanism, and this plan is built to avoid that. Two facts,
both verified against the live code, force the design:

1. **Recall is global, top-3, lexical, unscoped.** `hooks/seeded-recall.sh`
   injects the **top 3** bodies from a single flat `claude-memory` collection,
   ranked by **BM25 lexical** match to the prompt, with **no project scoping**.
   Adding ~200 project-local memories makes project trivia compete for those 3
   slots in *every unrelated session* — actively degrading recall of the curated
   132. (verified)
2. **`autoMemoryDirectory` / qmd indexes the directory by glob** (`Pattern:
   **/*.md`), so bodies become recallable without `MEMORY.md` pointers — but the
   canonical `MEMORY.md` is at **21.4 KB / 25.6 KB and 134 / 200 lines**, so a
   pointer-per-import is impossible anyway. (verified)

So consolidation is only worth doing if (a) the memories actually carry
**cross-project** value, and (b) recall can be **scoped** so project-local imports
don't crowd out curated ones. This plan **gates on (a) and requires (b)** rather
than assuming either. If the premise fails the pre-flight, the recommendation is
**archive-and-forget**, not consolidation — see Premise & Alternatives.

---

## Premise & Alternatives Considered

The originating plan (001) validated *stopping future scatter*. It did **not**
validate *consolidating the historical backlog into the global store* — that is
this plan's own bet, so it must be tested, not assumed.

**The bet:** that a worth-keeping subset of the 280 has cross-project recall
value. The Problem Frame concedes these are "private islands... never surfaced
again," and the pin already stopped the bleeding — so the do-nothing cost is low
and the alternatives are real:

- **A. Archive-and-forget (baseline).** Move scattered stores to an archive; don't
  import. Zero recall-pollution risk; memories preserved and restorable on demand
  if a specific one is ever missed. **This is the default the plan must beat.**
- **B. Consolidate-into-global (with scoping).** Import the worth-keeping subset,
  but only after adding recall-time project-scoping so imports don't dilute. Higher
  value *if* cross-project value exists; higher risk and cost.
- **C. Project-scoped recall.** Keep stores per-project, add per-project recall
  (recall a project's memories only when working in that repo). Avoids global
  pollution entirely but is a larger architectural change.

**The plan does not pre-commit to B.** U1 is a pre-flight that measures the
premise empirically (against the *lexical* recall path, with a captured baseline)
and recommends A, B, or C. Everything downstream of U1 (import machinery) runs
**only if U1 says B is justified**. This is the central decision; treat the U1
verdict as a real gate, not a formality.

---

## Requirements

- **R1.** *Gated.* If — and only if — the U1 pre-flight establishes cross-project
  value **that actually surfaces** (imports appear in top-3 under the strict-tier
  merge, not merely sit present in the collection), the worth-keeping subset becomes
  recallable via the `seeded-recall` hook (which searches the imported collection
  alongside curated — R4/KTD3), **without degrading recall of the existing curated
  memories** (measured, not assumed — R3). If value doesn't surface, the plan stops
  at A.
- **R2.** Canonical `MEMORY.md` stays under budget (≤ 25.6 KB and ≤ 200 lines)
  throughout — consolidation is a qmd-index operation, not a pointer-index one.
- **R3.** **No curated-recall regression.** A pre-import recall baseline on a fixed
  query set — **which must include an in-project session for the highest-volume
  store (Slate)** — is captured; import is accepted only if known-good canonical
  memories still surface in the top-3 (no displacement), in unrelated *and*
  high-volume same-project sessions. Dilution is measured against the **lexical**
  recall path the hook actually uses, not vector similarity.
- **R4.** **Recall-time scoping, two-tier, structurally guaranteed.** Recall draws
  candidates from two collections (KTD3): **curated** (`claude-memory` — its own
  bounded top-K, always eligible, tier 1) and **imported** (`claude-imported`,
  `origin_project`-tagged — slotted after curated, weighted **same-project >
  foreign**). Tier is the **primary sort key**; BM25 is the intra-tier tiebreak, not
  a multiplier a high-BM25 same-project import can overcome. Curated candidacy is
  **window-independent** (KTD9): import volume can never push a curated memory out
  of eligibility, which is what protects recall in the highest-volume project
  (Slate, 186 of 280). Without this structurally-guaranteed scoping, B is not pursued.
- **R5.** **Triage is drop-default, cross-project-positive.** Each scattered memory
  requires **cross-project signal** (or explicit operator keep) to be imported —
  recency alone is **not** sufficient (a recent project-only memory has no
  cross-project value and only inflates the same-project recall pile R4 must
  contain). "Everything else" is dropped. A target keep-rate cap is set; exceeding
  it is a triage failure to investigate, not an auto-import.
- **R6.** **Dedup against canonical AND intra-scatter.** Near-duplicates (a fact
  auto-saved repeatedly across sessions/stores) are collapsed before import, not
  imported as many near-copies.
- **R7.** **Imports survive reflect's prune.** Every import carries a fresh
  `last_used` and `pin: true` so the next `/reflect` cannot silently delete it.
- **R8.** **Idempotent, integrity-verified, non-destructive.** Re-runs don't
  double-import; every kept body is hash-verified present in the imported store
  before its source store is archived; **sources are archived, never deleted** in
  this plan.

---

## Key Technical Decisions

- **KTD1 — Premise pre-flight gates the build (U1).** Sample ~20–30 scattered
  memories, ask "would this have helped in an unrelated session?", and measure
  against the lexical recall path with a baseline. Low hit-rate → recommend
  archive-and-forget (A) and stop. The import units exist but do not run unless U1
  green-lights B.
- **KTD2 — Recall-time scoping is a real hook re-architecture: search two
  collections and tier-merge (U2 before import).** `seeded-recall.sh` runs a bounded
  search on **both** the curated `claude-memory` collection and the imported
  `claude-imported` collection (KTD3), then merges. Curated candidates need no
  per-result frontmatter read (the whole collection is curated). For imported
  candidates, read `origin_project` from the body — the hook already does a `qmd get`
  per result, and `qmd get` returns frontmatter+body in one call, so this is free —
  and **normalize worktree slugs to the parent repo** (`…-Slate-web-app-worktrees-…`
  is "same-project" as Slate), not exact-match the per-worktree slug. Merge fills
  slots from curated first, then imported by tier (R4). Two bounded searches + the
  existing per-result gets stay within the hard ~6s wall budget; the fail-safe and
  once-per-session guard are preserved. Scoping ships before import.
- **KTD3 — Imports go to a SEPARATE store + qmd collection, never the curated dir.**
  Kept bodies are written to a distinct directory (e.g.
  `~/.claude/projects/-Users-shawnroos/imported-memory/`) indexed as its own
  `claude-imported` collection — **not** mixed into the curated `claude-memory` dir.
  This is the structural pivot the review forced: it makes curated eligibility
  *window-independent* (KTD9 — no volume of imports can truncate a curated memory
  out of its own collection's top-K), keeps the curated store pristine so the
  `MEMORY.md` budget (R2) is trivially satisfied (imports aren't in it), and means
  the orphan-parity lint and `migrate-memory-index.py` never see the imports (the
  earlier lint-exclusion hack is no longer needed). Imports are recallable via
  re-embed of `claude-imported`; no `MEMORY.md` pointers.
- **KTD4 — Triage defaults to drop; model-assisted pass is mandatory.** Keep
  requires positive evidence; the borderline-classification model pass is required,
  not optional. Manifest is operator-reviewable but the design does not rely on a
  human reading 280 files — the default disposition is safe (drop/archive).
- **KTD5 — Dedup measured on the recall axis.** Dilution and dedup are evaluated
  with `qmd search` (lexical, the recall path), not only vector similarity, so the
  gate measures the contention recall actually experiences. Intra-scatter clustering
  runs before canonical comparison (R6).
- **KTD6 — Idempotency keyed on pre-injection source hash.** Frontmatter injection
  mutates the file, so the destination hash ≠ source hash. Compute the hash over the
  **frontmatter-stripped source body**, write it to the destination as
  `origin_hash`, and skip on `(origin_project, origin_hash)` already present —
  independent of filename (so the collision-rename case is still recognized).
- **KTD7 — Normalize every import to the canonical flat schema, then validate
  schema conformance.** The 280 sources are **three** shapes: ~50 flat top-level,
  ~228 nested under `metadata:`, and 2 with **no frontmatter at all**. A naive
  line-insert serves only the 50 — it strands `type`/`last_used` under `metadata:`
  for the 228 (off the canonical flat schema) and has no anchor for the 2 bare
  files. So import **normalizes** all bodies to the canonical flat schema: lift
  `metadata.*` to top level for the nested set, construct a fresh frontmatter block
  for the bare files, then add `origin_project`, `origin_hash`, `last_used`,
  `pin: true`. A full parse-reemit is fine here because `origin_hash` is computed
  over the frontmatter-**stripped** body (KTD6), so reformatting the frontmatter
  doesn't affect idempotency — the "never parse-reemit" constraint is dropped. The
  validation gate asserts **canonical-schema conformance** (required top-level
  fields present), not merely that the file parses — because `skills/reflect/SKILL.md`
  halts the whole reflect run on malformed *or* missing-required-field frontmatter.
- **KTD8 — Archive, integrity-gated, never delete here.** Sources move to
  `~/.claude/projects/_archived-memory/<slug>/` only after every kept body is
  hash-verified present in the imported store. Deleting originals is a separate,
  explicit, later operator action — not in this plan.
- **KTD9 — Curated eligibility is window-independent (closes the bounded-N hole).**
  Because curated and imported are separate collections (KTD3), the hook draws its
  own bounded top-K from the **curated** collection regardless of how many imports
  exist — so a curated memory can never be pushed out of *candidacy* by import
  volume (the failure mode of a single mixed collection + bounded over-fetch:
  a low-BM25 curated rule never fetched, never tier-boosted, silently dropped in a
  high-volume same-project session). Tier weighting (R4) then orders the merged
  curated+imported candidates; it does not gate curated candidacy. This is why the
  separate-collection decision (KTD3) is load-bearing, not cosmetic.

---

## Implementation Units

### U1. Premise pre-flight — measure cross-project value, recommend A/B/C

**Goal:** Empirically decide whether consolidation-into-global is justified, before
building any import machinery.

**Requirements:** R1 (gate), R3 (baseline half).

**Dependencies:** none.

**Files:**
- `scripts/consolidate-memory/preflight.py` (new)
- output: `scripts/consolidate-memory/preflight-report.md` (verdict + evidence)

**Approach:**
- Capture a **recall baseline**: a fixed set of representative prompts run through
  the *lexical* path (`qmd search -c claude-memory`, top-3), recording which
  canonical memories currently surface.
- **Intrinsic value:** sample ~20–30 scattered memories across the larger stores;
  for each, judge (model-assisted) "would this plausibly help in an *unrelated*
  project session?" Produce a cross-project hit-rate.
- **Value *surfacing* (the decisive measurement):** intrinsic value is necessary but
  not sufficient. Because R4 strict-tiers curated above imports, and a cross-project
  import is **foreign-tier** in any *other* project (the only place its cross-project
  value matters), it surfaces in top-3 only when the curated search is essentially
  silent on that prompt. So measure the thing that actually matters: inject kept
  cross-project candidates into a throwaway `claude-imported` collection and, for
  foreign-session prompts, run the **production strict-tier two-collection merge**
  and check whether those imports *actually appear in top-3*. A high intrinsic
  hit-rate with a near-zero surfacing rate means consolidation delivers little —
  verdict **A**, not B.
- Simulate dilution at **projected production scale**, not just sample scale —
  because displacement is volume-emergent (Slate alone projects to many imports).
  Inject keep-candidates **replicated to their projected post-triage per-store
  count** (especially Slate) into a throwaway **`claude-imported`** collection, and
  re-run the baseline prompts two ways: (a) **unscoped single mixed collection**
  (the naive harm) and (b) the **production two-collection merge path** — bounded
  search on curated + bounded search on imported, tier-merged exactly as U2 will
  ship (KTD2/KTD9), including an in-project (Slate) run where same-project volume
  bites. Measuring the *production* path (not an idealized lossless re-rank) is what
  makes the verdict trustworthy.
- **Verdict** (both arms measured via the production path): high intrinsic value
  **AND** a meaningful top-3 surfacing rate for foreign imports **AND** displacement
  "no worse than today" → **B**. Low intrinsic value, **or** high intrinsic value
  that strict-tier never surfaces (low surfacing rate) → **A** (archive-and-forget,
  stop) — and note that the strict-tier safety guarantee makes A the *expected*
  outcome unless surfacing is demonstrably non-trivial. High value that surfaces but
  can't be contained safely → **C** (project-scoped recall, re-plan).

**Test scenarios:**
- Baseline is reproducible (same prompts + unchanged store → same top-3).
- A planted obviously-cross-project sample memory raises the hit-rate; a planted
  project-trivia sample does not.
- The Slate run injects at projected keep-volume (replicated), not a handful — a
  curated rule that was top-3 pre-import is still surfaced under the two-collection
  path (the volume-emergent case is actually exercised).
- Displacement is measured against the lexical, two-collection path, not vector
  scores and not a lossless re-rank.
- **Surfacing is measured, not just intrinsic value:** a kept foreign import is
  checked for actual top-3 appearance in a foreign session under strict-tier merge;
  a high-intrinsic-value import that never surfaces drives an **A** verdict.
- The verdict is one of A/B/C with the supporting numbers recorded — including the
  foreign-import surfacing rate.

**Verification:** `preflight-report.md` states a clear A/B/C recommendation with the
hit-rate and displacement evidence. **Downstream units run only on a B verdict.**

---

### U2. Two-collection scoped recall in seeded-recall (prerequisite for any import)

**Goal:** Make the curated set structurally always-eligible and the imported set
scoped, so project-local imports cannot crowd out curated memories at any volume.

**Requirements:** R4.

**Dependencies:** U1 (B verdict).

**Files:**
- `hooks/seeded-recall.sh` (modify — search both collections, tier-merge)
- `tests/harness.sh` (extend the existing `seeded-recall hook` section)

**Approach:**
- Resolve the current project (git root → slug, mirroring the native feature),
  **normalizing worktree slugs to their parent repo** (KTD2).
- **Search both collections** (KTD2/KTD3): a bounded search on curated
  `claude-memory` (its own top-K — always eligible, tier 1, **window-independent**
  per KTD9) and a bounded search on imported `claude-imported`. For imported results,
  read `origin_project` from the body the hook already `qmd get`s, and tier as
  same-project > foreign.
- **Tier-merge** with tier as the **primary sort key** (BM25 intra-tier tiebreak,
  not a multiplier): fill slots from curated first, then imported by tier. Because
  curated has its own search, no volume of imports can evict a curated memory from
  candidacy (the bounded-N hole is gone — KTD9).
- **Shared merge logic.** The tier-merge is a single shared module used by both this
  hook and U1's surfacing sim, so the decisive surfacing measurement and the shipped
  behaviour can't diverge — the same KTD6 "one source of truth" discipline used for
  the hash helper, applied to the merge.
- Preserve the existing fail-safe (qmd absent → exit 0, no output), once-per-session
  guard, and total wall budget (two bounded searches + the existing per-result gets).

**Test scenarios:**
- In a **Slate** session injected at projected keep-volume, an untagged cross-cutting
  canonical rule that was top-3 pre-import **still surfaces** — curated's own search
  guarantees its candidacy regardless of import count (the load-bearing KTD9 case).
- A foreign-`origin_project` import does not displace an equally/more relevant
  curated body.
- A worktree-origin import is treated as same-project as its parent repo (slug
  normalization).
- With `claude-imported` absent/empty, behaviour is identical to today (curated-only).
- **Two-search latency is measured at projected import volume** (not just asserted):
  the curated + imported searches + per-result gets complete within the wall budget
  with `claude-imported` at its projected size, so the second search never trips the
  timeout fail-safe and silently drops a curated memory (guards R3). qmd-absent and
  once-per-session fail-safes still hold.

**Verification:** harness shows foreign-origin imports are down-weighted/filtered
while curated and same-project memories surface; existing seeded-recall tests still
pass.

---

### U3. Inventory + drop-default triage with dual dedup → manifest

**Goal:** Classify all 280 keep/drop/merge with positive-evidence keep, deduping
intra-scatter and against canonical, into a reviewable manifest.

**Requirements:** R5, R6, R3 (dilution-detect half).

**Dependencies:** U1 (B verdict).

**Files:**
- `scripts/consolidate-memory/inventory.py`, `triage.py` (new)
- output: `manifest.json`

**Approach:**
- Inventory the 12 stores (slug, file, frontmatter, size, mtime); exclude the
  canonical slug and `MEMORY.md`.
- **Cluster intra-scatter near-duplicates first** (R6), then compare each cluster
  representative to canonical. Use `qmd search` (lexical, KTD5) as the contention
  signal, alongside vector similarity for dedup.
- **Drop-default classification (KTD4, R5):** `keep` requires **cross-project
  signal** or explicit operator keep — recency alone is **not** sufficient (R5);
  else `drop`. `merge` = high canonical overlap. Model-assisted pass is mandatory.
  Record a target keep-rate cap; flag overruns.
- Emit `manifest.json`: `{slug, file, class, cluster_id, dup_of, dup_score,
  lexical_contention, reason}`. Operator-editable.

**Test scenarios:**
- Inventory finds all 280; excludes canonical + `MEMORY.md`.
- Two near-identical scattered bodies land in one cluster (one representative).
- A body with no positive keep-evidence defaults to `drop`.
- A near-duplicate of a canonical memory is `merge` with populated `dup_of`.
- Manifest is valid JSON, byte-stable on re-run of an unchanged tree.
- Fail-safe when qmd absent (signals degrade to null; classification still completes).

**Verification:** `manifest.json` enumerates 280 with classes; keep-rate is within
the cap (or flagged); summary printed for operator review.

---

### U4. Import kept memories into the imported store — prune-protected, idempotent

**Goal:** Bring keep-classified bodies into the separate imported store, recallable
and durable, without touching the curated store or its `MEMORY.md`/lint at all.

**Requirements:** R1, R2, R7, R8 (idempotency + integrity-write half).

**Dependencies:** U2 (scoping live), U3 (manifest).

**Pre-import gate (re-validate surfacing on the shipped hook):** U1's B verdict rests
on a surfacing rate measured by U1's sim. Before importing, re-run that surfacing
measurement against the **live U2 hook** (shared merge module, so sim and hook
can't diverge) at projected volume; if production surfacing is near-zero, stop at A
even on a prior B. The decisive number is confirmed against the real mechanism, not
just the offline sim.

**Files:**
- `scripts/consolidate-memory/import.py` (new)
- `scripts/qmd-reconcile-collections.sh` (modify — register the `claude-imported`
  collection on the imported dir, mirroring the existing reconcile pattern)
- `tests/harness.sh` (new `== memory consolidation ==` section, isolated CLAUDE_HOME)

**Approach:**
- For each `keep`: compute the hash over the **frontmatter-stripped source body**
  (KTD6, via a **shared strip helper** also used by U5 so the two never diverge);
  **normalize the frontmatter to the canonical flat schema** — lift `metadata.*` to
  top level (nested set), or build a fresh block (bare files) — then add
  `origin_project`, `origin_hash`, fresh `last_used` (import date), `pin: true`
  (KTD7, R7); write into the **imported store** (`…/imported-memory/`, KTD3), **not**
  the curated dir. Skip if `(origin_project, origin_hash)` already present
  (idempotent, KTD6).
- Filename collision (the 1 vs curated): imports live in a separate dir so there is
  no collision with curated; within the imported store, suffix `__<slug>` only if
  two imports share a name.
- Re-embed once at the end as the **`claude-imported`** collection. The curated
  `claude-memory`, its `MEMORY.md` budget (R2), and the orphan-parity lint are
  **untouched** — imports aren't in that dir (KTD3), so no lint change is needed.
- Validate each normalized file against canonical-schema conformance (required
  top-level fields, KTD7) before counting it imported — guards the reflect halt.
- `drop` skipped; `merge` routed per the merge decision (U6 / deferred).

**Test scenarios:**
- A `keep` body lands in the **imported** store with `origin_project` +
  `origin_hash` + `last_used` + `pin: true`; source left in place; curated dir
  untouched.
- The curated `MEMORY.md` byte and line counts are **unchanged** (R2 — trivially,
  since imports are in a separate dir).
- Re-running import is idempotent (matched on `origin_hash`, not filename; no churn).
- An imported body is **not** prune-eligible (fresh `last_used` + `pin`).
- All three source shapes normalize to the canonical flat schema: nested lifts to
  top level; bare gets a constructed block; flat is preserved.
- The validation gate rejects a body missing a required top-level field (not merely
  one that fails to parse) — not counted imported, reflect not left broken.
- After re-embed, a qmd search of `claude-imported` returns an imported memory.

**Verification:** kept bodies in canonical with full protection frontmatter;
`MEMORY.md` budget unchanged; lint parity clean; qmd recall returns an import.

---

### U5. Per-file integrity verify + archive (gate before any future delete)

**Goal:** Prove every kept body is intact in canonical, then archive drained
sources; leave deletion of originals as a separate confirmed step.

**Requirements:** R8 (integrity + archive half).

**Dependencies:** U4.

**Files:**
- `scripts/consolidate-memory/verify-and-archive.py` (new)

**Approach:**
- **Per-file integrity gate** (not counts, not a sample): for every `keep`,
  recompute the body hash with the **shared strip helper** (the same one `import.py`
  used — KTD6) and assert a body carrying that `origin_hash` exists in the imported
  store. Only stores whose entire keep-set passes are eligible to archive.
- Move drained stores' `memory/` subdir (only the subdir — session transcripts in
  the store root are untouched) to `~/.claude/projects/_archived-memory/<slug>/`.
  **No `rm`.** Stores with unresolved `merge` items are **not** archived (partial
  archival is expected pending the merge follow-up — stated, not hidden).
- Emit a reconciliation report: per-class counts that sum to 280, current
  `MEMORY.md` budget, and a recall spot-check.

**Test scenarios:**
- A truncated/corrupted import is caught by the per-file `origin_hash` check and
  blocks that store's archival.
- A fully-imported store's `memory/` subdir is moved to the archive; its `.jsonl`
  transcripts in the store root are untouched; nothing deleted.
- A store with an unresolved `merge` item is not archived.
- Report counts reconcile across the three U3 classes: `imported + dropped +
  merged == 280` (merge items not yet handled are counted under `merged`, awaiting
  the follow-up — there is no fourth class).

**Verification:** archive holds drained subdirs; canonical holds verified imports;
`MEMORY.md` under budget; recall returns imports; originals recoverable.

---

## Risks & Dependencies

- **R-risk1 — Recall dilution (the central risk).** Globalizing project memories
  can bury curated ones in the top-3. Mitigated *structurally*, not by hope:
  premise gate (U1), recall-time scoping (U2), drop-default triage (U3), and a
  no-displacement acceptance test on the lexical path (R3). If U1 shows scoping
  can't contain it, the plan routes to A/C instead of importing.
- **R-risk2 — Mutating the live memory system.** Import writes to the **separate**
  `imported-memory/` store (KTD3) — the curated dir and its `MEMORY.md` are
  structurally untouched — and U5 moves source `memory/` subdirs to the archive.
  Mitigated: idempotent (pre-injection hash), schema-normalize then validate,
  prune-protected, per-file integrity gate before archival, sources never deleted
  here. Test against isolated `CLAUDE_HOME` first.
- **R-risk3 — Merge may dominate.** These are one person's memories; high overlap
  is plausible, so `merge` could be the majority, not the deferrable remainder. U3
  reports the merge fraction; **if it exceeds ~40%, "ship keep/drop first" is not a
  viable standalone outcome** — decide then between investing in merge or falling
  back to archive-and-forget. No assuming a 90/10 split.
- **R-risk4 — Reflect tooling interactions.** Prune (`last_used`/`pin`), orphan-parity
  lint, and frontmatter-halt are all addressed in U4 (R7, KTD3, KTD7). Re-embed
  cost for ~280 small files is seconds-to-minutes; run once at end.
- **Dependency:** working `qmd` for dedup + recall (degrade gracefully when absent).

---

## Scope Boundaries

**In scope:** premise pre-flight (U1), recall-time scoping (U2), drop-default triage
with dual dedup (U3), prune-protected budget-safe import (U4), integrity-verify +
archive (U5).

### Non-goals
- **No import without a U1 "B" verdict** — archive-and-forget (A) is the default the
  plan must beat.
- **No bulk import; no MEMORY.md pointer explosion; no deletion of source stores.**

### Deferred to Follow-Up Work
- **Merge execution (R-risk3).** If the merge fraction is large or judgement-heavy,
  ship keep/drop + scoping first and handle `merge` as a separate curated pass (a
  new U6). The automate-vs-defer call is made on U3's measured fraction.
- **Curated pointer promotion** — adding a tiny hand-picked set to `MEMORY.md` within
  the ~66-line headroom, opt-in, after recall behaviour is observed.
- **Project-scoped recall (alternative C)** as a larger architecture, if U1 routes there.

---

## Open Questions / Deferred

- **A/B/C verdict** — decided empirically by U1, not assumed here.
- **Merge automate-vs-defer** — decided on U3's measured merge fraction (R-risk3).
- **Scoping strength** — hard filter vs. down-weight of foreign-origin imports
  (U2) — tuned so curated recall is never worse than today.
- **Drop heuristics / keep-rate cap** — tuned against the real manifest in U3.
- **Archive vs. delete originals** — default archive; deletion is a later confirmed
  call once recall is trusted.

---

## Sources & Research

- Plan 001 — the pin that stops future scatter; validated the pin, **not** this
  consolidation (hence the U1 premise gate).
- Live survey (2026-06-26): 280 scattered bodies across 12 stores; canonical
  `MEMORY.md` at 21.4 KB / 134 lines; 1 exact filename collision, 0 cross-store.
- **Verified mechanisms:** `hooks/seeded-recall.sh` — global, top-3, BM25-lexical,
  unscoped recall (drives R4/KTD2/KTD5); `qmd` `claude-memory` collection indexes by
  `**/*.md` glob (KTD3); `skills/reflect/SKILL.md` — auto-prune of unused/unpinned
  memories (R7), reflect-halt on malformed frontmatter (KTD7); `scripts/memory-index-lint.sh`
  — orphan-parity check (KTD3); two frontmatter schemas (flat + nested `metadata:`)
  in the live bodies (KTD7).
