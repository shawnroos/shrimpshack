---
title: "feat: Repo-scoped memory with walk-up-the-tree recall"
status: active
date: 2026-06-26
type: feat
origin: docs/brainstorms/2026-06-26-repo-scoped-memory-recall-requirements.md
---

# feat: Repo-scoped memory with walk-up-the-tree recall

## Summary

Memories tied to a repo are high-signal *in that repo* but compete against the
whole pool everywhere, so in their own context they get buried by higher-BM25 but
less-relevant noise (the origin's "signal loss"). This plan adds **repo-scoped
memory** on the single pinned store: each memory's `scope` (its birth repo) is
encoded **in its storage path**, recall reads that path **for free from the qmd
search result** and surfaces the current repo's relevant memories *in addition to*
(never displacing) the global ones, four `reflect` CLI tools give explicit control,
and the archived 280 are re-imported tagged by origin repo.

**Three decisions the review settled up front, each grounded in the inherited
mechanics (plans 001/002) and a direct qmd check:**

1. **Scope lives in the storage PATH, not (only) frontmatter — because qmd search
   returns `file` but not frontmatter fields.** Reading scope from frontmatter would
   force a `qmd get` per candidate across the pre-truncation window (the hook
   truncates to K *before* its get loop) — an unmeasured budget cost. Encoding scope
   in a `_scope/<slug>/` subpath means recall parses it from the result's `file`
   field at zero extra cost, and the `_scope/**` subtree is naturally invisible to
   `memory-index-lint`'s non-recursive `os.listdir` while qmd's `**/*.md` glob still
   indexes it. (Frontmatter *also* carries `scope` for the tools and readability,
   but recall reads the path.)
2. **It surfaces repo memories via a relevance-gated EXTRA slot, never by evicting a
   global.** Reserving one of the K=3 slots would make "global surfaces in every
   session" (AE2) unpassable and regress today's recall. Instead: when a current-repo
   memory clears a relevance floor on the prompt, it's injected as a **K+1th** item;
   globals keep all K slots. No displacement, by construction.
3. **It is gated by a U1 pre-flight that measures before building** — tagging
   *coverage* (can native-written memories actually be path-tagged?) and in-repo
   *surfacing value* — mirroring the discipline plan 002 applied to the inverse bet.

---

## Problem Frame

The single store (plan 001) fixed scatter but flattened scope: every repo memory
competes against the whole canonical store on recall. `hooks/seeded-recall.sh`
injects the **top-K=3** bodies by **BM25 lexical** match, **unscoped** — so a
Slate-specific memory exactly relevant in Slate can lose its slot to a higher-scoring
general memory. The native per-repo silos protected repo signal but lost cross-repo
sharing (the scatter we removed).

Target: the current repo's relevant memories surface *alongside* the globals
(closest-scope-first, walking up the tree to `~/`/global = the canonical
`-Users-shawnroos` store), driven by tools, on one store — without displacing the
global recall that works today.

---

## Requirements (traced to origin)

- **R1 — Scope = birth path, auto-detected** (origin R1). `scope` = the repo a memory
  was born in (cwd→git root; worktrees fold to parent), encoded in its storage path.
  No classify-as-global judgment at save. **Coverage caveat:** memories the system
  can't path-tag fall back to flat/global (no boost) — measured in U1.
- **R2 — Walk-up-the-tree, closest-first** (origin R2, R3). Recall surfaces
  current-repo memories first, then ancestors up to `~/`/global. Canonical store =
  global/root node.
- **R3 — Additive, relevance-gated, no regression** (origin R4, reframed). A
  current-repo memory surfaces as an **extra** item when it clears a relevance floor;
  globals are never displaced and remain exactly as today. **Not** a hard "always
  surfaces" guarantee — a repo memory below the recall window isn't fetched (the
  honest envelope). No-regression on globals is measured (U1, U4).
- **R4 — One store; scope in the storage path** (origin R5). The plan-001 pin stays;
  scope is a `_scope/<slug>/` subpath under the one store (frontmatter mirrors it).
  No separate per-repo *collections* (deferred — see Scope Boundaries).
- **R5 — Four tools, agent-callable + CLI** (origin R6). `recall`, `save --scope`,
  `promote`/`rescope`, `list` (incl. `--cross-repo`).
- **R6 — Re-import the archived 280, tagged + cross-cutting-aware** (origin R7).
  Tagged by origin repo into `_scope/<slug>/`, prune-protected, with plan 002's
  cross-project-positive triage (cross-cutting → global, not repo).
- **R7 — Repo granularity only** (origin R8). Worktrees fold to parent; no worktree
  scope, no expiry.

---

## High-Level Technical Design

Scope is a path; slugs are path-derived, so "walk up the tree" = walk up the slug's
components — `-Users-shawnroos` (the `~/` slug) is an ancestor of every
`-Users-shawnroos-projects-<repo>`. The store layout:

```text
~/.claude/projects/-Users-shawnroos/memory/
  *.md                       # global scope (flat root = ~/ node) — lint-checked as today
  _scope/<repo-slug>/*.md    # repo-scoped; invisible to non-recursive lint; qmd-indexed
  MEMORY.md                  # index of GLOBAL memories only (budget unaffected by scoped/imported)
```

Recall reads scope from the result path — no per-candidate get:

```mermaid
sequenceDiagram
    participant Hook as seeded-recall.sh
    participant QMD as qmd
    Hook->>Hook: resolve current-repo slug (git common-dir, abs; worktree→parent)
    Hook->>QMD: bounded BM25 search, over-fetch N>K, --format json
    QMD-->>Hook: results: file (PATH → scope), score, snippet
    Hook->>Hook: parse scope from each file path (FREE — no get)
    Hook->>Hook: take top-K globals/ancestors as today; if a current-repo result<br/>clears the relevance floor, add it as a K+1th item
    Hook->>QMD: qmd get ONLY the selected K(+1) bodies (as today)
    Note over Hook: repo memory below the N window isn't a result → not surfaced.<br/>That's the best-effort envelope (R3). Globals untouched.
```

The K+1 additive shape is authoritative: globals keep K slots; a relevant repo
memory rides alongside.

---

## Key Technical Decisions

- **KTD1 — Scope in the `_scope/<slug>/` storage path; recall reads it from the qmd
  `file` field (decided now, grounded in a qmd check).** `qmd search --format json`
  returns `docid/score/file/line/title/snippet` — the **path** but not frontmatter
  — so path-encoded scope is read for free, whereas frontmatter scope would cost a
  `qmd get` per pre-truncation candidate (the hook truncates to K before its get
  loop). The `_scope/**` subtree is excluded from `memory-index-lint`'s non-recursive
  `os.listdir` (no orphan spam) and included by qmd's recursive `**/*.md` glob.
  Frontmatter also carries `scope` for the tools/human readability. Per-repo
  *collections* (a true window-independent guarantee, = plan 002 option C) remain
  deferred. **Path-value normalization (load-bearing — verified gotcha):** qmd
  rewrites the `file` value — it strips the leading `_` (`_scope`→`scope`), strips
  the leading `-` from the slug (`-Users-…`→`Users-…`), and prefixes
  `qmd://<collection>/`. So the scope parsed from the result path and the slug from
  the resolver (KTD3, which carries the leading `-`) must both be **normalized**
  (drop the `qmd://…/` prefix, strip leading punctuation) before comparison, or the
  match silently never fires and the K+1 never appears. This normalization is part
  of U1's shared module and an explicit U1 acceptance criterion.
- **KTD2 — Additive K+1, relevance-gated — never slot reservation/eviction.**
  Globals keep all K slots (no regression, AE2 holds). A current-repo result is
  injected as an extra item **only when it clears a relevance floor**. That floor is
  a **distinct parameter** (e.g. `SEEDED_RECALL_REPO_MIN_SCORE`) applied only to the
  current-repo candidate after globals are separated — **not** the existing
  `SEEDED_RECALL_MIN_SCORE`, which filters *all* results before the top-K cut and
  must keep governing global selection unchanged. (Reusing the global knob for the
  repo floor would silently filter globals — the exact regression this KTD avoids.)
  This reconciles "surface repo memories" (AE1) with "never displace a global" — the
  two are orthogonal once we stop forcing the repo memory *into* K.
- **KTD3 — Walk-up = slug-path ancestry; resolver uses absolute git-common-dir.**
  Ancestry from slug components; `global` = `$HOME` slug. Repo root via
  `git rev-parse --path-format=absolute --git-common-dir` then strip `/.git` — NOT
  `--show-toplevel` (returns the worktree root) and NOT bare `--git-common-dir`
  (returns a *relative* `.git`/`../.git` in the main checkout → garbage slug). This
  is the common-case trap; the resolver must produce an absolute repo root.
- **KTD4 — Path-tag at save; coverage measured in U1.** Reflect-protocol saves and
  re-imports write into `_scope/<slug>/` directly. **Native auto-memory writes** land
  flat (plan-001 pin) and aren't authored by reflect; tagging them = a controlled
  move into `_scope/<slug>/` driven by a hook on the write *or* a backfill keyed on
  `originSessionId` → transcript-path `~/.claude/projects/<cwd-slug>/<session>.jsonl`
  → cwd-slug. U1 measures the taggable fraction **and the mis-scope rate** (the
  backfill recovers the *session-start* cwd, which ≠ the save-time cwd in multi-repo
  sessions). Untagged ⇒ flat/global: signal-safe but coverage-inert — stated, not
  hidden. `promote`/`rescope` corrects mis-tags.
- **KTD5 — Tools ship as a `reflect` CLI** (operator's prefer-CLI default); agent via
  Bash. No MCP surface.
- **KTD6 — Re-import reuses plan 002's import discipline AND its cross-project
  triage.** Idempotent (pre-injection body hash), schema-normalize, prune-protect
  (`last_used`+`pin`), per-file integrity, archive untouched. Cross-project-positive
  keep test → cross-cutting memories tag **global**, not `repo:<origin>` (adv F5).

---

## Implementation Units

### U1. Pre-flight gate — measure tagging coverage and in-repo surfacing value

**Goal:** Before building, answer the two questions the value rests on. U2–U7 commit
only on a positive verdict.

**Requirements:** R1 (coverage), R3 (value/no-regression). **Dependencies:** none.

**Files:** `scripts/scoped-memory/preflight.py` (new), `preflight-report.md`.

**Approach:**
- **Coverage:** probe for a hook on the native memory write; if absent, test the
  `originSessionId` → transcript-path → cwd-slug backfill against real files and
  report (a) the resolvable **fraction** and (b) the **mis-scope rate** (session-start
  cwd vs save-time cwd; transcript-retention bounds this — likely the dominant
  low-coverage driver). Low coverage ⇒ verdict NO or reduced-scope (tools +
  re-import only).
- **Value, on the shipped path:** build the re-rank as a **shared module** that U4's
  hook will import verbatim (so measured == shipped — plan 002's anti-divergence
  discipline), and run the sim on **real `qmd search` output**, not synthetic path
  strings. At projected volume, measure (a) how often a repo session's useful recall
  needs a repo memory today's flat top-3 misses, and (b) for the additive K+1, net
  usefulness. The no-displacement invariant is internal, not a diff-against-today:
  **the K global slots equal top-K of the post-scoping globals-only pool (siblings
  excluded); the repo extra is purely additional.**
- **Acceptance criterion (F-A — load-bearing):** the scope parsed (and normalized
  per KTD1) from a **real** qmd `file` field must string-equal the resolver's
  normalized slug for the same repo. If it doesn't, the K+1 never fires and the sim
  would false-STOP — so this equality is part of U1's definition-of-done before the
  value numbers mean anything.
- **Verdict:** build / reduced-scope / stop, numbers recorded.

**Test scenarios:**
- A planted cross-project-relevant repo memory raises the "K+1 helps" rate; repo
  trivia does not.
- The coverage probe reports a concrete taggable fraction AND a mis-scope rate.
- The K+1 path leaves all K global slots intact (zero displacement) in the sim.
- Verdict is build / reduced-scope / stop with numbers.

**Verification:** `preflight-report.md` states a clear verdict; U2–U7 conditional on
a build verdict; the re-rank module it builds is the one U4 ships.

---

### U2. Scope resolver + ancestry helper (foundation)

**Goal:** Shared helper: cwd → repo scope slug (absolute git-common-dir,
worktree→parent) and ancestry (is-ancestor, walk-up).

**Requirements:** R1, R2, R7. **Dependencies:** U1 (build verdict).

**Files:** `scripts/scoped-memory/scope.py` (new), `tests/harness.sh`.

**Approach:** `resolve(cwd)` via `git rev-parse --path-format=absolute
--git-common-dir` → strip `/.git` → repo root → canonical path-slug; worktrees fold
to parent. `is_ancestor`, `walk_up`, `global` = `$HOME` slug (KTD3).

**Patterns to follow:** `$HOME`-slug derivation in `scripts/setup.sh:24`.

**Test scenarios:**
- Covers AE2. `is_ancestor(home, repo)` true; siblings false.
- `resolve` in a **plain non-worktree repo** (root AND a subdir) returns the correct
  absolute repo slug — the relative-`.git` trap.
- `resolve` in a **worktree** returns the parent repo slug.
- `resolve` outside any repo returns the global/home slug.
- `walk_up(repo)` → repo … home slug in order.

**Verification:** resolver + ancestry pass, including plain-repo, subdir, and
worktree fixtures.

---

### U3. Save-time path tagging

**Goal:** Place memories under `_scope/<slug>/` at save — directly for reflect saves,
via the U1-confirmed mechanism for native writes.

**Requirements:** R1. **Dependencies:** U1 (coverage), U2.

**Files:** `hooks/scope-tag.sh` and/or a backfill in `scripts/scoped-memory/`;
`.claude/hooks/hooks.json`; `tests/harness.sh`.

**Approach:** Reflect saves write the body into `_scope/<slug>/` (and mirror `scope`
in frontmatter). Native writes land flat (pin); the tag step **moves** the taggable
ones into `_scope/<slug>/` and re-embeds (a controlled move, not a fight with the
pin — the pin writes flat, the tag step relocates). Untagged ⇒ flat/global. **Do
not relocate a body that carries a MEMORY.md pointer** — a pointered memory is
curated/always-loaded (global-value by definition), so moving it to `_scope/` would
silently demote it from always-loaded to qmd-recall-only. Relocation applies only to
un-pointered native auto-memories; scoped bodies are qmd-recall-only (not MEMORY.md
entries — see U7).

**Test scenarios:**
- A reflect save in repo X lands under `_scope/<X-slug>/` and is qmd-searchable.
- A save outside a repo stays flat (global).
- The backfill moves an untaggable-at-write native file into its scope subdir when
  provenance resolves; leaves it flat when not.
- Tagging preserves frontmatter (flat and nested `metadata:` schemas).
- Covers AE1.

**Verification:** scoped saves land under `_scope/`; global saves stay flat; qmd
indexes both.

---

### U4. Additive relevance-gated recall in seeded-recall

**Goal:** Surface a relevant current-repo memory as a K+1th item, reading scope from
the result path — no per-candidate get, no global displacement.

**Requirements:** R2, R3. **Dependencies:** U1, U2.

**Files:** `hooks/seeded-recall.sh` (modify, import U1's re-rank module),
`tests/harness.sh`.

**Approach:** Resolve current-repo slug (U2). Run the existing bounded BM25 search
with over-fetch N>K, `--format json`; **parse scope from each result's `file` path**,
normalizing qmd's path rewrite (KTD1: strip `qmd://…/` prefix, leading `_`/`-`) and
the resolver slug the same way before comparing (free — no extra get). Take the
top-K globals/ancestors (siblings excluded) exactly as today; if a current-repo
result clears the **distinct repo floor** (`SEEDED_RECALL_REPO_MIN_SCORE`, NOT the
global `min_score` — KTD2), inject it as a **K+1th** item. `qmd get` only the
selected bodies (the K + the one extra). Preserve the ~6s budget, qmd-absent
fail-safe, once-per-session guard.

**Patterns to follow:** the search/score/get structure in
`hooks/seeded-recall.sh:84-134` (note: truncation precedes the get loop today — the
new scope read happens on the full result set *before* selection, which is why it
must come from the `file` field, not a get).

**Test scenarios:**
- Covers AE1. In a `slate-web-app` session, a relevant Slate memory is added as the
  extra item.
- Covers AE2. The K global slots equal **top-K of the post-scoping globals-only
  pool** (siblings excluded) — the repo extra is purely additional, never occupying
  a global slot (the load-bearing no-regression assertion; NOT a byte-diff against
  today's flat store, which is unsatisfiable once repo memories move to `_scope/`).
- An irrelevant repo memory (below the relevance floor) is NOT added.
- A repo memory below the N window isn't a result → not surfaced (the envelope).
- A memory scoped to an unrelated repo never appears.
- Scope is read from the `file` path, not a per-candidate get; budget + fail-safes
  hold.

**Verification:** harness shows the additive K+1 with the K global slots equal to
top-K of the post-scoping globals-only pool; scope parsed from the real qmd `file`
path (normalized) and matching the resolver slug; within budget.

---

### U5. The four `reflect` CLI tools

**Goal:** Agent + operator CLI: active recall, scoped save, promote/rescope (which
*moves* a body between scope paths), list (incl. cross-repo discoverability).

**Requirements:** R5. **Dependencies:** U1, U2, U4.

**Files:** `scripts/scoped-memory/reflect-cli` (new), `tests/harness.sh`.

**Approach:** `recall --here "<q>"` (U4 logic on demand); `save --scope
<repo|global|repo:slug> "<note>"` (writes to the right path); `promote <memory>` /
`rescope <memory> <scope>` (moves the body between `_scope/…`↔flat + re-embed);
`list [--here|--scope <s>]` plus a **`--cross-repo`** mode surfacing repo-scoped
memories with high cross-repo lexical match — so a mis-scoped global-value memory
that suppression hides is discoverable.

**Test scenarios:**
- Covers AE5. `recall --here` adds this repo's relevant memories.
- `save --scope global` writes flat regardless of cwd.
- Covers AE3. `promote` moves a `_scope/X/` body to flat/global; it then surfaces
  everywhere; idempotent.
- `list --cross-repo` surfaces a repo-scoped memory matching across repos.

**Verification:** all subcommands behave per scenarios against an isolated store.

---

### U6. Re-import the archived corpus — tagged, cross-cutting-aware

**Goal:** Restore the 280 into `_scope/<slug>/`, cross-cutting ones to global, as
qmd-recall-only bodies (not MEMORY.md entries).

**Requirements:** R6. **Dependencies:** U1, U2, U3.

**Files:** `scripts/scoped-memory/reimport.py` (new), `tests/harness.sh`.

**Approach:** Read `_archived-memory/<slug>/memory/`; default `_scope/<slug>/`, but
apply plan 002 R5's cross-project-positive test → cross-cutting memories go to
flat/global instead. Light triage drops cruft. Stamp plan-002 protection frontmatter
(`last_used`, `pin`, `origin_hash`). Imports are **qmd-recall-only, not MEMORY.md
entries** — the global flat root keeps its index budget; `_scope/**` bodies are
outside the non-recursive lint's view, so no parity break. Idempotent
(`origin_hash`), per-file integrity, archive untouched. Reuses plan 002 KTD6.

**Test scenarios:**
- A `slate-web-app` archive body imports under `_scope/<slate-slug>/`, `pin`, fresh
  `last_used`; archive untouched; MEMORY.md unchanged.
- A cross-cutting archived memory imports flat/global, not scoped.
- Covers AE4. A Slate-scoped import surfaces (when relevant) in Slate, stays quiet in
  `ai-editor-backend`.
- Idempotent on `origin_hash`; counts reconcile (imported + dropped == archived).
- `memory-index-lint` parity stays clean (scoped bodies invisible to non-recursive
  listdir; not added to MEMORY.md).

**Verification:** tagged imports recallable in-repo; cross-cutting ones global;
archive intact; lint parity clean; counts reconcile.

---

### U7. Docs, hook wiring, lint reconciliation, and setup

**Goal:** Document scope + additive recall + tools; wire any hook; reconcile the lint
explicitly; `setup.sh` registers/backfills idempotently.

**Requirements:** R1–R6 (operationalization). **Dependencies:** U1, U3, U4, U5, U6.

**Files:** `skills/reflect/SKILL.md`, `docs/memory-protocol-update.md`,
`.claude/hooks/hooks.json`, `scripts/memory-index-lint.sh`, `scripts/setup.sh`,
`tests/harness.sh`.

**Approach:** Document `scope`, the additive K+1 envelope, and the four tools. Wire
the scope-tag hook (if hookable) fail-open. **Lint reconciliation:** confirm/encode
that `memory-index-lint.sh` treats only flat-root bodies as MEMORY.md-indexable and
ignores `_scope/**` (it's non-recursive today, so this is mostly an explicit
assertion + a test, not a rewrite — corrects the earlier "no change needed" by
making the exclusion intentional). Extend `setup.sh` to create `_scope/` and
backfill existing untagged memories (which stay flat/global) idempotently.

**Test scenarios:**
- `memory-index-lint` stays parity-clean with `_scope/**` bodies present (explicit).
- `setup.sh` is idempotent on re-run; `_scope/` created.
- The scope-tag hook (if wired) fires fail-open.
- Docs name the scope model, the additive envelope, and the four tools.

**Verification:** fresh `setup.sh` leaves a working, idempotent system; lint clean
with scoped bodies; docs match behavior.

---

## Risks & Dependencies

- **R-risk1 — Value/coverage unmeasured (highest).** Mitigated by U1 gating U2–U7,
  with a shared re-rank module (measured == shipped) and coverage + mis-scope-rate
  measurement (adv F1/F2).
- **R-risk2 — Best-effort envelope.** A repo memory below the recall window isn't
  surfaced (R3/KTD1). Accepted; a true guarantee = per-scope collections, deferred.
- **R-risk3 — Recall regression.** The additive K+1 leaves global slots untouched by
  construction (KTD2); U4 asserts the K global slots are byte-identical to today.
- **R-risk4 — Mis-tagging hides a global-value memory.** Mitigated for the 280 by
  U6's cross-project triage; for steady-state new memories by `promote`/`rescope` +
  `list --cross-repo`. **Residual (accepted):** a *new* repo-born global-value memory
  is suppressed elsewhere until someone runs `list --cross-repo` (pull-based) — a
  notice-to-audit dependency, lower-severity than the re-import case (adv F5).
- **R-risk5 — Native-write tagging coverage.** May be backfill-only and approximate
  (session-start vs save-time cwd); sized in U1, not assumed; untagged ⇒ global is
  signal-safe, coverage-inert.
- **Dependencies:** plan-001 pin live; plan 002 import mechanics + `seeded-recall`
  findings reused; working `qmd` (degrade gracefully when absent).

---

## Scope Boundaries

**In scope:** U1 gate, resolver (U2), path tagging (U3), additive recall (U4), four
tools (U5), cross-cutting-aware re-import (U6), docs/lint/setup (U7).

### Deferred to Follow-Up Work
- **Per-scope qmd collections** — the only design giving a true window-independent
  *guarantee* (= plan 002 option C); revisited only if U1 shows the additive
  best-effort path is insufficient. Carries collection lifecycle + recursive-glob
  overlap.
- **Intermediate scope nodes** (all-Slate-repos) — ancestry supports them; later
  opt-in (origin "Deferred for later").
- **Visual scope labels in injected context** — recall-presentation refinement.

### Outside this product's identity (from origin)
- **Worktree-level scope** (R7 / origin R8) — folded to parent.
- **Deleting the archive** — re-import reads it; deletion is a separate manual call.
- **Changing/removing the plan-001 pin** — single store is foundational.
- **Per-memory global classification at save** — replaced by birth-path tagging +
  re-scope tool + cross-cutting triage at import.

---

## Open Questions (execution-time)

- **U1 verdict** — build / reduced-scope / stop — decided empirically.
- **Native-write hookability + backfill coverage/mis-scope-rate** — measured in U1.
- **Over-fetch width N** — how deep the search reaches (bounds which repo memories can
  be the K+1) — tuned in U4 against budget (free scope read makes N cheap, but it
  still bounds the envelope).
- **Relevance-floor threshold** for the extra slot (U4) — tuned so the K+1 is added
  only when genuinely relevant.
- **Triage bar** for re-import (U6).

---

## Sources & Research

- Origin: `docs/brainstorms/2026-06-26-repo-scoped-memory-recall-requirements.md`.
- Plan 001 (`docs/plans/2026-06-26-001-...`) — single-store pin; native writes land
  flat (`setup.sh:58-64`).
- Plan 002 (`docs/plans/2026-06-26-002-...`) — verified `seeded-recall` mechanics
  (top-K=3, BM25, ~6s budget, truncate-before-get), worktree→parent normalization,
  the U1 pre-flight + shared-module + re-gate discipline mirrored here, the
  cross-project-positive triage reused in U6, and the import mechanics.
- qmd check (this session): `qmd search --format json` returns
  `docid/score/file/line/title/snippet` — path but not frontmatter — the basis for
  KTD1 (scope in the path, read free from `file`). `qmd` `**/*.md` glob indexes
  `_scope/**` recursively.
- In-session verification: `hooks/seeded-recall.sh` (truncate-before-get, `min_score`
  plumbing), `scripts/memory-index-lint.sh` (non-recursive parity — why `_scope/**`
  is naturally excluded), `scripts/setup.sh` (flat-write pin), the canonical store,
  `~/.claude/projects/_archived-memory/`.
