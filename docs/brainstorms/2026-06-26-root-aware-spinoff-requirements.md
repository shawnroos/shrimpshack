# Root- & workspace-aware spinoff — Requirements

**Date:** 2026-06-26
**Scope:** Standard (one script + its SKILL.md)
**Status:** Ready for `/ce-plan`

## Outcome

`/start` spinoffs root a new worktree in the **right repo** from a **fresh base**, and
never silently land in the **wrong cmux workspace** — without the manual `cd`-into-repo
and hand-corrected-base workarounds we hit three times in one session.

## Problem / context

The spinoff script assumes the originating session's cwd is already inside the target
git repo. When `/start` runs from `~/Users/shawnroos` (not a git repo),
`plugins/spinoff/skills/spinoff/scripts/spinoff.sh:53` —
`git rev-parse --show-toplevel || die "not inside a git repo"` — would kill the run. We
worked around it every time by having the backgrounded agent manually
`cd ~/projects/<repo>` first. That hand-`cd` IS the gap.

Two compounding failures, both observed this session:
1. **Wrong/no repo** — cwd isn't in the target repo, so the script can't resolve a root.
2. **Stale base** — local `main` was 6 commits behind `origin/main` and still carried the
   old `plugins/cmux-spinoff/` layout; branching off local HEAD reproduced the stale
   layout. We hand-corrected the base to `origin/main` twice.

The `/start` main session already knows the target repo (it's reasoning about the work),
so the cleanest lever is to have the caller resolve and pass repo + base explicitly,
rather than infer from cwd.

## Design principle (governs all three resolutions below)

The main `/start` session is **engaged in the decision**, not gated by hard-coded
confirmation prompts. SKILL.md equips it with a **decision rubric** for each resolution
(repo, base, workspace); it acts autonomously when confident and escalates via
`AskUserQuestion` **only when confidence is low**. The script keeps deterministic
backstops (fail-loud, warn-if-stale) as the safety net beneath the agent's judgment —
not as the primary decision mechanism.

**Hard constraint:** the mechanical script runs in a **backgrounded agent that cannot
ask the user anything**. Therefore all rubric-driven resolution and any low-confidence
escalation happens in the **interactive main session, before dispatch**. The backgrounded
script executes already-resolved, high-confidence values plus its dumb guards.

## Requirements

### R1 — `--repo` flag (script)
- Add `--repo <path>`. When present, the script roots in that repo via `git -C "$REPO"`
  instead of relying on cwd (`spinoff.sh:53` and the main-tree walk at 56–61 thread the
  explicit root through; `git -C "$MAIN_ROOT" worktree add` at ~97 already uses `git -C`).
- **Absent** → fall back to today's behavior (resolve the repo from cwd). Backward-compatible.
- **Neither resolves** → replace the bare `die "not inside a git repo"` with a helpful
  message that names `--repo` and explains how to pass it.
- The existing worktree-vs-main-tree walk (56–61) is correct — leave its logic intact;
  only change what feeds it (`$REPO` instead of bare cwd).

### R2 — Caller resolves and passes repo + base (SKILL.md)
- SKILL.md Steps 3–4 instruct the main session to resolve the target repo and pass it as
  `--repo`, and to pass `--base origin/<default-branch>` for a fresh base.
- **Repo rubric** (caller): derive the repo from the work under discussion / recent
  plan-brainstorm docs / `--session-cwd` when that cwd *is* a git repo; if confident, pass
  it; if ambiguous, `AskUserQuestion`.
- **Base rubric** (caller): default to `origin/<default-branch>` (fresh). Only deviate from
  origin's default branch when there's a clear reason; if unsure which base is intended,
  `AskUserQuestion`.

### R3 — Fresh base + stale-base warn guard
- Passing `--base origin/<default-branch>` reuses the existing fetch-on-`origin/*` code
  (`spinoff.sh:86–88`) — no new fetch logic needed for the happy path.
- **Guard (script):** if the resolved base is a *local* branch that is behind its remote
  tracking branch, print a loud **non-blocking** warning before `worktree add`. Warn, don't
  override — branching off local HEAD stays possible when intended.

### R4 — Workspace routing confirm (SKILL.md pre-flight)
- Before backgrounding the dispatch, the main session resolves which cmux workspace the new
  tab will land in and compares it to the workspace `/start` was invoked in.
- **Workspace rubric** (caller): if the new tab routes to the *same* workspace (the common
  `--target tab` path), proceed silently. If it would land in a *different* workspace, this
  is a low-confidence situation → confirm with the user (`AskUserQuestion`) before launching.

## Scope boundaries

**In scope**
- R1–R4 above: `--repo` flag, caller-passes repo+base, stale-base warn guard, workspace
  confirm pre-flight, and the SKILL.md rubrics that drive them.

**Out of scope / deferred**
- cmux-workspace *inference* of the repo (rejected — caller passes `--repo` instead).
- Auto-fetch-and-change-the-default-base when no `--base` is given (rejected — warn, don't
  silently override the caller's intent).
- Active workspace↔repo identity verification beyond the different-workspace confirm.

## Success criteria

- `/start` from a non-git cwd (e.g. `~/Users/shawnroos`) succeeds without any manual
  `cd`-into-repo step.
- A spinoff into a repo whose local `main` is stale roots its worktree on the fresh
  `origin` base (old layout not reproduced); a stale *local* base triggers a visible warning.
- Running `spinoff.sh` with neither `--repo` nor a git cwd prints actionable guidance naming
  `--repo`, not the bare "not inside a git repo".
- A spinoff that would open in a different workspace than the current one prompts for
  confirmation before launching; the common same-workspace path stays silent.
- Existing in-repo `/start` invocations keep working unchanged (backward-compatible).

## Dependencies / assumptions / open for `/ce-plan`

- **cmux query (open):** the exact cmux command/topology query for "which workspace will the
  new tab land in" vs "current workspace", and what counts as a workspace's anchor, is left
  for ce-plan to design. See the `cmux` skill (topology/surfaces).
- **Default-branch detection (assumption):** assume `main` for shrimpshack; confirm in plan
  whether `origin/<default-branch>` needs generic detection (e.g. `origin/HEAD`) for other repos.
- **Concurrent edit — coordinate:** `feature/session-naming`
  (`~/projects/shrimpshack/worktrees/session-naming`, `1a87867`) also edits `spinoff.sh`
  (adds `claude --name`). Keep edits localized; rebase on `origin/main` before landing; expect
  a merge with it.
- **Plugin store is version-gated:** shrimpshack is its own marketplace — bump the version in
  both manifests so the store serves the change, and refresh the marketplace before updating
  the plugin.
- **Base ref:** this worktree is correctly on `origin/main` (`77cad7c`) with the renamed
  `plugins/spinoff/` layout. Land changes from here, not local `main`.

## Source

- Handoff: `docs/handoff.md`
- Source session transcript: `/Users/shawnroos/.claude/projects/-Users-shawnroos/dde8ee69-bcee-40bd-a003-27e56020f197.jsonl`
