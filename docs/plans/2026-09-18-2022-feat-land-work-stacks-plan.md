---
title: Land the work plugin and board PR stacks - Plan
date: 2026-09-18
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
---

# Land the work plugin and board PR stacks - Plan

**Target repos:** `shrimpshack` (five PRs) and `herdr-linear-board` (two PRs). Paths
are relative to the repository named in each unit.

## Goal Capsule

**Objective.** A person can open a herdr space, see their Linear work in it, pick a
space, project or view, and read one issue in full — using the plugin and board
installed from `main`, not from a branch. Today that capability exists only in seven
unmerged pull requests, so nothing can be built on top of it.

**Means.** Land each repository's chain as one atomic `gh stack` merge rather than
merging pull request by pull request (KTD1).

**Product authority.** Shawn. He authorises every merge; this plan sequences them and
stops there.

**Stop conditions.**
- Stop before any merge and ask. Merging is outward-facing and irreversible.
- Stop if the plugin suite does not report `PASS` at the stack tip — do not land a red
  stack. Note that a red run surfaces through `honest-run` as `DID-NOT-COMPLETE`, not
  `FAIL`; read the log's final line to tell the two apart.
- Stop if `#89` ("herdr Linear board and per-session binding") turns out to be needed
  before the chain rather than after it — that would reverse a settled decision (R3).

**Open blockers.** None. Both were settled on 2026-09-18:
- **R3 — `#89` stays open.** Land the chain, then rebase #89 onto it
  (session-settled: user-directed — chosen over landing #89 first and over closing it:
  it is parallel work carrying Part B, and keeping it open is the reversible option).
- **R6 — the Linear-mode preemption is intended.** Scenario 13 is rewritten or retired
  (session-settled: user-directed — chosen over adding a `scope.rs` overlay exception:
  starting from the Linear board is the point of PR #2).

---

## Product Contract

### Summary

Seven pull requests across two repositories hold a complete, unmerged feature: the
work plugin learns to describe a herdr space and bind a session to Linear, and the
herdr board learns to render Linear and hand off to `/work:bind`. This plan restacks
the one broken seam in the plugin chain, proves the composed result against the
plugin's own gates, fixes a version-floor mismatch that is failing the board's
end-to-end suite, and lands each chain as a single atomic squash merge.

### Problem Frame

The board's Linear mode does not exist on `main` at all. Work that depends on it
cannot start, and a `/lfg` run on the board's issue-detail-parity plan already
stopped at its first step for this reason.

The chains are not simply "waiting for a merge button". Four things are actually
wrong, and only one of them was known when this work was handed off:

1. **The plugin chain has one broken seam.** `feature/work-plugin-initiative` (#82)
   was brought up to `main` after `feature/work-plugin-config` (#83) branched off it.
   #82's head is not an ancestor of #83, so eight commits — including a `main` merge
   and a new test — are missing from everything above it. The other three seams are
   in sync.

2. **The board's end-to-end suite holds two real regressions, neither a flake.** 38 of
   40 scenarios pass; the job needs no secret and calls no provider, so the
   environment is healthy.
   - `40-linear-mode.sh` fails with protocol code 6. Commit `f95df2a` raised
     `PLUGIN_VERSION_FLOOR` to `0.5.0` in `crates/board-core/src/lib.rs` and swept the
     Rust tests, but touched no end-to-end file — so the fixture still stubs the good
     plugin at `0.4.0`. The same scenario passed two commits earlier.
   - `13-jump-to-pane.sh` fails identically on 3 of 3 runs that reached the suite.
     PR #2 makes `board tui` open Linear mode whenever a herdr space id is present,
     with no fall-through, and scenario 13 is the one scenario that opens the board
     directly rather than through the helper that was patched to clear those
     variables. The kanban overlay is no longer reachable from a herdr pane at all.

3. **`#89` is not superseded** — and it holds Part B. 45 of its files exist nowhere in
   the chain: a two-way Linear↔herdr board, per-session binding, a herdr plugin
   manifest, worktree lifecycle, and fifteen test suites. The two branches ran in
   parallel off the same base, and #86's own body draws the line: *"The plugin's own
   layout mirror is a separate product and is not touched here."* The word "board"
   names two different products — #89's is panes-as-tickets inside herdr; the chain's
   is the separate Rust daemon in `herdr-linear-board`.

4. **There is no green baseline anywhere on the board repository.** Four CI runs
   exist, all on PR #2's branch. `main` and PR #1's branch have never run CI.

A fifth fact shapes how anything gets verified: **`shrimpshack` has no CI.** The
plugin's own harness says so in its header comment. `MERGEABLE / CLEAN` on those five
pull requests means "no textual conflict and no required checks", not "tested".

### Requirements

- **R1 — The plugin chain is internally consistent before it lands.** #82's head is
  an ancestor of #83's head, and each seam above remains in sync.
- **R2 — The plugin suite passes on the composed result.** `PASS` is read from the
  harness's own verdict line at the stack tip, after the restack, with the composed
  gates satisfied honestly rather than relaxed.
- **R3 — `#89`'s disposition is decided by Shawn and recorded.** It is not closed as
  superseded on this plan's assumption, because it is not superseded.
- **R4 — Each chain lands as one atomic squash merge**, so no intermediate state ever
  reaches `main` and the stack cannot half-land.
- **R5 — The board's version floor and its test fixture agree.** The code is right at
  `0.5.0`; the fixture is stale. It is raised rather than the floor lowered, and
  sourced so the next bump cannot desync it again.
- **R6 — Scenario 13 is rewritten against Linear mode or retired.** Linear mode
  preempting an explicitly-opened overlay is intended, so `scope.rs` is left alone and
  the scenario is not patched at the fixture — it tests a surface that no longer exists.
- **R7 — The installed plugin is refreshed between the two landings.** The board
  reads the work plugin from its installed root, not from `main`, so landing the
  plugin does not by itself change what the board sees.
- **R8 — Shawn can check the result himself.** The last step is something he opens
  and clicks, not a green log.

### Acceptance Examples

- **AE1 — the restack holds.** `git merge-base --is-ancestor` reports every parent's
  head inside its child, across all four plugin seams.
- **AE2 — the suite is honestly green.** The harness prints `PASS` at the stack tip,
  and the run is confirmed to have executed the suite rather than exited early.
- **AE3 — the board accepts the plugin.** `board linear snapshot` returns a snapshot
  instead of `{"error":{"code":6,...}}`.
- **AE4 — the feature works.** Shawn opens a herdr space, sees his Linear issues,
  picks a project or view, opens one issue and reads it in full.

### Scope Boundaries

**In scope.** Restacking, verifying, and landing the seven pull requests; the
version-floor mismatch; triage of the TUI end-to-end failure; refreshing the installed
plugin between landings; the manual verification pass.

**Out of scope.** Implementing the board's issue-detail-parity plan (this work
unblocks it, it does not do it). `#87` ("stop a folder-trust Enter from quitting the
new session") — an unrelated draft on `main`. Raising the plugin's version beyond
0.5.0. Building CI for `shrimpshack`.

### Dependencies

- `gh stack` v0.1.0 (installed; Stacked PRs confirmed enabled on both repositories —
  `gh stack checkout` returns exit 2, "not in a stack", not exit 9, "unavailable").
- `bats` at `/opt/homebrew/bin/bats`, which is not on the default `PATH`.
- `~/.claude/tools/honest-run/run.sh` for any long check.

### Outstanding Questions

- **Settled 2026-09-18 — R3.** `#89` stays open; the chain lands first and #89 rebases
  onto it. See KTD3.
- **Settled 2026-09-18 — R6.** Linear-mode preemption is intended; scenario 13 is
  rewritten against Linear mode or retired. See U6.
- **Blocking — raised during U2 (2026-09-18).** The stack carries real Slate ticket ids
  and internal product names that `main` deliberately swept out. Minimal fix: correct the
  nine failing assertions and leave the fixture a mix of real and fictional. Complete fix:
  finish the anonymisation across the stack's fixture additions and their tests, matching
  `main`'s policy. The second is more correct and larger.
- **Deferred — after this plan.** Which `/work:bind` design wins when #89 is rebased:
  session-scope binding, workspace-argument binding, or both coexisting. It surfaces
  at that rebase, not now.
- **Deferred.** Whether the product intends #89's panes-as-tickets board to survive
  alongside the Rust board daemon. The code cannot answer it; both were built
  knowingly in parallel.

---

## Planning Contract

### Key Technical Decisions

**KTD1 — Land each chain as one atomic `gh stack` merge.**
`gh stack merge --yes --squash` merges every member up to a chosen pull request into
the base in a single all-or-nothing operation. This removes the dilemma the handoff
posed. Bottom-up merging would need a `rebase --onto main` and a fresh suite run at
each of four levels; merging top-down into each parent would collapse five reviewable
pull requests into one commit. Atomic landing needs neither: the stack rebases once,
the suite runs once at the tip, and each pull request still squashes to its own commit
on `main`.
(session-settled: user-directed — chosen over per-pull-request merging: squash-on-landing
is the standing preference, and `gh stack merge` is atomic, so that preference does not
force a restack cascade.)

Two consequences worth stating plainly:
- It answers the handoff's fifth question. Asking whether the suite passes at #82, #83,
  #86 and #88 individually is asking about states that will never exist on `main`. The
  meaningful run is at the tip, after the restack.
- All-or-nothing is the desired property here, not a constraint to route around: a
  groundwork layer that lands without the layer that makes it visible is exactly what
  this repository's own history says to avoid.

**Answered at the merge (2026-09-19): one squashed commit per pull request.**
`gh stack merge --yes --squash` put five commits on `main`, each titled after its own
pull request, and two on the board's. Neither the CLI help nor GitHub's stacked-pull-request
docs state this; it was settled by observation, not by reading.

**KTD2 — Restack only the one broken seam, then adopt the chain as a stack.**
`gh stack init` adopts existing branches rather than recreating them. The chain needs
`feature/work-plugin-config` (#83) moved onto the current head of
`feature/work-plugin-initiative` (#82); the three seams above it are already in sync
and carry forward with it.

**KTD3 — `#89` stays open; the chain lands first and #89 rebases onto it.**
(session-settled: user-directed — chosen over landing #89 first and over closing it as
superseded: it is parallel work carrying Part B, and keeping it open is the reversible
option.) The earlier reading — including the one in this session's own scoping synthesis
— was that #89 was a big-bang branch the chain replaced. The file evidence says
otherwise.
Three options, with what each costs:

| Option | What it costs | When it is right |
|---|---|---|
| Land the chain, keep #89 open | One rebase of #89, **plus the `/work:bind` reconciliation** — a product decision between session-scope and workspace-argument binding, argued afterwards against the design this landing installs | #89 is genuinely parallel work — which the evidence says it is |
| Land #89 first, then the chain | Three rebases across the six shared files; blocked anyway, since #89's base #83 is still a draft and its body lists ten unresolved review items | The chain depended on #89 — it does not |
| Close #89, recover specific files | Loses Part B and the whole two-way board. Not file-separable: #89 threads board sync through seven existing skills, `hooks.json` and `commands/work.md` | Only if Shawn has abandoned that product |

**Chosen: land the chain, keep #89 open, rebase it afterwards.** It is the cheapest, and
it is reversible where closing is not. U3 records the rebase upstream before U1 moves
anything.

**A product decision waits behind it.** #89 and #88 are two answers to "what does
`/work:bind` bind". #89 binds the herdr *session* to a Linear scope (organization,
team, project or initiative); the chain binds per *workspace* from arguments the board
hands over. Head to head, `skills/bind/SKILL.md` and `lib/binding.sh` differ by 411
insertions and 353 deletions — the same file written twice, not landed twice.
Reconciling them is Shawn's call, and it surfaces when #89 is rebased, not now.

**Landing the chain makes #88's per-workspace binding the incumbent.** That is not
neutral: afterwards, choosing #89's session-scope design means changing shipped code on
`main` rather than picking between two branches. The decision stays open either way,
but its price is not symmetric, and it should be made knowing that.

**Part B lives in #89.** #83 is titled "part A" and its body says Part B covers the
herdr mapping in a separate pull request. #89's plan claims it outright: it supersedes
Part B of the config plan. Nothing in #86, #88 or #90 implements it.

**KTD4 — Fix the board's floor mismatch at whichever end is wrong, not by relaxing
the check.** The board refuses plugin 0.4.0 against a 0.5.0 requirement while its own
fixture supplies 0.4.0. One of the two is stale. This repository has a recorded
learning that a gate widened the first time it fires was never a gate, so the fix is
to correct the stale end — not to lower the floor to make the suite pass.

### Technical Design

The plugin chain, as it stands on the remote:

```
main (e70bf42)
 └── feature/work-plugin-initiative   #82   ✓ contains current main
      ╳  BROKEN SEAM — 8 commits missing below
      └── feature/work-plugin-config  #83   (draft)
           ├── feature/work-snapshot-board   #86  ✓ in sync
           │    └── feature/work-bind-handoff  #88  ✓ in sync
           │         └── feature/work-issue-detail  #90  ✓ in sync
           └── feature/work-plugin-board      #89  ✓ in sync  (draft, 45 unique files)
```

The eight commits stranded below the seam include a `main` merge and
`test(work): a test cannot reach the repository it lives in`. That test is a gate
written after the branches above it, which is precisely the composition case this
repository has already written up: both sides being green says nothing about their
union, so the suite must run after the restack, not before.

Two gates in `plugins/work/tests/run-tests.sh` are load-bearing here:
- `version_sync_check` compares `plugins/work/.claude-plugin/plugin.json` against the
  repo-root `.claude-plugin/marketplace.json`. #86 touches both.
- `HERDR_LINEAR_MIN_SUITES` is **26 at the stack tip** against 27 suite files — stale by
  one, not ten. (17 is `main`'s value; every branch in the chain already bumped it:
  initiative 20, config 22, snapshot-board 24, bind-handoff and issue-detail 26.) The
  harness's own comment says to raise it when suites are added.

The board chain needs no restack: both branches sit at `main`'s tip and the single
seam is in sync. Only the two end-to-end failures stand between it and landing.

### Assumptions

- `gh stack init` can adopt the chain from the existing `worktrees/work-issue-detail`
  worktree, which is already on the top branch. Five of the six branches are checked
  out across worktrees, and git refuses a second checkout of the same branch, so this
  is verified at execution time rather than assumed (U1).
- `gh stack submit --auto --open` marks existing drafts ready, which is how #83's draft
  status clears. `--auto` is required: a bare `submit` opens a full-screen editor that
  blocks under a PTY. Whether `submit` also rewrites existing pull request titles and
  bodies is unverified — and it matters, because a squash merge bakes each body into
  `main`'s history. U1 checks before submitting.
- `gh stack merge --squash` is expected to produce one commit per pull request rather
  than one for the whole stack. `gh stack merge --help` does not say, so U1 confirms it.
- The board reads the work plugin from an installed root
  (`BOARD_WORK_PLUGIN_ROOT`, "read on every request, from the caller's environment
  first"), so U4's refresh step is required rather than cosmetic.

### Implementation Constraints

- **Two peer sessions are live in these repositories.** `Issue detail parity` is busy
  in `herdr-linear-board/worktrees/issue-detail-parity`, and
  `herdr-board-work-interface-82` holds a board worktree. Check before moving any
  branch either of them has checked out.
- **Never use bare `git stash`** — the stash stack is shared across worktrees.
- **Read the harness's verdict line, never an exit code or an empty log.** Run long
  checks through `~/.claude/tools/honest-run/run.sh --expect`.
- **`gh pr merge` must not be used on a stack member** — it cannot merge a stack.
- **`gh stack link` must not be used** — it creates no local tracking, so a later
  `merge` will not see the layer.

### Sequencing

U3 → U1 → U2 → U4 → U5 → U6 → U7 → U8.

**U3 runs first, before any branch moves.** #89 branches off #83. Once the restack
rewrites #83's head, #89's merge base falls back and GitHub renders old #83's Part A
commits as #89's own changes — which destroys the very "45 files exist nowhere in the
chain" evidence U3 puts in front of Shawn. U3 edits no branch, so running it first
costs nothing.

**U5, U6 and U7 (the board work) do not depend on the plugin landing.** `live-e2e` is
a GitHub-hosted job that checks out only the board repository and installs no work
plugin: `40-linear-mode.sh` stubs its own manifest into a temporary root, and
`41-linear-bind-handoff.sh` — the only scenario that reads an installed plugin — is
provider-gated and excluded from the provider-free CI run. A plugin refreshed on
Shawn's machine cannot reach that job. The board chain can land on U5 and U6 alone.

**U8 is where both landings and both installed-artifact refreshes converge.** It is
the only step that needs the real installed plugin and the real installed board.

---

## Implementation Units

### U1 — Restack the plugin chain and adopt it as a stack

**Goal.** #82's head becomes an ancestor of #83's, all four seams read in sync, and
the five branches are registered as one stack with pull requests linked.

**Requirements.** R1, R4.

**Repo.** `shrimpshack`.

**Files.** None edited. This unit moves branches only.

**Approach.**
0. **Free the branches the rebase must move.** `gh stack rebase` checks out each branch
   it rewrites, and git refuses a branch already checked out elsewhere. `git worktree
   list` shows `feature/work-plugin-config` held by `worktrees/work-plugin-config` and
   `feature/work-bind-handoff` held by `worktrees/work-snapshot-board` — both sit above
   the broken seam. Detach each (`git -C <worktree> checkout --detach`) before starting,
   and re-check each back onto its branch once the stack has landed. A worktree holds
   its branch whether or not a session is live in it, so the peer-session check is a
   separate concern, not this one.
1. Confirm no peer session is mid-work in those worktrees before detaching them.
2. ~~Confirm the `--squash` commit granularity before spending the restack.~~
   **Checked 2026-09-18 — unresolvable ahead of the merge.** `gh stack merge --help` and
   GitHub's stacked-pull-request docs both describe only the all-or-nothing property and
   say nothing about commit shape. The natural reading of "all members of the stack ...
   are merged into the base branch" is one squashed commit per pull request, but that is
   inference, not confirmation. It does not gate the restack: U1 and U2 are required
   under either outcome. The answer becomes observable at U4, before Shawn authorises
   the merge, and is recorded in KTD1 then.
3. Restack #83 onto the current head of #82, carrying the three branches above it.
   Run this from `worktrees/work-issue-detail`: `gh stack init` checks out the top
   branch, and that worktree is the only place where the checkout is a no-op.
   `gh stack init --base main` with the five branches bottom-to-top adopts them;
   `gh stack rebase` repairs the seam. Prefer the tool's own repair over a hand-rolled
   `git rebase --onto`, and fall back to the manual form only if the tool refuses.
4. Resolve conflicts if the stranded `main` merge collides. Reconcile counts rather
   than eyeballing: a `.bats` append-collision can silently produce an unbalanced file
   because git matches the shared trailing `}` as common context.
5. Run `gh stack submit --auto --open`. `--auto` is required: a bare `submit` opens a
   full-screen editor that blocks under a PTY. Before running it, check what it does to
   the existing pull request titles and bodies — each becomes a squash commit message
   on `main`. If it would overwrite them, submit without `--open` and clear #83's draft
   separately.

**Test scenarios.**
- All four seams report in sync via `git merge-base --is-ancestor` (AE1).
- `gh stack view --json` lists five branches, each with its pull request number, and
  no branch reporting `needsRebase`.
- #83 is no longer a draft.
- Each pull request's body still reads correctly for a squash message — in particular
  that no first line names a stale base.

**Verification.** The seam check must be run with a shell array, not an unquoted
variable — zsh does not word-split, and an unquoted pair list silently collapses to a
single iteration that reports one misleading line.

---

### U2 — Prove the plugin suite on the composed result

**Goal.** The harness prints `PASS` at the stack tip after the restack, with the
composed gates satisfied rather than relaxed.

**Requirements.** R2.

**Repo.** `shrimpshack`.

**Files.** `plugins/work/tests/run-tests.sh` (the suite floor only, if raised).

**Approach.**
1. Run the full harness at the tip with `bats` on `PATH`, through `honest-run` with a
   marker that proves the suite actually executed.
2. If it goes red, check the base alone before attributing blame — a pristine-green
   base proves the failure is interactional, a pristine-red base means it was
   inherited and belongs in a separate audit.
3. Treat any newly-firing gate as a contract meeting, not a bug. Satisfy it honestly.
   Do not adjust a threshold to make the stack pass.
4. Raise `HERDR_LINEAR_MIN_SUITES` from 26 to 27 — the actual suite count at the tip —
   as the harness's own comment instructs.

**Test scenarios.**
- The harness's final line reads `PASS` (AE2).
- `version_sync_check` passes — `plugins/work/.claude-plugin/plugin.json` and the
  repo-root `.claude-plugin/marketplace.json` both read 0.5.0.
- The suite-count guard reports the real count, and the floor matches it.
- The test added by #82 (`a test cannot reach the repository it lives in`) passes
  against the branches written before it existed.

**U2 RESULT (2026-09-18) — RED at the tip, interactionally.** `verdict:
DID-NOT-COMPLETE (exit 1)`, which is the predicted surfacing of a genuine failure. Nine
tests fail across `fake-linear.bats`, `herdr-write.bats` and `start.bats`. The same three
suites are **green at the pre-restack tip** (162 tests), so this is the composition
firing, not damage from the restack.

**Cause.** `main` commits #84 and #85 ("use a fictional ticket and tool name") swept real
Slate tickets and product names out of the fixtures. The branches above #82 were written
before that sweep and still assert the originals. After the restack the fixture file is a
patchwork: `main`'s anonymised bodies (`WEB-3308`, `WEB-2670`, "Frame Effects") beside the
stack's additions, which still carry `WEB-3318`, `WEB-2870` and "AI Canvas Tools".

**Scope of what the stack still carries un-anonymised:** ten ticket ids (`WEB-2870`,
`WEB-3200`, `WEB-3300`, `WEB-3303`, `WEB-3312`, `WEB-3317`, `WEB-3318`, `WEB-3319`,
`WEB-3320`, `WEB-3400`) and 37 occurrences of real internal product names ("AI Canvas
Tools" ×27, "Web Creation" ×7, "AI Tools drawer" ×2, "Detach Foreground" ×1).

**This is a decision, not a mechanical fix** — see the open question below. Landing
either way requires the suite green (R2).

**Verification.** `bash ~/.claude/tools/honest-run/run.sh --expect "PASS" -- bash plugins/work/tests/run-tests.sh all`,
with `/opt/homebrew/bin` on `PATH`. A run with no verdict line did not finish;
absence of the line is the signal, not the log's silence.

---

### U3 — Record `#89`'s disposition and its rebase upstream

**Goal.** The settled decision on `#89` is written down, and the one SHA its later
rebase needs is captured before any branch moves.

**Requirements.** R3.

**Repo.** `shrimpshack`.

**Files.** None.

**The decision (settled 2026-09-18).** `#89` stays open. The chain lands first, then
#89 rebases onto it (session-settled: user-directed — chosen over landing #89 first,
which would force three rebases and is blocked anyway while #83 is a draft, and over
closing it, which would lose Part B and the two-way board).

**Approach.**
1. **Capture #89's rebase upstream now:** `git rev-parse
   origin/feature/work-plugin-config` — `39d89e3` at the time of writing. After U1
   rewrites #83 and U4 squashes the chain, that commit stays reachable through #89's own
   history but no `merge-base` query returns it, so the later
   `git rebase --onto main 39d89e3 feature/work-plugin-board` needs it recorded here.
   This is the only reason U3 runs before U1.
2. Leave #89 open and untouched. Do not close it, do not retarget it.
3. Note in #89 — a comment is enough — that it is parked pending the chain landing, so
   the next reader does not re-litigate whether it was abandoned.

**What this defers, deliberately.** The `/work:bind` reconciliation. #88 binds per
workspace from board arguments; #89 binds the herdr session to a Linear scope. Landing
the chain makes #88's design the incumbent on `main`, so choosing #89's later means
changing shipped code rather than picking a branch. That is a product decision for the
rebase, not for this plan.

**Test scenarios.** Not applicable — this unit records a decision and a SHA.

**Verification.** The SHA is written into this plan before U1 runs, and `gh pr view 89`
still reports the pull request open.

---

### U4 — Land the plugin stack and refresh the installed plugin

**Goal.** All five plugin pull requests are on `main` as five squashed commits, and
the installed work plugin the board reads is the landed 0.5.0.

**Requirements.** R4, R7.

**Repo.** `shrimpshack`.

**Files.** None.

**Approach.**
0. **Rehearse the handshake before the point of no return.** Build the board from PR
   #2's branch, point `BOARD_WORK_PLUGIN_ROOT` at the stack tip's `plugins/work`, and
   require `board linear snapshot` to return a snapshot. Until this passes, nothing has
   ever exercised the plugin against the board — U2 proves the plugin alone — and the
   merge is irreversible.
1. **Confirm `origin/main` is still the commit U2's tip was built on.** If it moved,
   re-run U2: `gh stack merge` rebases onto whatever `main` is at merge time, there is
   no CI to catch a bad union, and two peer sessions are live in these repositories.
2. **Ask Shawn to authorise the merge.** Do not merge without it.
3. `gh stack merge --yes --squash` up to #90.
4. **Refresh the installed plugin.** The board reads
   `~/.claude/plugins/installed_plugins.json`, key `work@shrimpshack` — which today
   records **version 0.1.0** at `~/.claude/plugins/cache/shrimpshack/work/0.1.0`, pinned
   to commit `a1470237` from 2026-09-06. That is four minor versions behind. Pull
   `~/.claude/plugins/marketplaces/shrimpshack` to the landed `main`, reinstall the
   `work` plugin, and assert the `work@shrimpshack` entry reports 0.5.0. That file, not
   the cache directory name, is what the board and `41-linear-bind-handoff.sh` read.
5. Re-run the harness on landed `main` through `honest-run`. The Definition of Done
   requires the suite to pass at the landed state, and no other unit owns that run.

**Test scenarios.**
- `board linear snapshot` returns a snapshot in the step-0 rehearsal, before the merge.
- `main` contains all five changes, and `gh pr view` reports each as merged.
- The `work@shrimpshack` entry in `installed_plugins.json` reads 0.5.0.
- The harness prints `PASS` on landed `main`.
- No branch was left half-landed — atomicity means this cannot happen, so confirm it
  rather than assume it.

**Verification.** Assert `origin/main` is an ancestor of the landed result. Read each
merged pull request's resulting commit subject on `main`.

---

### U5 — Reconcile the board's plugin version floor

**Goal.** The board's required floor and its end-to-end fixture state the same
version, and `40-linear-mode.sh` stops failing with exit 6.

**Requirements.** R5.

**Repo.** `herdr-linear-board`.

**Files.** `e2e/40-linear-mode.sh` (line 21 writes the stand-in manifest; lines 126-127
assert the refusal message), `e2e/README.md`. The floor itself —
`crates/board-core/src/lib.rs:41`, `PLUGIN_VERSION_FLOOR` — stays at `0.5.0`.

**Approach.** The direction is settled by the history: `40-linear-mode.sh` passed at
`6acb8b1` and fails at `f95df2a`, the commit that raised the floor to `0.5.0` and moved
the constant into `board-core`. That commit swept the Rust tests and the docs and
touched no end-to-end file. So the code is right and the fixture is stale.

1. Raise the stub manifest to `0.5.0` and update the floor assertion to match.
2. Source the number rather than repeating it. `PLUGIN_VERSION_FLOOR` is a Rust `pub
   const` that no `board` subcommand prints, so nothing shell-reachable exposes it
   today. Have `e2e/lib.sh` derive it once by grepping the constant out of
   `crates/board-core/src/lib.rs` and export it, then have `40-linear-mode.sh` and
   `41-linear-bind-handoff.sh` read that variable instead of their own literals. Fixing
   only the literal leaves the same trap armed.
3. Check `e2e/41-linear-bind-handoff.sh`'s `BIND_FLOOR` for the same staleness.
4. Update `e2e/README.md`'s scenario table, which documents the 40-linear-mode stand-in
   root as being "at the 0.4.0 floor", to state 0.5.0.

This corrects a decision the handoff recorded as settled: "the board's plugin version
floor stays at 0.4.0 — the board detects the new read by script presence, not by
version". The board's own error message names a version comparison, and the constant
says `0.5.0`.

**Test scenarios.**
- `board linear snapshot` returns a snapshot rather than
  `{"error":{"code":6,"message":"plugin unavailable..."}}`. This proves the *fixture*,
  not the installed plugin — the scenario points at the stub root this unit is editing.
  AE3 is proven where the real installed plugin is in play: U4's rehearsal and U8.
- `40-linear-mode.sh` passes.

**Not in this unit.** `41-linear-bind-handoff.sh`'s no-skip check belongs to U8. It
reads the *installed* plugin, which is at 0.1.0 until U4's refresh, so it would print
the `skipped:` line this plan forbids. It is also provider-gated and never runs in CI.

**Verification.** Run the affected end-to-end scripts directly and read their
per-script verdict, not the suite's aggregate.

---

**U5 ADDITION (2026-09-19) — the anonymisation crosses into the board.**
`snapshot.bats` and the board pin the *same* eight fixture hashes, and the board vendors
its own copies, so U2's sweep made the two sides disagree. The board half is therefore
part of U5, not a follow-up:

- Re-vendor the six changed fixtures into
  `crates/board-core/tests/fixtures/linear-snapshot/` and regenerate its `VERSION`.
  Both sides now pin identical hashes.
- Three Rust sources hard-code the old identifiers and needed hand fixes:
  `crates/board-core/tests/linear_fixtures.rs` (looked up `issues["WEB-3312"]`, which is
  why the board's own test panicked with "no entry found for key"),
  `crates/board-tui/tests/update/pane_title.rs`, and `crates/board-tui/tests/linear/mod.rs`.
- Twenty-three `insta` `.snap` files render the fixtures as width-aligned ASCII.
  `AI Canvas Tools` → `Frame Effects` is 15 characters to 13, so the padding shifts.
  These are **regenerated** (`INSTA_FORCE_UPDATE=1`), never hand-edited.

**A pre-existing flaky test sits in the way of a clean full run.**
`agy_catalog.rs` → `load_from_cli_bounded_rejects_oversized_stdout_and_kills_the_child`
asserts a child is killed in under 2 seconds and measured 5.56s while the machine was
compiling. It is load-sensitive and unrelated to this work. Do not "fix" it here; confirm
it passes on a quiet machine and leave it.

---

### U6 — Retire scenario 13 against the settled Linear-mode behaviour

**Goal.** `13-jump-to-pane.sh` stops failing, because it no longer tests a surface that
exists.

**Requirements.** R6.

**Repo.** `herdr-linear-board`.

**Files.** `e2e/13-jump-to-pane.sh`, and `e2e/README.md`'s scenario table.
`crates/board-cli/src/scope.rs` and `main.rs` are deliberately **not** touched.

**The settled behaviour.** PR #2 makes `board tui` open Linear mode whenever a herdr
space id is present: `scope.rs` routes on the space id alone with no overlay exception,
and `space_identity` reads the id from the plugin-context JSON as well as the
environment variable. That is intended — starting from the Linear board is the point of
PR #2 (session-settled: user-directed).

What follows from it: `plugin pane open --plugin herdr-board --entrypoint board` always
lands in Linear mode, so a herdr pane gives up the card/run board — run history, retry
and jump-to-pane. The kanban board is still reachable from a shell with no herdr space
id, so the loss is scoped to panes. Scenario 13 covers exactly the pane path, which is
why it fails on 3 of 3 runs: commit `aec7bcf` hardened the shared launch helper to clear
both variables, and scenario 13 is the one scenario that does not use that helper.

**Approach.**
1. Rewrite `13-jump-to-pane.sh` against Linear mode, or retire it. Do **not** patch it to
   clear the space id — that would test a path no person can take. If a rewrite keeps
   the jump-to-pane assertion, drive it through the Linear board's own pane selection.
2. Update `e2e/README.md`'s scenario table to match whichever it becomes.
3. Do not add a `scope.rs` overlay exception. The preemption is the decision, not a bug.

**Test scenarios.**
- `13-jump-to-pane.sh` passes, or is deliberately gone and the suite's scenario list no
  longer expects it.
- The board still opens the kanban board from a shell with no herdr space id — the
  fallback that scopes this loss to panes.
- A baseline exists: CI is run once on PR #1's branch, which has never run it.

**Verification.** Read the scenario's own output. The uploaded evidence artifact carries
no pane capture, so a claim about what rendered needs a real run.

---

### U7 — Land the board stack

**Goal.** Both board pull requests are on `main` as squashed commits, and the `board`
on this machine is built from that `main`.

**Requirements.** R4, R7.

**Repo.** `herdr-linear-board`.

**Files.** None.

**Depends on.** U5 and U6 only — not U4. `live-e2e` is a GitHub-hosted job that
installs no work plugin, so nothing done to the installed plugin changes whether it
passes.

**Approach.**
1. Confirm `live-e2e` is green on PR #2 after U5 and U6.
2. Check that no peer session is mid-work on either board branch — `Issue detail
   parity` and `herdr-board-work-interface-82` both hold board worktrees.
3. **Ask Shawn to authorise the merge.**
4. Adopt the two branches as a stack, then run `gh stack submit --auto` to create the
   stack on GitHub. Without this, `gh stack merge` finds no stack to merge — local
   adoption alone is not enough, and `gh stack link` is not a substitute.
5. Confirm `gh stack view --json` lists both branches with their pull request numbers.
6. `gh stack merge --yes --squash` up to #2.
7. **Rebuild and reinstall the board.** `~/.local/bin/board` is currently a symlink into
   the `herdr-board-work-interface` worktree's `target/release/board` — PR #1's code,
   without PR #2's pickers and without U5's floor fix. A landed commit does not update
   it, exactly as R7 says of the plugin. Rebuild from landed `main` and repoint the
   symlink at that build.

**Test scenarios.**
- `live-e2e` passes on PR #2, and the run's commit is the branch head, not an older one.
- Both pull requests report merged.
- `board --version` (or the binary's resolved path) shows the landed `main` build, not
  a worktree build.

**Verification.** Read the check run that gated the merge and confirm its commit is the
branch head. Resolve `~/.local/bin/board` and confirm where it now points.

---

### U8 — Manual verification pass

**Goal.** Shawn confirms the feature himself, in the product.

**Requirements.** R8.

**Repo.** Neither — this runs against the installed plugin and board.

**Files.** None.

**Depends on.** Both landings (U4 and U7) *and* both installed-artifact refreshes — the
work plugin at 0.5.0 and the `board` binary built from landed `main`. This is the only
step that needs either.

**Approach.** Start from an **unbound** herdr space, so each step exercises the pull
request that added it:

1. Open the board in the space — the pickers render (#86, #88).
2. Pick a space, project or view (#88).
3. Start `/work:bind` from the board (#88).
4. See the bound issues render — this is the step binding makes meaningful.
5. Open one issue and read it in full (#90).

Order matters here. Asking to see issues *before* binding gives an unbound snapshot
(`"groups": []`, `"issues": {}`), which renders an empty board — indistinguishable from
a broken one. Binding first makes step 4's result readable.

**Test scenarios.** AE4, performed by hand.
- `41-linear-bind-handoff.sh` runs against the refreshed 0.5.0 plugin and does **not**
  print its `skipped:` line. This check lives here, not in U5, because only now does the
  installed plugin clear the floor.

**Verification.** Shawn's own confirmation. Green checks are not this step; the whole
point of landing the stack atomically is that there is something to look at when it
lands.

---

## Incident — PR #91 orphaned by the U1 force-push (2026-09-18)

**What happened.** While U1 ran, a peer session opened **PR #91 ("decide a project's
repository per team, once per project and team")** from
`worktrees/work-scope-repo-per-team`, based on `feature/work-bind-handoff` (#88's head).
It was created at 21:26, after this plan's worktree survey, and was never adopted into
stack #92. `gh stack submit` then force-pushed #88 from `f85321c` to `5b013a4`, so #91's
base moved out from under it.

**State now.** #91 is `CONFLICTING / DIRTY` and its diff reads **+8907 / −184 across 71
files** instead of its own three commits. Nothing of its work is lost — its three commits
are intact at `be2833a`, the worktree is clean, nothing is unpushed.

**Repaired 2026-09-18 (approved by Shawn).** Rebased `--onto 5b013a4 f85321c`, which
replayed all three commits onto #88's new head. One conflict in `start.bats`, resolved to
keep both changes: `WEB-3308` (the anonymised identifier from the new base) and
`$PAIRKEY` (this branch's actual change). Force-pushed with lease; `be2833a → 14442c1`.
#91 is back to **+564/−63 across 9 files, MERGEABLE / CLEAN**, from +8907/−184 across 71.

**#91 is parked like #89, and for the same reason.** It is a *sibling* of #90 — both sit
on #88 — so a linear stack cannot contain both; `gh stack merge` up to #90 will not carry
it. When the stack lands, `feature/work-bind-handoff` is deleted, GitHub retargets #91 to
`main`, and its diff reads as the whole chain again. Its rebase upstream
`5b013a4d1087e9fc2bf173a95c8cccecff60ebad` is recorded here and on the pull request, so
the post-landing fix is `git rebase --onto main 5b013a4 feature/work-scope-repo-per-team`.

**Two siblings now outlive the chain**, both parked with a recorded upstream: #89 (on #83,
upstream `39d89e3`) and #91 (on #88, upstream `5b013a4`).

**What this changes for the plan.** U1's peer check was written as "confirm no peer
session holds a branch the rebase will move". That is too narrow: #91 held no stack
branch — it *depended on one*. The check belongs on dependents, not just holders.

---

## Execution log (2026-09-18 → 19)

| Unit | State | Evidence |
|---|---|---|
| U3 `#89` parked | done | upstream `39d89e3` recorded here and on the PR |
| U1 restack + submit | done | stack #92 live, #83 ready, all titles/bodies preserved |
| U2 plugin suite | done | 840 tests, `verdict: PASS`, commit `e8977e4` |
| — `#91` repair | done | orphaned by the force-push, rebased, `be2833a → 14442c1` |
| U5 board floor + fixtures | done | commits `b50f172`, `aaad1bd`, pushed |
| U6 scenario 13 | done | kanban half retired, CLI half kept |
| U4 land plugin stack | done | five squashed commits, `04eedf7` → `31dfca1` |
| — plugin refresh | done | `work@shrimpshack` 0.1.0 → **0.5.0**, sha `31dfca1` |
| U7 land board stack | done | two squashed commits, `3e4aa51`, `e392ba1` |
| — board rebuild | done | built from `e392ba1`; `~/.local/bin/board` repointed off the worktree |
| — AE3 handshake | **proven** | `board linear snapshot wG` returned schema 1, 452 issues, 16 groups — no code 6 |
| U8 manual pass | **waiting on Shawn** | everything it needs is in place |

**What the anonymisation actually cost**, since the plan under-scoped it: 276
replacements across 18 plugin files, then 33 board files, because the two repositories
pin the same eight fixture hashes and the board vendors its own copies. It also reached
23 `insta` snapshots, which render the fixtures as width-aligned ASCII — "AI Canvas
Tools" to "Frame Effects" is two characters shorter, so the card padding moves.

**Two false greens caught on the way**, both worth remembering:
- `cargo test -p board-tui` passed 34 tests and proved nothing. Every real target in
  that crate is behind `required-features = ["fake-client"]`; CI uses `--all-features`.
- A run under `INSTA_UPDATE=always` accepts whatever it renders, so its green is not
  evidence. Every board verdict here was re-taken with no insta variables set:
  snapshots 212, `linear_fixtures` 8, `update` 148.

**Still open, not blocking:** `agy_catalog.rs` and `opencode_catalog.rs` each assert an
oversized child dies within 2 seconds and measured 4–5s on a loaded machine. They are
load-sensitive and unrelated to this work, but cargo stops at the first failing target,
so they hide everything after them in a full-workspace run.

---

## Third parked branch — `feature/issue-detail-parity` (recorded 2026-09-19, pre-merge)

The board repository has a live session working in
`worktrees/issue-detail-parity`, with uncommitted changes, on a branch built on
top of board #1 and an older point of #2. It has **no open pull request**, so nothing
breaks publicly when the board stack lands — but a squash merge puts *new* commits on
`main`, so this branch's own history will not be in `main` and its eventual diff would
read as the whole #1+#2 chain.

Checked before merging rather than after, which is the lesson #91 taught.

- **Rebase upstream:** `6acb8b1303f191f9452183edfe1d48c1ed351fe6` — its merge-base with
  board #2.
- **Its own work:** seven commits from `a2ee1ce` (linear.issue reads one issue whole)
  through `023c488` (apply review findings).
- **After the board lands:**
  `git rebase --onto main 6acb8b1 feature/issue-detail-parity`.

Its worktree is **not** touched here: a live session holds it and four files are
uncommitted. Whoever owns that session runs the rebase.

**Three branches now outlive their bases**, each with a recorded upstream:

| Branch | Sat on | Upstream | Has a PR |
|---|---|---|---|
| `feature/work-plugin-board` (#89) | plugin #83 | `39d89e3` | yes |
| `feature/work-scope-repo-per-team` (#91) | plugin #88 | `5b013a4` | yes |
| `feature/issue-detail-parity` | board #1/#2 | `6acb8b1` | no |

---

## Closeout (2026-09-24)

**The objective is met.** The board's Linear mode is on `main` in both repositories, and
the issue-detail work it was blocking is underway (board #4, another session).

Landed since this plan's own run, by the session working the shrimpshack side:
`#91` (repository decided per project *and* team — the branch this plan orphaned and
repaired) and `#93` (context cascades down the herdr session).

**`#89` ("herdr Linear board and per-session binding") is still NOT superseded.**
A peer session suggested `#93` may have replaced it, because the titles overlap. Checked
against `main` at `8c86f68`: **45 of #89's files are still absent**, the same count as
before — the whole board engine (`lib/board-*.sh`, `bin/board-sync.sh`,
`skills/board/SKILL.md`), per-session binding (`lib/session.sh`,
`lib/session-binding.sh`), the herdr plugin manifest, and `lib/worktree-remove.sh`.
What `#93` did land is the *binding split* — `record.sh`, `scope-record.sh`,
`context-filter.sh` — which is adjacent work, not the same work. The R3 decision stands:
keep it open.

**But its rebase got harder, and the recorded upstream is no longer enough.** `#93` split
`lib/binding.sh` into four files. `#89` carries +144/−7 against the old single file, so
`git rebase --onto main 39d89e3 feature/work-plugin-board` will now conflict across a
file that no longer exists. Whoever picks it up should expect to place those changes into
the new split by hand, not to resolve a textual conflict.

**Two facts from `#91`/`#93` that invalidate assumptions in this plan:**
- herdr workspace ids are per server — two sessions can each hold a space called `w1`.
  Space records are now keyed by session *and* space. Any reasoning here that treats a
  space id as globally unique is stale.
- `lib/binding.sh` no longer exists as a single file.

**Parked branches, current:**

| Branch | Upstream | State |
|---|---|---|
| `#89` herdr Linear board and per-session binding | `39d89e3` | open, CONFLICTING — 45 files still unique |
| `#91` repository per project and team | `5b013a4` | **merged** |
| `feature/issue-detail-parity` | `6acb8b1` | superseded by board #4 |

**Handed on, not done here:** the plugin's skill lib-sourcing gate computes its closure
for `skills/` and `commands/` only. `bin/` and `hooks/` source libraries by name with
nothing checking them, so the `#93` library split broke three scripts silently until a
test that runs them caught it. That gate is the natural next piece of work — it is the
same class of defect as the fixture/floor desync this plan hit twice.

---

## Verification Contract

**`shrimpshack` has no CI.** `plugins/work/tests/run-tests.sh` is the entire automated
verification contract, stated in the harness's own header. `MERGEABLE / CLEAN` on the
five plugin pull requests means no textual conflict and no required checks — it is not
evidence of a passing suite.

| Gate | Command | Passing signal |
|---|---|---|
| Plugin suite | `bash ~/.claude/tools/honest-run/run.sh --expect "PASS" -- bash plugins/work/tests/run-tests.sh all` | A `verdict:` line, and the harness's own final `PASS` |
| Seam integrity | `git merge-base --is-ancestor <parent> <child>` per seam, driven from a shell **array** | Exit 0 on all four seams |
| Stack shape | `gh stack view --json` | Five branches, pull request numbers present, no `needsRebase` |
| Board end-to-end (CI) | `live-e2e` on PR #2 | Every CI-runnable scenario `PASS`. This job installs no work plugin, so it cannot prove the handshake |
| Board end-to-end (local) | `e2e/run-all.sh` on the machine holding the refreshed plugin | `41-linear-bind-handoff.sh` runs rather than printing `skipped:` |
| Plugin/board handshake | `board linear snapshot` against the real installed plugin | A snapshot, not protocol code 6 |

Standing rules for this repository, all of which have burned a previous session:
- Read the harness's verdict line. A missing verdict means the run did not finish.
- `/opt/homebrew/bin/bats` is not on the default `PATH`.
- Never infer a pass from an empty log, a zero exit code, or a silent background job.
- A `skip` counts as ok in bats, so a green suite can still have tested nothing.
- **A genuinely failing suite surfaces as `DID-NOT-COMPLETE`, not `FAIL`.** With
  `--expect "PASS"`, honest-run never matches its marker on a red run, so it reports the
  run as unfinished. Read the log's final line to tell a red suite from a run that never
  started. The Goal Capsule's stop condition is worded around `FAIL`; this is what the
  operator will actually see.

## Definition of Done

**Global.**
- All seven pull requests are merged through the atomic stack merge, and the resulting
  commit shape on `main` is recorded (see KTD1 — per-pull-request squashing is expected
  but confirmed in U1, not assumed).
- The plugin suite passes at the landed state, with the suite-count floor raised from
  26 to 27.
- `#89` is still open, its rebase upstream (`39d89e3`) is recorded, and the
  `/work:bind` fork it carries is written down for the rebase that follows.
- The board's floor and fixture agree on `0.5.0`, and the fixture reads the number from
  a single source rather than repeating it.
- `13-jump-to-pane.sh` is rewritten against Linear mode or retired, and `scope.rs` is
  unchanged.
- PR #1's branch has run CI at least once, so the board has a baseline.
- The installed plugin is the landed 0.5.0 — asserted from the `work@shrimpshack` entry
  in `installed_plugins.json`, not from a cache directory name.
- The installed `board` is built from landed `main`, not from a worktree.
- Shawn has opened the board and read one Linear issue in full (AE4).
- No temporary branch, scratch worktree or experimental commit from the restack is
  left behind.

**Per unit.** Each unit's own test scenarios pass, and every merge in U4 and U7 was
authorised by Shawn before it ran.

## Sources

- `docs/handoff.md` — the directional brief this plan validates against. Three of its
  recorded decisions did not survive: the 0.4.0 floor (U5), `#89` as superseded (U3),
  and the four-level per-branch suite question (KTD1). Its fourth open question —
  whether board #2 was `CONFLICTING` and therefore never ran checks — is answered no:
  the suite ran to completion and 38 of 40 scenarios passed.
- The board's CI history and failing job log: `40-linear-mode.sh` passing at `6acb8b1`
  and failing at `f95df2a`, and `13-jump-to-pane.sh` failing identically on 3 of 3 runs.
- `crates/board-core/src/lib.rs:41` (`PLUGIN_VERSION_FLOOR`),
  `crates/board-cli/src/scope.rs` (`tui_mode`), `e2e/lib.sh:469` (the helper that
  clears the space id) — the three places the board regressions live.
- `docs/solutions/workflow-issues/rebasing-onto-a-base-that-added-enforced-gates.md` —
  gates compose on a rebase; both branches green says nothing about their union.
- `plugins/work/tests/run-tests.sh` — the verification contract, and the two gates
  that matter here.
- `gh stack merge --help` and `gh stack submit --help` — atomic all-or-nothing merge;
  `--open` marks existing drafts ready.
