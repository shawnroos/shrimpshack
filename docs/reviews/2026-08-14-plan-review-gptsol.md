# Plan review: Reflect embed indexing and honest tally

**Verdict: no — the plan is not safe to implement as written.** The main existing-collection test can be made load-bearing and the masking trap is explicitly avoided, but the plan leaves first-run collection correctness dependent on an unproven stub behavior and can still emit a falsely precise `embedded=0` after an embed failure. Those gaps undermine the two guarantees this change is meant to establish.

## Findings

### P1 — First-run collections are outside the proposed update and are not given a required embedding assertion

**Anchor:** `docs/plans/2026-08-14-001-fix-reflect-embed-index-new-memories-plan.md:89` (KTD1), `:190-198` (U1 test scenarios), and `:272` (New collection timing risk)

**Verified by reading:** The proposed global `qmd update` runs before traversal. Production creates a missing collection later inside `reconcile_one`, immediately before `embed_one` (`plugins/reflect/scripts/qmd-reconcile-collections.sh:80-102`). The real harness’s initial seeded-recall setup also relies on `collection add` making the collection’s initial files available to a following embed without an update (`plugins/reflect/tests/harness.sh:173-186`), but that block uses real qmd and does not assert index membership separately. The plan’s required U1 scenarios assert the post-registration-file case and collection creation, but none requires that a file present in a newly created collection reaches the embedded ledger on that same run (`plan:190-198`). Only the Risks section says U1 “must retain” such a scenario (`plan:272`), even though no such reconciler scenario currently exists to retain.

**Concrete failure:** If real `qmd collection add` registers a path without indexing its existing files—or that behavior changes—the hoisted update sees no new collection, the later add creates it, and its immediate embed has no indexed documents. Pass 8 finishes while first-run memories remain unfindable. The proposed stub can hide this because KTD4 says `collection add` “may seed its current files” (`plan:92`), allowing the test model to assume the exact behavior that needs proof.

**Required plan change:** Make initial-file seeding a verified qmd prerequisite from a runtime spike, and make U1 require a first-run assertion that a file present before production reconciliation reaches the embedded ledger. If qmd does not guarantee add-time indexing, the sequence must change so each newly added collection is indexed before its first embed; a single update before traversal cannot satisfy that case.

**Runtime command needed:** An isolated `qmd collection add --name <name> <path>; qmd embed -c <name>; qmd search <unique-token> -c <name>` with no intervening `qmd update` would settle the real-qmd prerequisite.

### P1 — An embed failure can still produce the knowingly false document tally `embedded=0`

**Anchor:** `docs/plans/2026-08-14-001-fix-reflect-embed-index-new-memories-plan.md:48-50` (R5-R7), `:186-196` (U1 tally scenarios), and `:206-215` (U2 tally algorithm)

**Verified by reading:** U2 sets `embedded=0` when every *successful* embed emits the no-work line and excludes failed embeds from the tally. U1 separately tests no-op output and a failed embed, but does not define or assert the aggregate for a run containing both (`plan:193-196`). Production deliberately treats embed failure as non-fatal (`plugins/reflect/scripts/qmd-reconcile-collections.sh:58-65`).

**Concrete failure:** One collection can embed one or more documents and then exit non-zero, while all other collections report the no-work line. Under the proposed algorithm, the failed command contributes nothing and the successful commands contribute zero, so the summary reports `embedded=0` even though documents may have been embedded. That violates R5’s promise that the number is an observed document effect and recreates a falsely precise green-looking tally.

**Required plan change:** Define any embed failure without a proven count as making the aggregate `embedded=unknown` (while preserving the existing warning and traversal). Add a combined failure-plus-no-op assertion. Only retain a numeric aggregate when every collection’s effect is known.

### P2 — The spike permits a content-hash count to be labeled as a document count

**Anchor:** `docs/plans/2026-08-14-001-fix-reflect-embed-index-new-memories-plan.md:138-147` (Spike S2) and `:202-210` (U2 tally contract)

**Verified by reading:** R5 defines `embedded` as documents, but S2 accepts an integer tied to “documents/content hashes embedded.” Those are not established as the same unit in the plan.

**Concrete failure:** If one document produces multiple content hashes or chunks, summing the hash count and publishing it as `embedded=N` overstates embedded documents. The new tally would remain structurally misleading despite no longer counting collections.

**Required plan change:** Accept only an output field explicitly defined by qmd as a document/file count. If qmd reports hashes or chunks, either report `unknown` or rename the field and update its contract and consumers accordingly.

## What I checked and found sound

- **Proposed test’s main pre-fix/post-fix path:** Verified by reading the current stub and plan. Today the stub’s `embed)` case exits 0 unconditionally (`plugins/reflect/tests/harness.sh:88-91`) and has no `update` case, so production’s current embed increments once per collection and cannot place a post-registration file in a modeled embedded ledger. With U1’s proposed stateful cases implemented literally, initial registration seeds only the first file; the second file is then created; unchanged production calls `embed -c` without `update`, so the second-file membership assertion is false, `check` increments `FAIL`, and the harness exits 1 at `plugins/reflect/tests/harness.sh:1163-1164`. After production adds the bare update, the stub’s proposed `update` case rescans registered paths before `embed -c`, the second file reaches both ledgers, and that assertion exits 0. Removing the production update again makes it fail. This conclusion is conditional on implementing the stub semantics and assertion exactly as specified; I did not run the harness.
- **Masking trap:** Verified by reading. U1 explicitly forbids test-side `qmd update` and requires a call ledger (`plan:184-191`). The stub remains on `PATH` only through the reconciler block (`plugins/reflect/tests/harness.sh:115-161`); the later real-qmd setup-side update at `plugins/reflect/tests/harness.sh:223-226` cannot satisfy the earlier ledger assertion. The implementation should reset or delimit the ledger immediately before the production invocation so earlier setup calls cannot be mistaken for it.
- **Shell feasibility:** Inferred from the stated design, not executed. `if output="$(qmd embed -c "$name" 2>&1)"; then ... else ... fi` is safe under `set -euo pipefail`, preserves the command status for branching, and permits replaying captured failure output to stderr. A string value `embedded=unknown` is also safe if the implementation stops doing arithmetic on that variable. The exact implementation still needs `bash plugins/reflect/tests/harness.sh` to verify this.
- **REFLECT.log consumers:** A repository-wide text search found no executable parser that requires a numeric `embedded` value; current references are the skill and historical docs. Updating the live schema and examples in `plugins/reflect/skills/reflect/SKILL.md:249-263` therefore appears sufficient inside this repository. External consumers remain unknown.
- **SKILL.md citations:** Spot-checked all cited regions. Pass 2 behavior and tally are at `plugins/reflect/skills/reflect/SKILL.md:117-174`; Pass 6 and `index_tightened` are at `:217-223`; Pass 8 and its numeric tally are at `:233-239`; Pass 9 and `worktrees_removed` are at `:241-247`; the log schema/examples are at `:249-263`; `compounded=0` semantics are at `:196-215`; and trigger-effect wording is at `:251-257`. The citations are substantively accurate, though some ranges split behavior from its tally.
- **Release gates:** Verified by reading. Reflect is `0.5.0` in both `plugins/reflect/.claude-plugin/plugin.json:1-3` and `.claude-plugin/marketplace.json:60-66`. `scripts/check-version-bumped.sh:45-92` requires changed shipped plugin content to bump `plugin.json` and match the marketplace version.
