---
title: "A refusal log and a \"refuses and writes nothing\" test must be reconciled, not one picked over the other"
date: 2026-10-19
category: best-practices
module: plugins/auto
problem_type: best_practice
component: testing_framework
severity: medium
applies_when:
  - "merging a branch that journals refused approvals into a main whose tests assert a refused verb writes nothing"
  - "a programme verb raises a module-specific error type that the refusal catch in _write does not list"
  - "a test compares a whole-home file hash before and after a refused verb"
resolution_type: test_fix
related_components:
  - tooling
tags: [approval-refused, refusal-journal, writes-nothing, merge-conflict, error-types, programme-store, mutation-check]
---
# A refusal log and a "refuses and writes nothing" test must be reconciled, not one picked over the other

## Context

PR #112 "feat(auto): show each task's path and make the programme contract interactive" journals one `approval_refused` row whenever a typed-prompt approval is refused. The contract view reads that row to show "refused" and the reason. main gained #111 "PM operating contract", whose corrections and carry-over tests assert that a refused verb "refuses and writes nothing". They check this with a hash of every file in the programme home. After #113 "Programme durability", the journal and the record both live in `programme.db`, so the refusal row changes the hash and those tests fail.

Two easy resolutions are both wrong:

- **Drop the log.** The contract view silently loses its "refused" state.
- **Loosen the tests** to "the verb exited 1". They then stop proving that a refusal changes nothing it governs.

A second defect hid behind the first. The refusal catch in `_write` listed only `ProgrammeError` and `ValueError`. #111's verbs refuse with `programme_terms.TermsError` and `programme_decisions.DecisionError`. Some refused approvals were therefore logged and others were not, depending on which module raised the refusal.

## Guidance

1. **State the invariant the test was really guarding**, then test exactly that. Here it is: the record is unchanged, every journal row other than the refusal is unchanged, and exactly one `approval_refused` row was added. A file hash of the whole home over-specifies once the store holds both the record and the journal.

   ```bash
   governed() {   # hash of the record plus every non-refusal journal row
     "$PY" - "$AUTO_ROOT" "$RUN" <<'EOF'
   ...
   rec = core.read_run_record(ph.home_path(run), run)
   rows = [r for r in pj.read(run) if r.get("kind") != "approval_refused"]
   print(hashlib.sha256(json.dumps([rec, rows], sort_keys=True, default=str).encode()).hexdigest())
   EOF
   }
   # refused: exit 1, governed() unchanged, approval_refused count + 1
   ```

2. **Make the refusal catch cover every domain refusal type**, but not infrastructure errors. In `plugins/auto/lib/programme.py`'s `_write`:

   ```python
   except (ProgrammeError, ValueError, programme_terms.TermsError, programme_decisions.DecisionError) as exc:
   ```

   Keep `RunRecordError` and `StoreError` out of the catch. They are failures to write, not refused approvals, and logging them as refusals would show Shawn a false "refused".

3. **Journal the refusal after the store write has failed, never inside it.** A journal append inside a store write deadlocks.

4. **Prove the narrowed test still bites.** With `_journal_refusal` turned into an early `return`, the corrections tests went from 42/0 to 28/14 and carry-over from 41/0 to 34/7. Without that check, a narrowed test can quietly pass vacuously.

## When this applies

Use this whenever one side of a merge adds an audit or log row on a failure path, and the other side asserts that the failure path writes nothing. Reconcile the two into one invariant that excludes only the audit row, and check every error type that reaches the failure path.
