---
title: "A file lock a stalled writer can lose must be re-checked right before the commit"
date: 2026-10-12
module: plugins/peek
problem_type: logic_error
component: tooling
severity: high
category: logic-errors
symptoms:
  - "an independent cross-model review found that a group writer paused for more than 10 s could have its lock broken by another session and still mv its stale copy over the newer edit"
  - "the same writer's finally-block rmdir removed the lock the new holder had just taken"
  - "two writers of one group shared one staged path, so one could rename the other's half-finished file"
  - "a stale-lock break that only ran rmdir passed every test, because the fake filesystem's rmdir succeeded on a non-empty directory"
root_cause: concurrency
resolution_type: code_fix
tags: [peek, groups, file-lock, mkdir-lock, lease, atomic-rename, cross-session, lost-update]
---

# A file lock a stalled writer can lose must be re-checked right before the commit

## Problem

Peek groups are written by any Claude Code session in the same repo: the agent's tools and the person's pane actions alike. The engine offers no lock, and `$.store` is one 4 MiB JSON file per plugin whose types say nothing about per-key merging or whether `get` sees another process's write. So each group is a JSON file under `~/.local/share/claude-peek/groups/<project hash>/`, guarded by a `mkdir <id>.lock` lock.

The first version locked, re-read, wrote a staged file and renamed it over the group file. It also broke locks older than 10 s, so a crashed session could not block a group for ever. That break is what made it unsafe: a live writer stalled past 10 s (heavy load, a suspended process) lost its lock without knowing, then resumed and renamed its stale group over the newer edit. A person's addition or removal vanished silently. Its `finally` then removed the new holder's lock as well.

## Root cause

Breaking a stale lock turns the lock into a lease, and a lease is only safe if its holder checks it is still the holder at the moment of commit. The writer checked the lock only on entry. Three smaller faults widened the window:

- The staged path was shared (`<id>.json.staged`), so two writers could overwrite or rename each other's staged file.
- Release was an unconditional `rmdir`, so a writer that had lost the lock still released it.
- The test double's `rmdir` succeeded on non-empty directories, so a break that left the owner file behind looked correct in tests and would fail on disk.

## Solution

The write path in `plugins/peek/hooks/groups.ts` (`lockedWrite`):

1. Queue writes per group inside the process, so a pane action and a tool call never race each other for the lock.
2. `mkdir <id>.json.lock`. Only one process can create a directory, so this is the cross-session lock. Write a random owner token into `<lock>/owner`.
3. Re-read the group file under the lock and apply the operations to that copy, never to a cached one.
4. Write a per-writer staged file, `<id>.json.<token>.staged`.
5. Read the owner token again immediately before `mv -f staged file`. If it changed or the lock is gone, delete the staged file and return "busy, try again". Nothing is committed.
6. Release with `rm -f owner` then `rmdir`, and only if the token is still ours.
7. Breaking a lock older than `LOCK_STALE_MS` (10 s) also removes its owner file first.

Tests in `plugins/peek/tests/groups-pane.test.ts` simulate another session breaking and taking the lock between a holder's read and its rename, and assert the newer edit survives and the new holder keeps its lock. The fake filesystem's `rmdir` fails on a non-empty directory, matching the real one.

Residual: the token check and the `mv` are two steps, so a break landing in the few milliseconds between them can still slip through. Closing that needs an OS-level lock such as `flock`, which a mod's io port does not provide.

## Prevention

Whenever a lock can be broken by age, treat it as a lease: give the holder an identity, re-check that identity as the last step before the irreversible write, and release only what you still own. Check that test doubles fail where the real primitive fails (`rmdir` on a non-empty directory), or the test cannot catch the bug it exists for.
