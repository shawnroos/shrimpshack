---
title: "A routing decision made before taking a lock must be re-checked under it"
date: 2026-10-19
category: logic-errors
module: plugins/auto
problem_type: logic_error
component: tooling
symptoms:
  - "a record write that started while promote ran reported success, but the change was in the JSON export only and never reached programme.db"
  - "a typed prompt or a claim appended while promote ran was later absorbed as a foreign_write row and refused as approval"
  - "the first fix closed the record-write path and left the journal and claims append path open until a second review found it"
root_cause: concurrency
resolution_type: code_fix
severity: high
tags: [programme, promote, flock, check-then-act, routing, migration, foreign-write, twin-path]
---

# A routing decision made before taking a lock must be re-checked under it

## Problem

Programme writes in `plugins/auto` go to one of two places: the legacy JSON files, or the SQLite store behind `programme_authority`. Each writer decides which one by asking "is this home promoted?", and only then takes the lock for the legacy path. `promote` migrates a home from JSON to the store while it holds those same locks. A writer that asked the question just before `promote` started got the answer "legacy", waited on the lock, and then wrote into the JSON files that `promote` had just turned into an export.

## Symptoms

- Record writes (review finding #10, "Write racing promote lands in the JSON export and is lost"): the writer reported success, but its change was only in the export. The store never got it.
- Journal and claims appends (round-2 finding P2-1, "journal and claims appends still race promote"): a typed prompt, request or claim landed in `journal.jsonl` or `claims.jsonl` after promotion. The next authority write absorbed it as a `foreign_write` row, and foreign rows are refused as approval. So a real typed approval was silently turned into a refusal.

## What Didn't Work

- **Checking `promoted` once, before the lock.** This is the original shape of both paths. The check is correct when it runs, but `promote` can start between the check and the lock. The waiting writer then acts on an answer that is no longer true.
- **Fixing one path only.** The first fix (commit ce4a1a69 on branch feature/programme-durability-plan, unpushed as of this writing, so the SHA may change on merge) added the re-check to record writes in `run_record_core._with_locked_run_record`. The journal path `programme_journal.append_row` has the same check-then-lock shape and kept it. It stayed open until the second review round, and by then the foreign-write refusal added in the same commit made the leftover race worse: lost rows became refused approvals. (Matches the memory "harden one loop, harden its twin" (auto memory [claude]).)

## Solution

Re-check the routing decision inside the lock. If the home is now promoted, raise a private sentinel exception, let the lock release, and then route the same write through the authority.

Record writes, `plugins/auto/lib/run_record_core.py` (`_with_locked_run_record`):

```python
def body():
    if _programme_authority(repo_root, run_id) is not None:
        raise RoutedToAuthority(run_id)
    ...  # legacy read-modify-write

try:
    return _flock_run(lpath, body)
except RoutedToAuthority:
    if not reroute:
        raise
return _programme_authority(repo_root, run_id).mutate(repo_root, run_id, mutate)
```

`programme_authority.write` calls this with `reroute=False` from its legacy branch, catches `RoutedToAuthority`, and continues into its own store path, so a record change and its journal row still commit together.

Journal and claims appends, `plugins/auto/lib/programme_journal.py` (`append_row`), commit 7a1af0e0 on the same branch (also unpushed):

```python
if not _promoted(run_id):
    def body():
        if _promoted(run_id):
            raise _RoutedToAuthority()
        _write_line(path, row)
        return row
    try:
        return _locked(path, body)
    except _RoutedToAuthority:
        pass
return _authority().append_row(run_id, row, channel=channel, provenance=provenance, guard=guard)
```

The re-routed write keeps the same channel, provenance and guard, so a typed prompt is stored as a native row and still approves. `append_to`, which writes to an explicit file path and cannot re-route, re-checks under the lock and refuses instead.

## Why This Works

`promote` takes the run lock and then the journal lock (`plugins/auto/lib/programme_import.py`, `promote`). Any writer that checks `promoted` while holding one of those locks gets an answer that cannot change until it releases the lock. The check before the lock is still useful as a fast path, but only the check under the lock is trustworthy.

The writer must release the lock before it calls the authority. The authority takes the run lock itself, and `flock` locks belong to an open file, not to a process. A second `open` and `LOCK_EX` on the same lock file from the same process waits forever. On the journal path the authority also exports under the journal lock, so calling it while holding that lock deadlocks the same way and also takes the two locks in the opposite order to `promote`. The private sentinel is how the code leaves the lock first and re-routes second.

## Prevention

- When code decides *where* to write and then takes a lock, ask what can change the decision while the writer waits. If anything that holds the same lock can change it (a migration, a promotion, a mode switch), re-check the decision under the lock.
- When one write path gets this fix, search for every other path with the same check-then-lock shape (here, the record path and the journal and claims path) and fix them in the same change.
- Never call a component that takes the same flock from inside a held flock. Raise a private sentinel, release, then call it.
- Test the race directly, not by timing. `plugins/auto/tests/integration/programme-storage-cutover.test.sh` pauses racing writers at the lock with a gate file, runs `promote`, releases the gate, and asserts that the record changes, the typed prompt and the claim are in the store as native rows, that nothing was quarantined, and that the `append_to` racer was refused. See the blocks headed "a current-code record write that decided "legacy" just before promote ran" and "journal and claims appends that decided "legacy" just before promote ran".

## Related Issues

- `docs/solutions/logic-errors/a-lock-a-stalled-writer-can-lose-must-be-rechecked-before-the-commit.md` covers a related failure in the peek plugin (since moved to its own repo): a lock that can be broken by age must be re-checked right before the commit. That doc is about losing the lock. This one is about a decision made before the lock going stale while the writer waits.
