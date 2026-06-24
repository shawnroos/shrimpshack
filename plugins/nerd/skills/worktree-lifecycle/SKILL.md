---
name: worktree-lifecycle
description: Canonical, single-source procedures for nerd's experiment worktree lifecycle — create, merge-back, and reconcile/cleanup. Both /nerd and /nerd-this reference this so the safety logic lives in exactly one place instead of being copy-pasted (and drifting) across command files. Use whenever a nerd command needs to create an experiment worktree, merge a completed experiment back into the source branch, or clean up worktrees after a batch.
---

# Worktree Lifecycle (canonical)

These are the **single source of truth** for how nerd handles experiment worktrees. `/nerd` (Phases 6c / 6e / 8) and `/nerd-this` (Phases 8.x / 10) both reference this skill instead of inlining the bash — fix a bug here once, not in four places. When a command says "follow worktree-lifecycle §X," run the bash below verbatim (substituting the noted placeholders); do not improvise an alternative, because these blocks encode hard-won safety properties.

Placeholders: `$CURRENT_BRANCH` = the **re-captured** source branch (after the off-main guard's possible switch — never the pre-switch value); `{entry.id}` = experiment id; `{test_command}` = project test command.

## Cleanup gate (shared sub-step)

Parse `auto_cleanup_worktrees` **fail-safe**: only an explicit affirmative (or a missing key) permits the destructive `git worktree remove`. Quoted, commented, or negative values all KEEP the worktree.

```bash
AUTO_CLEANUP=$(grep -E '^auto_cleanup_worktrees:' .claude/nerd.local.md 2>/dev/null \
  | head -1 | sed 's/^[^:]*://; s/#.*//; s/["'\'' ]//g' | tr '[:upper:]' '[:lower:]')
# cleanup_allowed when: key absent (default ON), or value is true/yes/1.
cleanup_allowed() { [ -z "$AUTO_CLEANUP" ] || [ "$AUTO_CLEANUP" = "true" ] || [ "$AUTO_CLEANUP" = "yes" ] || [ "$AUTO_CLEANUP" = "1" ]; }
```

**Verify:** with `auto_cleanup_worktrees: "false"`, `false # comment`, or `no` in `.claude/nerd.local.md`, `cleanup_allowed` must return false (worktree kept); with the key absent or `true`, it returns true.

## §Create — make an experiment worktree

```bash
PROJECT_ROOT="$(pwd)"
# Never branch off an empty/detached HEAD — the setup guard should prevent this, but a resumed run can land here.
if [ -z "$CURRENT_BRANCH" ]; then
  echo "ABORT: CURRENT_BRANCH is empty (detached HEAD). Check out a branch before running experiments." >&2
  exit 1
fi
# Suffix the branch if a prior partial batch already created it, so 'git worktree add' can't collide.
WT_BRANCH="nerd/{entry.id}"
if git rev-parse --verify "$WT_BRANCH" >/dev/null 2>&1; then
  WT_BRANCH="nerd/{entry.id}-$(git rev-parse --short HEAD)"
fi
git worktree add worktrees/nerd-{entry.id} -b "$WT_BRANCH" "$CURRENT_BRANCH"
cd "$PROJECT_ROOT"
```

Use `$WT_BRANCH` (the actually-created name) in this experiment's later merge/cleanup, not the literal `nerd/{entry.id}` — a collision may have suffixed it.

**Verify:** `git worktree list` shows `worktrees/nerd-{entry.id}` on `$WT_BRANCH`, branched from `$CURRENT_BRANCH`.

## §Merge — merge one completed experiment back into the source branch

Process completed experiments **one at a time** (serialize this step even though executors run in parallel) — the recovery below assumes the merge it undoes is the latest commit on the source branch.

```bash
if [ -z "$CURRENT_BRANCH" ]; then echo "ABORT: empty CURRENT_BRANCH" >&2; exit 1; fi
git checkout "$CURRENT_BRANCH"
if [ -n "$(git status --porcelain)" ]; then
  echo "WARN: working tree dirty on $CURRENT_BRANCH — skipping merge of $WT_BRANCH to avoid clobbering; mark deferred." >&2
else
  if git merge "$WT_BRANCH" --no-edit; then
    if ! {test_command}; then
      git reset --hard HEAD~1   # tests failed AFTER a clean merge → undo the merge commit; KEEP worktree (debuggable)
    fi
  else
    git merge --abort           # merge CONFLICTED → abort (no merge commit to drop); KEEP worktree
  fi
fi
```

A conflicted merge leaves no merge commit, so `git reset --hard HEAD~1` would destroy a real prior commit — use `git merge --abort` for conflicts and reserve `reset --hard HEAD~1` for the "merged clean but tests failed" case only.

If the merge succeeded and tests passed, clean up — gated on the cleanup gate above (run the **Cleanup gate** sub-step first so `cleanup_allowed` is defined in this shell):

```bash
if cleanup_allowed; then
  if git worktree remove worktrees/nerd-{entry.id}; then
    git branch -d "$WT_BRANCH" 2>/dev/null   # -d only deletes fully-merged branches; safe
  fi
fi
```

Merge conflicts in eval-module files are additive — combine both sides.

**Verify:** after a clean experiment, `git log --oneline -1 "$CURRENT_BRANCH"` shows the merge; the worktree is gone (when cleanup allowed) or intact (when kept); a tests-fail case left the source branch at its pre-merge commit.

## §Reconcile — sweep all worktrees after a batch

`git worktree prune` only removes worktrees whose directory is already gone — it does NOT remove a worktree still on disk for an already-merged branch. That gap is how stale worktrees accumulate and get re-run. Cross-check against merged branches first (run the **Cleanup gate** sub-step first so `cleanup_allowed` is defined in this shell):

```bash
if [ -z "$CURRENT_BRANCH" ]; then echo "ABORT: empty CURRENT_BRANCH — cannot reconcile worktrees" >&2; exit 1; fi
git checkout "$CURRENT_BRANCH"
if cleanup_allowed; then
  # Prefix column stripped: * current, + worktree-checked-out, 2 spaces other.
  MERGED=$(git branch --merged "$CURRENT_BRANCH" | sed 's/^[*+ ] *//')
  for wt in worktrees/nerd-*; do
    [ -d "$wt" ] || continue
    branch="nerd/$(basename "$wt" | sed 's/^nerd-//')"
    if echo "$MERGED" | grep -qx "$branch"; then
      if git worktree remove "$wt"; then     # merged → safe to remove
        git branch -d "$branch" 2>/dev/null
      else
        # Don't swallow the failure — a merged-but-unclean worktree left on disk gets re-run next batch.
        echo "WARN: '$wt' is merged but could not be removed (untracked/uncommitted files). Resolve manually: git worktree remove --force '$wt'" >&2
      fi
    fi
  done
fi
git worktree prune                       # clean any remaining stale metadata
```

When auditing whether a worktree represents in-progress work, ALWAYS check `git branch --merged` first — a worktree whose branch is merged is done, not active, regardless of whether its directory still exists.

**Verify:** after reconcile, `git worktree list` contains no worktree whose branch appears in `git branch --merged "$CURRENT_BRANCH"`; any that couldn't be removed printed a WARN rather than being silently skipped.
