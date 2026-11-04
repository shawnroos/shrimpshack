---
title: "Score a guard that reads shell text against real bash, and name where its review stops"
date: 2026-11-04
category: best-practices
module: plugins/auto
problem_type: best_practice
component: testing_framework
severity: high
applies_when:
  - "a hook or check decides from command text what a shell will run"
  - "a guard's tests are hand-written expected results with no outside source of truth"
  - "review rounds on a text guard keep finding new spellings"
related_components:
  - tooling
tags: [send-guard, pretooluse-hook, shell-parsing, test-oracle, differential-testing, guard-rail, stopping-rule]
---
# Score a guard that reads shell text against real bash, and name where its review stops

## Context

The send-guard in `plugins/auto/lib/send_guard.py` was cut down to one job: refuse a literal send into a PM's pane. Its lexer still read shell text in five passes built around `shlex`. All 257 hand-written cases in `plugins/auto/tests/unit/send-guard-literal.test.sh` passed, and two review rounds fixed more gaps.

A thermo-nuclear review then ran generated commands through `/bin/bash` with a logging `herdr` shim and compared what bash ran with what the guard said. It found 411 false allows in 3,333 scored cases. One was an ordinary shape: `echo ">"; herdr pane run <pane> ls`. `shlex` drops the quotes, so `>` reads as a redirect, and the send loses its command position.

## Guidance

**Use the shell as the oracle.** A guard's own cases only hold what its author thought of. Generate commands by crossing prefixes, spellings and wrappers, run each through real bash with a shim that only logs, and fail on any false allow. `plugins/auto/tests/unit/send-guard-bash-oracle.test.sh` does this. It runs a deterministic subset to stay under about a minute, and it proves it can fail with an allow-all guard.

**Run the oracle under more than one shell.** `/bin/bash` on macOS is 3.2. It rejects a `case` inside `$( )` and has no `coproc`, so a 3.2-only oracle drops those forms as syntax errors and reads as clean. Homebrew bash 5 exposed both.

**Prefer one reader to several passes.** Each pass tracked quoting alone and patched what the last one lost. Gaps sat in the seams, so a fix in one pass could not close them. Replacing the passes with one reader that yields final words closed the class: 0 false allows across 3,424 generated cases. The line count barely changed. The win was fewer concepts.

**Keep the oracle's limits in view.** Its prefixes wrap the outside of each form, so it missed a comment or `case` inside `$( )`. Two later reviewers found those by reading. An oracle shows what its generator reaches.

**Name the stopping rule before review starts.** Text reading never finishes: `ksh -c`, `env -S`, `coproc` and `echo '<send>' | bash` all ran a send in probes. The plan states that this refusal is a guard rail and a computed send gets through. So a spelling a worker could plausibly write is a defect, and the rest are accepted limits listed in the PR. Without that line, each round reopens the same argument.

## When to Apply

Any check where a wrong allow is silent, the input is shell text, and passing tests read as proof. If the check must actually hold against a hostile agent, reading text is the wrong tool, and it needs a runtime check instead.

## Related

- `docs/solutions/security-issues/narrowing-a-shell-command-guard-needs-default-deny-and-a-differential.md`: the earlier default-deny approach this replaced, whose differential method still applies.
- `docs/plans/2026-11-04-1658-feat-auto-permissive-by-default-plan.md`: the decision to reduce the guard.
