---
title: "A clean git status does not prove a worktree is safe to remove"
date: 2026-10-22
category: logic-errors
module: plugins/auto
problem_type: logic_error
component: tooling
severity: high
symptoms:
  - "programme end ran plain `git worktree remove` and deleted a gitignored docs/plan.md, with a `removed` receipt"
  - "a nested git repo with uncommitted work inside an ignored node_modules/ was deleted, because git reports a wholly ignored folder as one entry"
  - "a local edit on an assume-unchanged or skip-worktree file was deleted with no warning"
  - "three successive review rounds each found a new hole in an allowlist of disposable ignored folders, and a fourth gap (assume-unchanged edits) surfaced after the switch to default-deny"
root_cause: logic_error
resolution_type: code_fix
framework_version: "git 2.54"
related_components:
  - testing_framework
tags: [git-worktree, gitignore, default-deny, allowlist, data-loss, assume-unchanged, skip-worktree, programme-end]
---

# A clean git status does not prove a worktree is safe to remove

The fix lives on branch `feature/pm-home-directory`, not yet merged as of this writing.

## Problem

At programme end, `release()` in `plugins/auto/lib/programme_worktree.py` removes the PM's programme worktree with a plain `git worktree remove` (no `-f`), on the theory that git refuses to remove a worktree that holds work. Git only refuses when `git status` shows a change, and `git status` does not show several kinds of local work, so the removal deleted that work without any error.

## Symptoms

- A plan written to an ignored folder (`docs/plan.md`, where Slate web-app writes plans because it gitignores `/docs`) is gone after programme end, and the release receipt says `removed`.
- A nested git repo with uncommitted work inside an ignored folder (`node_modules/pkg`, or `.venv/src/<pkg>` from `pip install -e`) is gone with it.
- A local edit to a file marked `assume-unchanged` or `skip-worktree` is gone.
- A worktree with submodules is never removed: git exits 128 with `fatal: working trees containing submodules cannot be moved or removed`.
- After an over-tight fix, the reverse symptom: every Python or monorepo worktree is refused because of a nested `__pycache__/` or `packages/a/node_modules/`.

Reproduced in a scratch repo on git 2.54.0. In a detached worktree holding an ignored `docs/plan.md`, an ignored `node_modules/pkg` repo with an uncommitted file, an ignored `dist/.env`, and an edit to an `assume-unchanged` tracked file:

```
$ git status --porcelain --untracked-files=all
                                   # prints nothing
$ git status --porcelain --untracked-files=all --ignored=matching
!! dist/.env
!! docs/
!! node_modules/
$ git ls-files -v
H .gitignore
H dist/keep.txt
h tracked.txt                      # lowercase tag = assume-unchanged
$ git worktree remove ../w && echo REMOVED
REMOVED                            # all four kinds of work deleted
```

Two facts from that output decided the design. First, `--untracked-files=all` does not open an ignored folder: git lists `docs/` and `node_modules/` as one entry each, so their contents (including a nested repo) cannot be inspected through `git status`. Second, an assume-unchanged edit does not appear in any `git status` mode.

## What Didn't Work

Each round below passed its own tests. A fresh reviewer then found a new case, and the case was confirmed in a scratch repo.

1. **Status check only**. Refuse when `git status --porcelain --untracked-files=all` prints anything. Ignored files are not in that output, so `docs/plan.md` was deleted.
2. **Allowlist of regenerable ignored folders, matched on the first path component.** Add `--ignored`, then let through entries whose first component is a cache name (`node_modules`, `__pycache__`, `.venv`, and so on). Nested caches such as `pkg/__pycache__/` and `packages/a/node_modules/` did not match, so almost every real Python or monorepo worktree was refused.
3. **Allowlist matched on any path component.** This fixed nested caches, but an ignored `.env` inside a tracked folder named `dist/` or `coverage/` matched on `dist`/`coverage` and was deleted.
4. **Allowlist matched on the last component only, with `dist` and `build` removed** (`REGENERABLE` set of `node_modules`, `.DS_Store`, `__pycache__`, `.pytest_cache`, `.venv`, `.cache`, `.angular`, `.next`, `.turbo`, `coverage`). Because git reports a wholly ignored folder as one entry, an allowlisted `node_modules/` can hold a nested repo with uncommitted work, and nothing in the status output says so. That work was deleted.

The common defect in rounds 2 to 4: an allowlist is an enumeration of "safe" names, and the thing it judges (a folder git will not look inside) can hold anything. Every narrowing of the allowlist closed one case and left the class open.

## Solution

Default-deny. `release()` removes the worktree only when every check below passes, and otherwise leaves it as a pending closure resource with a receipt that names the cause and the fix. Shawn deletes caches by hand, or records `dispose-action --resource worktree` after deleting the worktree himself.

Checks, in order, at the current tree (`plugins/auto/lib/programme_worktree.py`):

| Check | Code | Refuses when |
|---|---|---|
| Caller is not inside the worktree | `:186-188` | the command's cwd is inside the worktree |
| No nested worktree | `:189-196` | `git worktree list --porcelain` lists another worktree inside this one |
| Nothing changed or untracked | `:197-203` | any entry in `git status --porcelain -z --untracked-files=all --ignored=matching` has a code other than `!!` |
| Nothing ignored except Finder metadata | `:204-208` | any `!!` entry is not a `.DS_Store` file (`_disposable`, `:163-164`) |
| No hidden local edits | `:209-217` | `git ls-files -v -z` shows a lowercase tag (assume-unchanged) or `S` (skip-worktree) for a path that exists on disk |
| No submodules | `:218-221` | `.gitmodules` exists in the worktree |
| No unreachable commits | `:222-230` | `git rev-list -n 1 <head> --not --branches --remotes` prints a commit |

Only then does it run plain `git worktree remove` (`:231`), never with `-f`.

The ignored-entry rule, before (round 4) and after:

```python
# before: allowlist, last path component
REGENERABLE = frozenset({"node_modules", ".DS_Store", "__pycache__", ".pytest_cache", ".venv",
                         ".cache", ".angular", ".next", ".turbo", "coverage"})

def _regenerable(entry) -> bool:
    return entry.rstrip("/").rsplit("/", 1)[-1] in REGENERABLE
```

```python
# after: programme_worktree.py:161-164
# Default-deny: an ignored folder can hide a nested repo with uncommitted work, so the only
# ignored entry a removal may take is a Finder metadata file, which can hold nothing.
def _disposable(entry) -> bool:
    return entry.rsplit("/", 1)[-1] == ".DS_Store"
```

`.DS_Store` is safe because it is a file, not a folder, so it cannot hide a nested repo.

Status is parsed with `-z` by `_entries` (`:167-177`). The NUL-separated form does not quote names with spaces or unusual characters, and a rename or copy entry (`R`/`C`) carries a second path token that the parser skips (`:174-175`), so the original path of a rename is not misread as a new entry.

The hidden-edit check (`:212-213`) requires the path to exist on disk (`os.path.lexists`). A sparse-checkout file is also tagged `S` but is absent from the worktree, so it holds nothing to lose and does not block removal.

## Why This Works

`git worktree remove` without `-f` treats a worktree as clean when `git status` is clean. That is a narrower question than "does deleting this folder lose anything". Three gaps sit between the two:

- **Ignored paths.** `git status` hides them by default. With `--ignored`, it still reports a wholly ignored folder as a single entry, so a nested repo inside it is invisible.
- **Index flags.** `assume-unchanged` and `skip-worktree` tell git not to compare the file to the index, so no `git status` mode reports an edit to it. `git ls-files -v` exposes the flags through the tag letter.
- **Other worktrees and submodules.** A worktree registered inside this one is a separate checkout that `git status` here does not describe. Submodules make git refuse removal outright.

The final `release()` closes each gap with a direct check instead of trying to decide which ignored content is safe. Any ignored entry other than `.DS_Store` refuses removal. That refusal is the safe failure: the worktree stays and Shawn gets a receipt naming the path. A wrong "removed" deletes work that cannot be recovered. Refusing too often costs a manual cleanup step. Removing wrongly costs lost work, so the check leans toward refusing.

## Prevention

- **Treat "git refuses unsafe removal" as a claim to test, not a guarantee.** Before relying on any git safety check, list what it consults (here, `git status`) and probe what that source omits: ignored files, ignored folders with nested repos, index flags, nested worktrees, submodules.
- **When the judged content is opaque, default-deny.** If the tool cannot see inside a thing (a wholly ignored folder), no name-based allowlist can make it safe. Allow only entries that cannot hold anything (a single known metadata file). The same lesson as `docs/solutions/best-practices/default-deny-for-an-unattended-agent.md` and `docs/solutions/logic-errors/default-allow-regex-projection-gate-silently-drops-nudges.md`: an enumeration never closes a class.
- **Write one test per hiding place, and confirm each test fails when its check is removed.** `plugins/auto/tests/unit/programme-archive.test.sh` has one case each. The author confirmed each fails when its check is deleted:

  | Case | Hiding place | Expected |
  |---|---|---|
  | w60 | ignored `docs/plan.md` | pending, file kept, receipt names `docs/` |
  | w61 | ignored nested worktree at `.claude/wt/child` | pending, `wip.txt` kept |
  | w62 | ignored `.DS_Store` at root and in a subfolder | released |
  | w63 | nested repo inside ignored `node_modules/` | pending, work kept, receipt names `node_modules/` |
  | w64 | worktree inside ignored `dist/` | pending, `wip.txt` kept |
  | w65 | ignored `.env` inside tracked `coverage/` | pending, `SECRET=1` kept |
  | w66 | ignored `dist/report.pdf` | pending, file kept |
  | w67 | submodule | pending, receipt names `submodule` |
  | w68 | assume-unchanged local edit | pending, edit kept, receipt names `no-assume-unchanged` |

  A test that asserts on the file contents (`cat "${WT}/docs/plan.md"`) proves the work survived. A test that only asserts the status string does not.
- **Reproduce each reviewer finding in a scratch repo before patching.** Every round here was confirmed on git 2.54 first, which is how round 4's gap (one status entry per ignored folder) was found to be a property of git, not of the parser.
- **Never add `-f` to `git worktree remove` to clear a refusal.** The refusal is the safety mechanism, and `-f` overrides git's own modified/untracked refusal.

## Related

- `docs/solutions/logic-errors/default-allow-regex-projection-gate-silently-drops-nudges.md`: the same defect class (an enumerated gate leaks a new case each review round; fixed by default-deny), in a different domain.
- `docs/solutions/best-practices/default-deny-for-an-unattended-agent.md`: the general rule this fix applies to file deletion.
