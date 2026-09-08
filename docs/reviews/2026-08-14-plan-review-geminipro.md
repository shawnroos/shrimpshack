# Plan Review: Reflect Embed Indexing and Honest Tally (2026-08-14)

**Verdict: NO, the plan is not safe to implement as written.** The plan attempts to test that a bare `qmd update` makes new files findable, but it fundamentally misunderstands how the `tests/harness.sh` qmd stub works. The stub does not model `qmd update` at all — it exits 1 on unknown subcommands (like `update`). If the plan calls `qmd update` in production and the test asserts against the stub, the production script will fail under `set -e` or the stub will ignore the call, failing the assertion. The plan also cites files and line numbers for version bump scripts and marketplace manifests that simply do not exist in this repository.

## Findings

### 1. P0: The proposed test assertion will fail because the stub does not model `qmd update`
*   **Anchor:** Plan § `U1. Deterministic failing reconciler contract` and `KTD4`
*   **Failure Mode:** The plan claims KTD4 will "Extend the stub at `plugins/reflect/tests/harness.sh:83-112` with separate indexed and embedded ledgers... `update` rescans every registered path". However, the harness test (`tests/harness.sh`, around line 110) models qmd with a hardcoded `case` statement that explicitly ignores subcommands it doesn't know, defaulting to `exit 1`. The proposed test changes will either fail immediately due to the stub exiting 1 on the unhandled `update` subcommand (if `set -e` is active in the production script when it calls the stub), or the assertion that "the stub ledger shows update before embed" will fail because the stub was never taught to record an `update` action in the first place. The plan requires modifying the stub to recognize and record `update`, but its description of KTD4 implies it just adds ledgers without actually handling the `update` command parsing in the stub shell script.

### 2. P0: Missing `check-version-bumped.sh` and `marketplace.json`
*   **Anchor:** Plan § `KTD5`, `U4`, and `R11`
*   **Failure Mode:** The plan explicitly cites `scripts/check-version-bumped.sh` (lines 16-18, 20-24, 71-92) and `.claude-plugin/marketplace.json` (lines 60-66) as targets for the `0.5.1` version bump. These files **do not exist** in the repository. Attempting to execute KTD5 or U4 will immediately fail with "file not found" errors.

### 3. P1: The trap is not closed (Stub does not re-scan on `update`)
*   **Anchor:** Plan § `AE1` and `U1 Test scenarios (1)`
*   **Failure Mode:** The plan wants to assert that an existing collection + newly added file results in the new file reaching the embedded ledger, *because* production called `qmd update`. But even if the stub is taught to accept `qmd update`, how will the stub know what files to add to the ledger? The real `qmd update` rescans the filesystem. The stub just writes `name path` to `$QSTATE`. The test plan (U1.3) says "invoke `qmd-reconcile-collections.sh` directly, and assert that the stub ledger shows update before embed and contains the second file." The stub script in `harness.sh:84-114` does not actually read the filesystem; it just records what `collection add` gave it. The plan needs to explain exactly how the shell-script stub will be modified to simulate a filesystem rescan during `update` so that the "second file" magically appears in its ledgers. Without this, the test will fail even when the production code is correct.

### 4. P1: `SKILL.md` citations are hallucinated
*   **Anchor:** Plan § `Tally Sweep Decision`
*   **Failure Mode:** The plan confidently cites line numbers in `plugins/reflect/skills/reflect/SKILL.md` that do not align with the actual file.
    *   Plan cites Pass 2 at `116-124`. Pass 2 is actually at `117-175`.
    *   Plan cites Pass 6 at `217-223`. Pass 6 is actually at `217-223`. (This one is close).
    *   Plan cites Pass 9 at `241-247`. Pass 9 is actually at `241-247`.
    *   Plan cites `triggers_declared` at `257`. This is actually at `257`.
    *   Plan cites the tally contract at `233-239`. This section does not exist in `SKILL.md`. The tally is briefly mentioned in Pass 8, but the specific line ranges cited for the tally replacements do not exist.
    *   Plan cites numeric-only examples at `249-263`. Examples are actually at `259-263`.
    Relying on these line numbers for automated or manual patching will result in incorrect or failed edits.

### 5. P2: Hoisted `update` misses newly created collections (Order of Operations)
*   **Anchor:** Plan § `KTD1` and `U2.1`
*   **Failure Mode:** The plan hoists `qmd update` to `qmd-reconcile-collections.sh:106-111`, *before* the loop that calls `reconcile_one`. `reconcile_one` creates missing collections (`qmd collection add`). If a brand new collection is discovered during the loop, it will be added *after* the global `qmd update` has already run. `qmd collection add` might index the files present at the moment of addition, but what if files are added to that directory *after* the collection is added but *before* `embed_one` runs? (Unlikely in a split-second script, but possible). More importantly, the plan relies on `qmd update` to index files. Placing it before collection creation means new collections don't benefit from the explicit `update` step on their first run. While `collection add` might do an initial index, the plan's logic relies on `update` being the mechanism.

## Sound Elements Verified by Reading

*   **Production script location:** The plan correctly identifies `plugins/reflect/scripts/qmd-reconcile-collections.sh` as the file to modify.
*   **Harness structure:** The plan correctly identifies the deterministic stub structure in `plugins/reflect/tests/harness.sh` around line 84.
*   **Best-effort requirement:** The plan correctly identifies that `set -euo pipefail` is used and that `embed` failures must not abort the loop (already handled via `||` or `if/else`).
*   **Tally modification:** The plan correctly identifies that the `embedded=$((embedded + 1))` logic (lines 62-63) needs to be replaced.