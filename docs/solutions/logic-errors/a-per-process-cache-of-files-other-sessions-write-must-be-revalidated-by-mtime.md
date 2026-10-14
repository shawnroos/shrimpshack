---
title: "A per-process cache of files other sessions write must be revalidated by mtime on every poll"
date: 2026-10-14
module: plugins/peek
problem_type: logic_error
component: tooling
severity: high
category: logic-errors
symptoms:
  - "a list moved to another repo by one session was moved back when a second session folded the list"
  - "after one session took over an agent item, a second session still sent the agent's later status changes to the old hidden record, so the takeover doc never updated"
  - "a takeover doc moved to the user-level list or another repo was refused by setStatus and the change was never retried"
  - "every single-process test passed because one mirror instance can never see another writer"
root_cause: concurrency
resolution_type: code_fix
tags: [peek, mirror, stale-cache, mtime, cross-session, lost-update, two-instance-test, mutation-check]
---

# A per-process cache of files other sessions write must be revalidated by mtime on every poll

## Problem

Every Claude Code session runs its own peek process, and each process keeps module-level caches. The agent-list mirror (`plugins/peek/hooks/mirror/watch.ts`) built a per-session cache of on-disk shared state once per process and never re-read it: the `followed` map holds the list state read from `state.json` plus one `Rec` per mirrored record file. Another session could rewrite those files at any time, so this process kept acting on, and writing back, a copy that was already stale.

## Symptoms

- Session A moved a list to another repo (`moveList` writes the new `placeKey` into `state.json`). Session B then folded the list and wrote its own cached state over A's, so the list moved back. Test failure before the fix: `Expected /other/.git  Received /repo/.git`.
- Session A took over an agent item (wrote a takeover doc and set the record's `takeover` prop). Session B kept routing the agent's later status changes to the old hidden record, so they never reached the takeover doc. Test failures before the fix: `Expected [doing] Received [todo]` and `Expected [done] Received [todo]`.
- A third, related bug: `take()` derived the status place from the session's own repo. A takeover doc that had moved to the user-level list or another repo was refused by `setStatus`, and the change was never retried.
- Single-process tests were green. One mirror instance can never see a second writer.

Found independently by the code review's correctness reviewer and by a cross-model Codex adversarial pass, both pointing at the same lines (`watch.ts:165` and `:198` at the time of the review), then confirmed by an independent validator.

## What Didn't Work

- **Single-instance tests.** A test that builds one mirror (`createMirror` once) exercises a cache that no one else mutates. It passed before and after, so it proved nothing about this bug. The bug only exists with two instances over one mirror folder.
- **A first version of the move test did not catch dropping `places.delete`.** The mutation (delete that line from the reload branch) survived until the test was changed so session B already held a cached place before the move. Without a cached place to go stale, there was nothing for the missing invalidation to leave behind.
- **Trusting "built once, then maintained" as an invariant.** The cache was correct for the writes this process made itself, which is all one process ever observes in a test. That is why it looked right on read-through.

## Solution

Revalidate the cache against the file's mtime on each poll, and re-read only when the mtime moved.

1. `follow()` stats `state.json` every poll. When the mtime differs from the one this process last read or wrote, it reloads `f.state` and drops the cached place (`places.delete`, `unplaced.delete`). See `follow` at `plugins/peek/hooks/mirror/watch.ts:165-190`.

```ts
const stateMtime = (await io.stat(stateOf(root, session)))?.mtimeMs
const known = followed.get(session)
if (known) {
  if (known.stateMtime !== stateMtime) {
    known.state = await readListState(io, session, root)
    known.stateMtime = stateMtime
    places.delete(session)
    unplaced.delete(session)
  }
  return known
}
```

2. A new `saveState()` (`watch.ts:192-196`) writes the state, then records the mtime of that write into `f.stateMtime`. This process never mistakes its own write for another session's and re-reads itself.

3. `Rec` now carries `mtimeMs` (`watch.ts:52`). `take()` stats the record; if the mtime moved, it rebuilds the `Rec` from disk (`watch.ts:210-218`) so a `takeover` prop set by another session is seen.

4. A shared `placeOfTasksFolder(io, folder)` in `plugins/peek/hooks/tasks/store.ts:60` derives the place from the takeover doc's folder (the user place if the folder is the user folder, else the repo capture for a folder ending in the tasks tail). `take()` uses it for takeover docs (`watch.ts:223`), falling back to `placeOf(root, session)` when there is no takeover or its folder is not a tasks folder. This removes the "place derived from my repo" assumption that caused the refusal.

Cost: one extra `stat` per followed session per poll; file reads happen only when an mtime moved.

Status of the fix: pushed on branch `feature/peek-markdown-views`, which is stacked on `feature/peek-md-tables` (PR #105, open); a PR for this branch was not yet open at this writing, and nothing is merged.

## Why This Works

The root cause was an unstated assumption: "I am the only writer of these files." Per-process caches are correct under that assumption and wrong the moment a second process writes, and a design with one peek process per session violates it by construction. The fix replaces the assumption with a cheap check of the actual authority (the file's mtime) and keeps the cache as an optimization, not a source of truth. Recording the mtime of the process's own write (`saveState`) is what makes the check safe: otherwise every self-write would look like a foreign change and force a pointless re-read.

Deriving the place from the doc's own folder, not from the session's repo, fixes the third bug for the same reason: the doc location on disk is the truth, and the session's repo is a guess that stops being valid when a list moves.

## Prevention

- **Treat any module-level cache of a file another session can write as suspect.** For each such cache, name the writers. If the answer is "more than this process", add a validity token (mtime here) checked at every use, and re-read only on mismatch. Record the token of your own writes.
- **Test with two instances over one shared folder.** The regression tests in `plugins/peek/tests/mirror.test.ts` call `createMirror` twice (for example `createMirror(io, { id: 'session-two', root: '/wt/feature' })`) over one mirror folder, and interleave their writes. Single-instance coverage cannot fail for this bug class.
- **Prove each test can fail.** Each fix was mutation-checked: revert the line, and the matching test must go red. One mutation (dropping `places.delete`) survived the first test, which exposed that the test never made session B hold a cached place before the move. A surviving mutation means the test is incomplete, not that the code is fine. See `docs/solutions/logic-errors/a-test-can-pass-because-it-cannot-fail.md`.
- **Review with an independent second model on cross-process code.** Two unrelated reviewers (correctness reviewer, cross-model Codex pass) landed on the same two lines; that agreement was the signal, since the tests gave none.

Related: `docs/solutions/logic-errors/a-lock-a-stalled-writer-can-lose-must-be-rechecked-before-the-commit.md` covers another cross-session writer hazard in the same plugin (a stalled lock holder committing stale data). Both share the premise that sessions are concurrent peers, and a process's in-memory view of shared files is only a hint.
