---
title: Reflect Embed Indexing and Honest Tally - Plan
type: fix
date: 2026-08-14
revised: 2026-08-14
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-plan-bootstrap
origin: docs/handoff.md
---

# Reflect Embed Indexing and Honest Tally - Plan

**Revision note (2026-08-14).** This is revision 2, resolving every finding in
`docs/reviews/2026-08-14-consolidated-plan-review.md` (1 P0, 6 P1, 3 P2, 4 P3). The material
changes: a real-qmd end-to-end assertion now backs the stub test (F1), the tally collapses to
two honest values because qmd exposes no document count (F4), the foreign-safety invariant the
fix breaks is now restated rather than silently violated (F9), two verified shell traps are
mandated away (F10), release verification splits at the merge boundary (F11), and every
shell-file citation is corrected by +1 (F5).

**Product Contract preservation:** restructured, no scope change. R4 and R6 gained
qualifiers, R10 widened to cover one more file, R12 added for the end-to-end assertion. The
Goal Capsule objective narrowed to match what the requirements actually cover (removed-file
indexing was promised and never covered).

## Goal Capsule

- **Objective:** Make reflect Pass 8 index files added since a collection was registered
  before embedding them, and prevent its tally from treating successful collection visits as
  embedded-document counts.
- **Authority:** The operator-set decisions in KTD1-KTD6 govern implementation.
  `docs/handoff.md` is directional only, as it states at `docs/handoff.md:2-3`.
- **Execution profile:** Test-first bug fix with a deterministic qmd stub for call-order
  regression, a real-qmd assertion for the end-to-end invariant, an explicit production-code
  mutation check, documentation updates, and a patch release.
- **Stop conditions:** Stop if the installed `0.5.1` cache does not match the released source.
- **Tail ownership:** Pre-merge completion is source-tree green plus a clean-export harness
  run. Cache verification is post-merge and owned by U5.
- **Deferred:** Removed-file handling. `qmd update` also removes deleted files from the index,
  which would fix retired memories still surfacing in recall — but no requirement, unit, or
  Definition of Done item here covers it, and Spike S3 only observes it. Recorded as follow-up
  work, not claimed as a deliverable of this change.

---

## Product Contract

### Summary

Pass 8 must run one global `qmd update` before collection-scoped embeds so files added since a
collection was registered enter qmd's index before vectorisation. Its report must never convert
successful command exits into a document count: `embedded` is `0` only when every embed proved
no work, and `unknown` in every other case.

### Problem Frame

The reconciler calls `qmd embed -c "$1"` and increments `embedded` once when that command exits
successfully (`plugins/reflect/scripts/qmd-reconcile-collections.sh:54-66`). Collection
reconciliation reaches both `claude-memory` and every doc-store subdirectory through
`reconcile_one` (`plugins/reflect/scripts/qmd-reconcile-collections.sh:69-104`,
`:110-120`). No production path runs `qmd update` before those embeds (`:107-125`).

The harness already records the required qmd sequence when it adds fresh activation fixtures:
bare global `qmd update`, followed by collection-scoped `qmd embed`
(`plugins/reflect/tests/harness.sh:225-228`). Its earlier seeded-recall setup runs embed alone
(`plugins/reflect/tests/harness.sh:174-188`). That earlier block cannot validate indexing of
files created after collection registration, while the later block self-seeds the index and
therefore cannot detect omission of `qmd update` from the production reconciler.

The existing reconciler tests use a deterministic qmd stub because the assertions concern
reconciler behavior and real qmd is global and intermittent
(`plugins/reflect/tests/harness.sh:65-81`). The stub models `embed` as an unconditional success
and does not model `update` at all — an unmodelled subcommand falls to its `*) exit 1` default
(`plugins/reflect/tests/harness.sh:84-113`) — so it cannot expose either defect.

**The bug is real and recurring, not theoretical.** Three live occurrences in three days, each
caught by a declared memory trigger firing rather than by any test. The most recent was verified
by effect: after running `update` then `embed`, a distinctive phrase from each new memory
returned at 96% and 97% similarity, where the run would otherwise have reported
`embedded=5 failed=0` with all five memories unfindable.

### Requirements

**Indexing behavior**

- R1. A normal Pass 8 run must invoke bare global `qmd update` once before any collection-scoped
  `qmd embed` invocation.
- R2. The run must retain `qmd embed -c <collection>` after update because update indexes file
  membership while embed creates vectors.
- R3. Update and embed failures must remain non-fatal to collection traversal so one transient
  qmd failure cannot starve later doc-store collections; the current best-effort intent is
  documented at `plugins/reflect/scripts/qmd-reconcile-collections.sh:59-66` and per-collection
  continuation at `:110-120`.
- R4. `QMD_RECONCILE_NO_EMBED=1` must skip **both** the hoisted global `qmd update` and every
  collection-scoped embed. The flag is the script's fast-test interface (documented at
  `plugins/reflect/scripts/qmd-reconcile-collections.sh:18`, checked at `:54-58`); scoping it to
  embedding alone would leave a global re-index running in every existing stubbed assertion.

**Truthful reporting**

- R5. `embedded` must mean documents observed as embedded, never collections whose command
  exited zero.
- R6. `embedded` has exactly two values. It is `0` only when **every** embed this run — including
  any that failed — is accounted for and every accounted embed emitted the exact no-work line
  `✓ All content hashes already have embeddings.`. It is `unknown` in every other case, which
  includes any embed that failed, any embed whose output was not that line, and any run where a
  collection's outcome is not known. There is no numeric branch above zero: qmd exposes no
  document count (KTD3).
- R7. A non-zero embed exit must still emit the existing collection-specific non-fatal warning
  (`plugins/reflect/scripts/qmd-reconcile-collections.sh:62-66`), must not be counted as
  embedded work, and must force `embedded=unknown` per R6.

**Coverage and release**

- R8. A deterministic test must create a file after initial collection registration, invoke the
  production reconciler without any test-side `qmd update`, and prove the file becomes indexed
  and embedded in the stub's ledgers.
- R9. The new assertion must be observed failing before implementation, and must fail again when
  the production `qmd update` call is temporarily removed after implementation.
- R10. Pass 8 documentation, the reconciler script's own header contract, and all tally wording
  touched by the requested sweep must define observed effects rather than attempted steps, and
  must not claim an invariant the shipped script no longer holds.
- R11. The reflect plugin must bump from `0.5.0` to `0.5.1` in both release gates.
- R12. A real-qmd assertion must prove the end-to-end invariant the stub cannot: a memory file
  created **after** its collection was registered is retrievable by search after the production
  reconciler runs, with nothing in that test's own setup performing the `qmd update` under
  assertion. The stub proves call order; only this proves findability.

### Acceptance Examples

- AE1. Given an existing `claude-memory` collection, when a new memory file is written and the
  reconciler runs, then the qmd stub records update before embed and the new file reaches the
  embedded ledger without test setup calling update. Covers R1, R2, R8.
- AE2. Given three collections whose embed commands all return the no-work status line, when
  reconciliation completes, then the summary reports `embedded=0`, not `embedded=3`. Covers R5,
  R6.
- AE3. Given at least one successful embed whose output is not the no-work line, when
  reconciliation completes, then the summary reports `embedded=unknown`. Covers R5, R6.
- AE4. Given one collection whose embed command fails, when later collections remain, then the
  warning names the failed collection, later collections are still attempted, and the summary
  reports `embedded=unknown` even if every other collection reported no-work. Covers R3, R6, R7.
- AE5. Given the fixed test passes, when the production update invocation is temporarily
  removed, then AE1's assertion fails. Covers R9.
- AE6. Given a real qmd index with a registered collection, when a new file is written after
  registration and the production reconciler runs, then searching a distinctive phrase from that
  file returns it. Covers R12.

### Scope Boundaries

**In scope**

- The global update placement, collection-scoped embed behavior, output capture, and tally in
  `plugins/reflect/scripts/qmd-reconcile-collections.sh`, including that file's header contract.
- Deterministic reconciler coverage and one real-qmd end-to-end assertion in
  `plugins/reflect/tests/harness.sh`.
- Pass and tally wording in `plugins/reflect/skills/reflect/SKILL.md`.
- The two reflect release version fields.

**Out of scope**

- Repairing qmd itself or the separate seeded-recall cooldown/wedge behavior.
- Adding shell counters for model-performed Pass 2, Pass 6, or Pass 9 work. Those tallies are
  prose contracts, not variables in the reconciler.
- Treating an embed or update failure as fatal.
- Reworking the seeded-recall activation-floor scenario at
  `plugins/reflect/tests/harness.sh:218-230`; it remains a consumer-level test whose setup
  intentionally performs update and embed.

### Deferred to Follow-Up Work

- Removed-file handling: proving a retired memory stops surfacing in recall after `qmd update`.
  Spike S3 observes whether update reports removals; acting on it is separate work.
- A sibling flag that skips embedding but keeps indexing, now that the two steps are separate
  operations under R4.

---

## Planning Contract

### Key Technical Decisions

- **KTD1. Hoist one global update before collection traversal.** (session-settled: user-directed
  — chosen over calling update inside `embed_one`: `qmd update` has no collection flag, so
  per-collection calls would repeat a full global scan.) Add one guarded, best-effort update
  stage after qmd availability and counter initialization but before the first `reconcile_one`
  call at `plugins/reflect/scripts/qmd-reconcile-collections.sh:107-112`. Do not put it in
  `embed_one` at `:54-67`. Governs R1, R4.
- **KTD2. Preserve best-effort traversal for both update and embed.** (session-settled:
  user-directed — chosen over failing under `set -e`: a transient qmd failure must not skip
  remaining doc-store subdirectories.) Guard the global update with an explicit conditional so
  `set -euo pipefail` at `plugins/reflect/scripts/qmd-reconcile-collections.sh:26` cannot
  terminate the run. Keep each embed inside its existing conditional at `:62-66`. Governs R3, R7.
- **KTD3. The tally has two values and no parse-and-sum branch.** (session-settled:
  user-approved — chosen over parsing a document count from qmd output: qmd exposes no document
  count.) Verified observation of qmd's real output: `update` prints a **hash** count
  (`"21 unique hashes need vectors"`) and `embed` prints
  `✓ All content hashes already have embeddings.` when idle. One document can carry several
  content hashes, so publishing a hash count as `embedded=N` would overstate documents and
  relocate the same lie this change exists to remove. Capture each embed's combined output
  instead of discarding it at `:62`. Match the exact no-work line as zero for that collection;
  everything else — including every failure — makes the aggregate `unknown`. Never increment
  from an exit code. Governs R5, R6, R7.
- **KTD4. Model the production contract in the existing stub.** Extend the stub at
  `plugins/reflect/tests/harness.sh:84-113` with separate indexed and embedded ledgers, a
  recorded call ledger, and controllable failure modes. `collection add` registers a path and
  seeds the files present at that moment; `update` rescans every registered path; `embed -c`
  moves only indexed files for that collection into the embedded ledger. The add-time seeding is
  **not an assumption** — it matches real qmd, proven by a currently-passing test that adds a
  collection then embeds and recalls with no intervening update
  (`plugins/reflect/tests/harness.sh:174-195`). The stub keeps reconciler assertions off the
  global, intermittent real qmd the harness intentionally removed from this block (`:65-81`).
  Governs R8, R9.
- **KTD5. Back the stub with one real-qmd end-to-end assertion.** (New in revision 2, resolving
  F1.) The stub test proves the script calls `update` before `embed`. It cannot prove a memory
  becomes findable, because the plan authors the very stub semantics the assertion depends on —
  so if the premise were wrong the suite would stay green while memories stayed unfindable, which
  is the defect relocated into the test. Add one assertion against real qmd in the seeded-recall
  block, which already uses a real index, real files and real search. Its setup must not perform
  the `qmd update` under assertion. Governs R12.
- **KTD6. Two tally variables, and one mandated capture form.** (New in revision 2, resolving
  F10. Both traps verified by execution.) A single mixed-type variable is fatal: `embedded=unknown`
  followed by any `$((embedded + n))` exits 1 with `unknown: unbound variable` under `set -u`,
  killing the run before the summary prints and before the remaining doc-store collections are
  traversed — the exact starvation R3 forbids, caused by the honesty feature. Use a numeric
  `embedded_docs=0` that is the only thing arithmetic ever touches, plus a boolean
  `embedded_unknown=0`, rendered once at the summary line. Separately, the output-capture form
  decides behavior: a bare `out="$(qmd embed -c "$1" 2>&1)"` as its own statement returns the
  command's status and **aborts the whole script** under `set -e`, while `local out="$(...)"`
  returns `local`'s status and **silently masks the failure** so the warning and failed-tally
  branches never fire. Only `if out="$(...)"; then` is correct. Governs R3, R6, R7.
- **KTD7. Patch release through both gates; verification splits at the merge boundary.** (Revised
  in revision 2, resolving F11.) Bump `plugins/reflect/.claude-plugin/plugin.json:1-3` and
  `.claude-plugin/marketplace.json:60-66` to `0.5.1`. Both values gate delivery and must move
  together (`scripts/check-version-bumped.sh:17-19`, `:71-92`). The reflect cache is versioned
  per published release and populated by a marketplace refresh from the pushed repo, so a
  `0.5.1` cache directory **cannot exist pre-merge**. Pre-merge proof is a clean-export harness
  run; cache proof is post-merge. Governs R11.

### Tally Sweep Decision

The requested sweep is a documentation contract review, not more shell implementation. Pass 2
defines `updated`, `saved`, and trigger work as model actions and then states their tally in
prose (`plugins/reflect/skills/reflect/SKILL.md:117-174`). Pass 6 instructs the model to run
render and lint, then supplies `index_tightened=0|1` (`:217-223`). Pass 9 describes worktree
removal and supplies `worktrees_removed=N` (`:241-247`). The log format collects those
model-reported values (`:249-257`).

Revise only ambiguous wording so each tally names an effect:

- `updated`: memory files whose durable content or `last_used` field changed, not memories
  inspected.
- `saved`: new memory body files successfully written, not save attempts.
- `triggers_declared`: memories that actually received a valid trigger block; `:257` already
  states this effect and needs no behavior change.
- `index_tightened`: `1` only when Pass 6 changed the rendered `MEMORY.md`; `0` when the render
  was already compliant, even though render and lint ran.
- `worktrees_removed`: worktrees confirmed absent after removal, not removal commands attempted.
- `embedded`: `0` for a proven all-no-work run, otherwise `unknown` — replacing the unqualified
  numeric tally at `:233-239` and the numeric-only examples at `:249-263`.

### Parallelism and Sequencing

1. U1 (failing stub contract + real-qmd assertion) lands first; record its observed failure.
2. U2 (production script body) and U3 (documentation sweep) must run **sequentially, U2 then
   U3** — not in parallel. They share a file: U3 rewrites the header comment block of
   `plugins/reflect/scripts/qmd-reconcile-collections.sh` that U2 edits the body of. Running them
   concurrently risks a lost edit. U3's SKILL.md work is independent and may start any time.
3. Run the production-code mutation proof after the fixed tests pass. No source edit may run
   concurrently with that mutation.
4. U4 (version bump + pre-merge clean-export proof) runs only after script, tests, and
   documentation are final.
5. U5 (post-merge cache verification) runs after merge and a marketplace refresh. It is not a
   pre-merge gate.

### Runtime Spikes

These are execution-time confirmations. This planning run did not execute them. Their results can
no longer change the tally design — KTD3 settles it — so they exist only to confirm the literal
strings have not drifted.

#### Spike S1. Confirm `qmd update`'s output strings

```bash
TMP="$(mktemp -d)"; cd "$TMP"; qmd init; mkdir mem
printf '# first\nfirst token\n' > mem/first.md
qmd collection add --name reflect-embed-spike "$TMP/mem"
printf '# second\nsecond unique token\n' > mem/second.md
qmd update 2>&1 | tee qmd-update.out
```

Confirm the hash-count phrasing (`"N unique hashes need vectors"`) and the completion line are
unchanged. Do **not** build a document-count parser from it — the count is hashes, not documents.

#### Spike S2. Confirm `embed`'s no-work literal

```bash
qmd embed -c reflect-embed-spike 2>&1 | tee qmd-embed-work.out
qmd embed -c reflect-embed-spike 2>&1 | tee qmd-embed-noop.out
```

The second output must contain exactly `✓ All content hashes already have embeddings.` — that
literal is what the `embedded=0` branch matches. If it has drifted, update the matched literal in
the same change.

#### Spike S3. Observe deletion handling (informational only)

```bash
rm mem/second.md
qmd update 2>&1 | tee qmd-update-delete.out
qmd search "second unique token" -c reflect-embed-spike 2>&1 | tee qmd-search-delete.out
```

Record whether update reports removals and whether the removed file stops appearing. Do not
expand this change's scope on the result; file it as the deferred follow-up.

---

## Implementation Units

### U1. Failing reconciler contract, stub plus real qmd

- **Goal:** Make the harness expose missing global indexing and false collection-count reporting
  before production changes, and add the one assertion that proves findability rather than call
  order.
- **Requirements:** R1, R2, R5-R9, R12; R9's pre-fix red half only. Covers AE1-AE4, AE6.
- **Dependencies:** none. S1/S2 confirm literals but do not gate this unit.
- **Files:** `plugins/reflect/tests/harness.sh`.
- **Approach:**
  1. Extend the qmd stub at `plugins/reflect/tests/harness.sh:84-113` to model global `update`,
     per-collection index membership, per-collection embeddings, a recorded call ledger, output
     modes (no-work line vs other successful output), and controllable update/embed failure.
  2. Add a reconciler scenario that runs with embedding **enabled**, rather than relying only on
     the `QMD_RECONCILE_NO_EMBED=1` currently exported at `:132-135`.
  3. After initial registration, create a second memory file, invoke
     `qmd-reconcile-collections.sh` directly, and assert the call ledger shows update before
     embed and the embedded ledger contains the second file.
  4. Do not call the stub's `qmd update` from test setup. Reset or delimit the call ledger
     immediately before the production invocation so no earlier setup call can be mistaken for it.
  5. Add the tally scenarios: all-no-work, successful-but-not-no-work, failed embed, and the
     combined failure-plus-no-op case.
  6. Add the real-qmd end-to-end assertion (KTD5) in the seeded-recall block: with a registered
     collection, write a new file **after** registration, run the production reconciler, and
     assert a distinctive phrase from that file is returned by search. Nothing in this scenario's
     own setup may run `qmd update`.
- **Patterns to follow:** keep the stub work in the always-runnable stubbed reconciler block —
  the harness explains why real qmd state is global and intermittent at `:65-81`. Use the existing
  `check` helper at `plugins/reflect/tests/harness.sh:27`. The real-qmd assertion follows the
  seeded-recall block's existing shape (`:174-230`).
- **Execution note:** Add and run the new assertions against unchanged production code first, and
  preserve the failing output as implementation evidence. A deliberate-fail flag is not sufficient.
- **Test scenarios:**
  1. Existing collection plus newly added file: production reconciliation causes one global update
     before any embed, and the new file reaches the embedded ledger.
  2. Self-seeding trap guard: the scenario's setup contains no `qmd update`, and the call ledger
     proves the invocation came from `qmd-reconcile-collections.sh`.
  3. First-run new collection: a file present when the collection is created reaches the embedded
     ledger on that same run (guards the add-time seeding KTD4 relies on).
  4. Multiple collections: exactly one global update occurs while each valid collection receives
     one scoped embed.
  5. All embeds emit the no-work line: summary reports `embedded=0`, independent of collection
     count.
  6. A successful embed whose output is not the no-work line: summary reports `embedded=unknown`.
  7. One embed fails: its warning names the collection, a later collection still embeds, and the
     summary reports `embedded=unknown`.
  8. Combined case — one embed fails while every other collection reports the no-work line: the
     summary reports `embedded=unknown`, never `embedded=0`.
  9. Update fails: later scoped embeds are attempted and the run remains best-effort.
  10. `QMD_RECONCILE_NO_EMBED=1`: neither update nor embed is called, preserving the fast test mode.
  11. Real qmd: a file created after registration is returned by search after the production
      reconciler runs.
- **Verification:** the new-file stub assertion and the real-qmd assertion both fail against
  current production code. Existing collection-creation, idempotency, foreign-safety and
  qmd-absent assertions at `plugins/reflect/tests/harness.sh:120-168` remain green after the stub
  gains state.

### U2. Global update and truthful embed tally

- **Goal:** Index file changes once per run, embed every reconciled collection, and report only
  observed document effects — without introducing a shell trap that kills the run.
- **Requirements:** R1-R7; R9's post-fix mutation half. Covers AE5. Implements KTD1, KTD2, KTD3,
  KTD6.
- **Dependencies:** U1's observed pre-fix failure.
- **Files:** `plugins/reflect/scripts/qmd-reconcile-collections.sh`.
- **Approach:**
  1. Add one best-effort bare `qmd update` stage before the memory and doc-store traversal at
     `plugins/reflect/scripts/qmd-reconcile-collections.sh:107-120`, guarded by an explicit
     conditional, and skipped when `QMD_RECONCILE_NO_EMBED=1` per R4.
  2. Replace the single `embedded` counter initialised at `:48` with `embedded_docs=0` and
     `embedded_unknown=0` per KTD6. Arithmetic touches `embedded_docs` only.
  3. Keep `embed_one` collection-scoped and non-fatal at `:54-67`, capturing output with the
     mandated `if out="$(qmd embed -c "$1" 2>&1)"; then` form. Do **not** use a bare
     `out="$(...)"` statement (aborts under `set -e`) or `local out="$(...)"` (masks the failure).
  4. Remove `embedded=$((embedded + 1))` at `:63`.
  5. On success, match the exact no-work literal; anything else sets `embedded_unknown=1`. On
     failure, replay the captured output to stderr, emit the existing collection warning, and set
     `embedded_unknown=1`.
  6. Render the field once at the summary line, preserving its location at `:125`:
     `embedded=unknown` when the flag is set, else `embedded=$embedded_docs`. Preserve the
     collection-creation failure exit behavior at `:128-130`.
- **Patterns to follow:** the existing explicit conditional around embed keeps the function safe
  under `set -e` (`:59-66`); the outer per-collection continuation is at `:110-120`.
- **Execution note:** implement only after U1 was observed failing. After green, temporarily
  remove the new production `qmd update` invocation — not a test flag — and rerun U1. The
  new-file assertion must fail. Restore and rerun to green before any other edit.
- **Test scenarios:** U1 owns the behavioral scenarios. U2 must make all eleven pass without
  weakening their assertions.
- **Verification:** the pre-fix failures become green. Deleting or commenting out the new bare
  `qmd update` call, with the tests unchanged, makes the new-file assertion red; restoration
  returns it to green. A run where one embed fails and the rest report no-work prints
  `embedded=unknown` and still traverses every collection.

### U3. Pass 8, invariant, and tally contract documentation

- **Goal:** Make the skill and the script's own header describe the real update-then-embed
  mechanism, its true blast radius, and effect-based tally semantics.
- **Requirements:** R10. Implements the Tally Sweep Decision.
- **Dependencies:** U2's final tally contract.
- **Files:** `plugins/reflect/skills/reflect/SKILL.md`,
  `plugins/reflect/scripts/qmd-reconcile-collections.sh` (header comment block only, `:3-13`).
- **Approach:**
  1. **Restate the foreign-safety invariant the fix breaks.** The script header at `:3-7` claims
     "Only ever touches `claude-`-prefixed collections, so foreign collections (openclaw, Slate,
     global) are never modified," and `SKILL.md:236` makes the matching claim about the ~24.8k-doc
     backlog. A bare `qmd update` re-indexes every collection in the resolved config. Rewrite both
     to state: the run performs one global re-index pass that necessarily covers every collection
     in the resolved config, while **embedding and collection creation** remain restricted to
     `claude-`-prefixed collections. Note the cost: `setup.sh:60-62` invokes the reconciler with
     embedding enabled, so `/reflect-setup` pays a full global re-index on first run.
  2. Replace the embed-only Pass 8 mechanism at `plugins/reflect/skills/reflect/SKILL.md:233-239`
     with one global update followed by collection-scoped embeds, including the best-effort
     behavior and the `0`-or-`unknown` tally contract.
  3. Update the REFLECT.log schema and examples at `:249-263` so `embedded=unknown` is valid and
     no example implies collections equal documents.
  4. Tighten only the effect definitions named in the tally sweep: Pass 2 at `:117-174`, Pass 6 at
     `:217-223`, Pass 9 at `:241-247`.
- **Patterns to follow:** preserve the skill's distinction between a step running and producing an
  effect, already explicit for `compounded=0` at `:196-215` and trigger tallies at `:251-257`.
- **Test scenarios:** `Test expectation: none — this unit changes model-facing contract text and a
  code comment; U1 tests the shell-produced tally.` Manual review must confirm every named tally
  answers "what changed?" rather than "what ran?", and that no document still claims foreign
  collections are untouched.
- **Verification:** Pass 8 no longer claims embed alone makes new files findable. Neither the
  script header nor SKILL.md asserts an invariant the shipped script violates. Every swept tally
  has an effect definition, and no new shell counter is introduced for model-reported passes.

### U4. Version bump and pre-merge release proof

- **Goal:** Move both release gates together and prove the shipped tree is green from a clean
  export, without depending on a cache that cannot exist yet.
- **Requirements:** R11. Implements KTD7's pre-merge half.
- **Dependencies:** U1-U3 complete and green.
- **Files:** `plugins/reflect/.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`.
- **Approach:**
  1. Change both `0.5.0` values at `plugins/reflect/.claude-plugin/plugin.json:1-3` and
     `.claude-plugin/marketplace.json:60-66` to `0.5.1`.
  2. Run `scripts/check-version-bumped.sh`, whose contract requires both fields to move together
     (`:17-19`, `:71-92`).
  3. Run the harness once from a clean `git archive HEAD` export of `plugins/reflect` at a path
     outside the worktree, so the pre-merge proof exercises only committed content.
- **Patterns to follow:** the delivery guard explains that merge without a version bump leaves
  installs on old code (`scripts/check-version-bumped.sh:1-19`).
- **Test scenarios:**
  1. Both manifests report exactly `0.5.1`.
  2. The version check passes with shipped reflect files changed.
  3. The harness passes from the clean export, including the no-self-seeding indexing assertion,
     the real-qmd findability assertion, and the tally scenarios.
- **Verification:** both gates agree at `0.5.1`, the version check is clean, and the clean-export
  harness run is green. Do **not** claim cache verification here.

### U5. Post-merge cache verification

- **Goal:** Prove the installed artifact is the artifact tested, once the release exists.
- **Requirements:** R11. Implements KTD7's post-merge half.
- **Dependencies:** U4 merged to `shrimpshack` main and pushed; marketplace refreshed.
- **Files:** none — this unit verifies, it does not edit.
- **Approach:**
  1. Update/install reflect `0.5.1`, then compare the shipped plugin files with
     `~/.claude/plugins/cache/shrimpshack/reflect/0.5.1`.
  2. Invoke the harness and focused reconciler checks using scripts from the cache root, not the
     worktree source path.
  3. Run the real-qmd smoke against an isolated fixture: make a file added after registration
     searchable after reconciliation, then run the cached reconciler a **second** time and assert
     the summary line contains `embedded=0`. This is the only place the no-work literal the parser
     matches meets real qmd output, so it is an assertion, not a spike note.
- **Patterns to follow:** treat the cache as the delivery surface, per
  `scripts/check-version-bumped.sh:1-19`.
- **Test scenarios:**
  1. Cached `scripts/qmd-reconcile-collections.sh`, `tests/harness.sh`, and
     `skills/reflect/SKILL.md` match the released source byte-for-byte.
  2. The cache-path harness passes.
  3. A file added after registration is searchable after a cache-path reconciler run.
  4. A second cache-path run reports `embedded=0`.
- **Verification:** source-to-cache match for every modified shipped file, green cache-path
  harness, and an observed `embedded=0` from real qmd. Note that running the harness from the
  cache root places its repo root inside `~/.claude`; read any worktree-fold assertion failures
  there as environmental, not release, failures.

---

## Verification Contract

1. **Spike confirmation:** S1 and S2 confirm the qmd output literals are unchanged. Their results
   cannot alter the tally design (KTD3); a drifted literal means updating the matched string in
   the same change.
2. **Pre-fix red:** run the focused reconciler harness after U1 and before U2. Both the new-file
   stub assertion and the real-qmd findability assertion must fail while existing assertions
   continue to run.
3. **Fixed green:** run `bash plugins/reflect/tests/harness.sh`. All reconciler, real-qmd, and
   existing plugin assertions pass.
4. **Load-bearing mutation:** remove only the new production bare `qmd update` invocation. Rerun
   and observe the new-file assertion fail. Restore production code and rerun to green.
5. **Failure behavior:** use the stub controls for update failure and per-collection embed
   failure. Confirm traversal continues, the warning names the collection, and the tally reports
   `unknown` — including in the combined failure-plus-no-op case.
6. **Shell-trap guard:** confirm no code path assigns a non-numeric value to a variable used in
   `$(( ))`, and that embed output is captured only via `if out="$(...)"; then`.
7. **Release gates:** run `scripts/check-version-bumped.sh` against the intended base and confirm
   plugin and marketplace versions agree.
8. **Pre-merge export proof:** the harness passes from a clean `git archive HEAD` export of
   `plugins/reflect` outside the worktree.
9. **Post-merge cache proof (U5, not a pre-merge gate):** after installing `0.5.1`, rerun the
   harness from the cache and observe both a searchable post-registration file and an
   `embedded=0` second run.

No verification in this plan was run during planning; this session had no shell or qmd execution
capability inside the planning pass.

---

## Risks and Dependencies

- **Global re-index blast radius:** bare `qmd update` covers every collection in the resolved
  config, including foreign ones. Mitigation: one call per run, never per collection, and U3
  restates both documents that currently claim otherwise rather than leaving a false invariant in
  the shipped code.
- **First-run cost:** `/reflect-setup` invokes the reconciler with embedding enabled
  (`setup.sh:60-62`), so a machine with a large global index pays a full re-index on first run.
  Documented in U3 rather than mitigated.
- **Literal drift:** the `embedded=0` branch depends on one exact qmd string, and every stubbed
  test for it is green by construction. Mitigation: U5's second-run real-qmd assertion is the one
  place the literal meets real output.
- **Unstable qmd output generally:** human-readable output may change between versions.
  Mitigation: the tally never parses a count, so only the single no-work literal is exposed.
- **Output capture hiding diagnostics:** capturing combined output could suppress useful error
  text. Mitigation: replay captured output to stderr on failure alongside the collection warning.
  Successful-embed output was already discarded before this change, so nothing an operator sees
  today is lost.
- **Coverage asymmetry from R4:** because `QMD_RECONCILE_NO_EMBED=1` now skips update too, every
  pre-existing stubbed assertion runs with update skipped. Only the new scenarios exercise the
  update path, so they must not be weakened.
- **Cache drift:** a source-only fix leaves the live plugin unchanged. Mitigation: U5 treats the
  `0.5.1` cache as the final verification target, post-merge.

---

## Definition of Done

**Pre-merge**

- R1-R12 are satisfied and AE1-AE6 pass.
- One global update occurs before scoped embeds, with no per-collection global rescans.
- Update and embed failures remain non-fatal to later collection traversal.
- `embedded` is `0` only for a proven all-no-work run and `unknown` in every other case,
  including any failed embed. No code path performs arithmetic on a non-numeric value.
- Embed output is captured only via `if out="$(...)"; then`.
- The new stub assertion contains no setup-side `qmd update` and was observed failing before the
  fix; the real-qmd findability assertion was likewise observed failing first.
- Removing the production update call makes the unchanged assertion fail; restoring it returns
  the suite to green.
- No shipped document claims foreign collections are never modified.
- Other reflect tallies are clarified as observed model-reported effects, with no unrelated shell
  changes.
- Reflect is `0.5.1` in both manifests and `scripts/check-version-bumped.sh` is clean.
- The harness passes from a clean `git archive HEAD` export outside the worktree.
- Temporary mutation code, spike fixtures, and dead-end experiments are absent from the final
  diff.

**Post-merge (U5)**

- Modified shipped files in the installed `0.5.1` cache match source byte-for-byte.
- The cache-path harness passes.
- A cache-path run makes a post-registration file searchable, and a second run reports
  `embedded=0`.
