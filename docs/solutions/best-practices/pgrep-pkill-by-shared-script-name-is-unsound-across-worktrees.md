---
title: "Selecting processes by a shared script name double-counts and reaches into other worktrees"
date: 2026-08-12
module: plugins (worktree process selectors)
problem_type: best_practice
component: tooling
severity: high
category: best-practices
applies_when:
  - "counting how many runs of a script are live, or reaping leftovers after a run"
  - "the repo has sibling git worktrees checked out of the same repo, so peer sessions run the same script paths"
  - "writing teardown, supervision, or cleanup code that kills processes it did not itself spawn"
  - "a status line, guard, or concurrency ceiling reads a count of running work"
symptoms:
  - "`pgrep -f <shared-script-name>` systematically double-counts: every run matches the launcher process AND the parent shell whose argv carries the same string"
  - "a parked waiter matches a third time, so one live suite read as three concurrent suites"
  - "`pkill -f <shared-script-name>` is a repo-WIDE selector and kills peer sessions' in-flight work in sibling worktrees"
  - "no error is raised either way: the count is silently wrong, and the kill silently succeeds on the wrong target"
root_cause: scope_issue
related_components:
  - testing_framework
  - development_workflow
tags:
  - pgrep
  - pkill
  - process-selection
  - worktrees
  - argv-matching
  - lsof-cwd
  - teardown
  - shell
---

## Context

This repo is worked on from several git worktrees of the same clone at once — parallel
sessions, each with its own branch, each running the same scripts from the same relative
paths. Under that layout, a process's command line stops identifying which worktree it
belongs to. Every worktree runs `plugins/spawn/tests/unit/launch.bats`; every worktree's
lens spills into `${TMPDIR}/gwlens.XXXXXX` (`plugins/spawn/lib/lens.sh:210`). The argv
string is the same everywhere.

The friction showed up while counting concurrent test suites during the work that landed
PR #41 ("spawn: say what the user gets, not what it is built on"), PR #42 ("spawn: say what
each surface can actually reach") and PR #43 ("spawn: stop rewriting the operator's gw").
Observed in this session's runs: `pgrep -f <test-script-path>` reported three suites when
exactly one was running. The over-count was systematic, not a one-off — one live run
matched twice, and a parked waiter added a third.

The mechanism is not a quirk. `pgrep -f` matches against the **full argv** of every
process, and a shell invoked to run a script carries that script's path in its own argv.
So a single run produces at least two matches: the process actually executing the script,
and the parent shell whose command line names it. Nothing about that is specific to this
repo; any `-f` matcher on a script path behaves the same way.

The same string is also what `pkill -f` selects on — which turns a "clean up my leftovers"
line into a machine-wide one.

## Guidance

**Never use a shared script or program name as the selector for `pgrep -f` or `pkill -f`.**
Match on something unique to the run, or scope candidates by resolved working directory.

The unsound form:

```sh
# WRONG: counts the runner AND its parent shell, and every sibling worktree's copies
n=$(pgrep -f 'plugins/spawn/tests/unit/launch.bats' | wc -l)

# WORSE: a repo-wide kill. Reaches into every other worktree of this clone
# and destroys peer sessions' in-flight work.
pkill -f 'plugins/spawn/tests/unit/launch.bats'
pkill -f gwlens
```

The cwd-scoped form. A process's working directory is a fact about which worktree it
belongs to; argv is not. Resolve it with `lsof`, then filter:

```sh
# The worktree that owns a pid, via its cwd.
owner_worktree() {
  local cwd
  cwd=$(lsof -a -p "$1" -d cwd -Fn 2>/dev/null | grep '^n' | head -1 | sed 's/^n//') || return 1
  [ -d "$cwd" ] || return 1                       # a deleted cwd is NOT "mine"
  git -C "$cwd" rev-parse --show-toplevel 2>/dev/null
}

mine=$(git rev-parse --show-toplevel)
for pid in $(pgrep -f 'launch.bats'); do
  [ "$(owner_worktree "$pid")" = "$mine" ] || continue
  kill "$pid"
done
```

This is not a new idiom for the repo. `clawcrush` already resolves ownership exactly this
way: `set_pid_cwd` reads the cwd with `lsof -a -p "$1" -d cwd -Fn`
(`plugins/clawcrush/scripts/crush.sh:842`), and `owner_worktree_of`
(`plugins/clawcrush/scripts/crush.sh:851-857`) maps that path to a worktree top via
`worktree_of` (`plugins/clawcrush/scripts/crush.sh:767-773`), failing closed when the cwd
is unresolvable or deleted. Reuse it rather than reinventing it.

Two details that matter:

- **`-d cwd` is a resolved path, not a string a process chose.** It cannot be spoofed by
  how the command happened to be invoked, and it survives the parent-shell duplication —
  the shell and its child share a cwd, so the filter still needs a dedup, but both land in
  the correct worktree instead of an arbitrary one.
- **Unresolvable means "not mine".** If `lsof` returns nothing, or the cwd no longer
  exists on disk, treat the process as out of scope rather than assuming ownership. That
  is the direction that cannot destroy someone else's work.

The sound counter-case: a **unique** string is a fine selector. The spawn bats teardowns
reap with `pgrep -f "$WORK"` (`plugins/spawn/tests/unit/launch.bats:77`), where `$WORK` is
a per-run `mktemp -d` under `$TMPDIR` (`plugins/spawn/tests/unit/launch.bats:17`,
canonicalized at line 22). No other worktree, and no other run in this one, can produce
that string. The rule is about **shared** names, not about `-f` being forbidden.

## Why This Matters

Two distinct failure modes, with different costs.

**A wrong count misleads whoever reads it.** Nothing errors. `pgrep -f` returns a number,
and the number is plausible. In this session it said three concurrent suites where one was
running — enough to make a human or an agent conclude that runs were leaking, and to go
fix a problem that did not exist. A count that over-reports by a fixed factor is worse than
one that fails, because it never announces itself.

**A wrong kill destroys work that isn't yours.** `pkill -f <shared name>` is a repo-wide
selector by construction: the same script path substring exists in every worktree checked
out of the same clone, and shared temp prefixes like `gwlens` exist in every run on the
whole machine. A teardown line written to reap one suite's leftovers will reap a peer
session's live gateway, its in-flight test run, or its editor's helper — silently, and with
no way to recover the work that was mid-flight. This is unrecoverable in a way a bad count
is not.

There is a live instance of the shape in the tree: `plugins/spawn/tests/unit/lens.bats:486`
asserts `pgrep -f 'gwlens'` returns zero matches. Because `gwlens` is the shared `mktemp`
prefix (`plugins/spawn/lib/lens.sh:210`), that assertion reads any concurrent run's
temp-dir path, anywhere on the machine, as a leaked orphan from this test.

## When to Apply

All of these, together, is when the hazard is live:

- **More than one worktree of the same repo exists on the box** — the default for parallel
  sessions here. One clone, one checkout: the hazard is much smaller, though the
  parent-shell double-count survives even then.
- **The selector is a name shared across runs** — a script path, a binary name, a fixed
  temp-dir prefix, a plugin directory. If two independent runs could both produce the
  string, it is not a selector.
- **The matcher reads full argv** — `pgrep -f`, `pkill -f`, `ps | grep`, any `-f`-style
  full-command-line match. Matching the process *name* only (`pgrep <name>`, no `-f`) does
  not pick up the parent shell, but still cannot tell worktrees apart.

Applies to counting and to killing alike. Counting is where the defect is cheap and
therefore easy to leave in; killing is where it costs someone else their session.

## Examples

**Before — a repo-wide reaper.** A teardown that kills by script name:

```sh
teardown() {
    pkill -f 'plugins/spawn/tests/unit/launch.bats' 2>/dev/null || true
}
```

Run from `~/projects/shrimpshack` while a sibling session runs the same suite in
`~/projects/shrimpshack/worktrees/gateway-plugin`, this kills both. The author sees a
green local run and no signal at all that anything was destroyed.

**After — a unique per-run selector.** What the suite actually does
(`plugins/spawn/tests/unit/launch.bats:72-82`):

```sh
teardown() {
    if [ -n "${GW_PID:-}" ]; then
        kill "$GW_PID" 2>/dev/null || true
        wait "$GW_PID" 2>/dev/null || true
    fi
    for p in $(pgrep -f "$WORK" 2>/dev/null); do
        [ "$p" = "$$" ] && continue
        kill -9 "$p" 2>/dev/null
    done
    rm -rf "$WORK"
}
```

`$WORK` is this run's `mktemp -d` (line 17), so the match set cannot contain another
worktree's processes. The explicit `[ "$p" = "$$" ] && continue` (line 78) stops the
reaper from killing its own shell should that shell ever land in the match set — cheap
insurance against exactly the self-match that `-f` matchers produce.

**After — cwd scoping when the name has to be shared.** When you genuinely cannot make the
string unique (an already-running third-party binary, a fixed daemon name), scope by
resolved cwd instead, the way `clawcrush` resolves ownership
(`plugins/clawcrush/scripts/crush.sh:838-857`, used at `crush.sh:1543`):

```sh
mine=$(git rev-parse --show-toplevel)
for pid in $(pgrep -f gwlens); do
  cwd=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | grep '^n' | head -1 | sed 's/^n//')
  [ -n "$cwd" ] && [ -d "$cwd" ] || continue                    # fail closed
  [ "$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" = "$mine" ] || continue
  kill "$pid"
done
```

`pgrep -f` is fine as the *candidate generator* here — it is over-broad, and the cwd filter
is what makes the set correct. The order matters: broad match, then narrow by a fact the
process cannot fake.

## Related

- [A default-allow safety gate on a regex dialect projection silently drops matches](../logic-errors/default-allow-regex-projection-gate-silently-drops-nudges.md)
  — the same shape one layer up: a selector broader than the thing it names, default-allow,
  failing with no signal. Its prevention rule (invert to default-deny on identity) is what
  cwd scoping does here.
- `plugins/clawcrush/scripts/crush.sh` — the reference implementation of the ownership
  predicate. `plugins/clawcrush/CLAUDE.md` states the ownership axis and the fail-closed
  posture as standing rules for that plugin.
