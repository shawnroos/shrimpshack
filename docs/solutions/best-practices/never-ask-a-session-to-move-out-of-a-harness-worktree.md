---
title: "Never ask a session to move out of a Claude Code harness worktree"
date: 2026-10-27
category: best-practices
module: plugins/auto
problem_type: best_practice
component: tooling
severity: high
applies_when:
  - "a hook or verb checks the session's working directory and blocks or advises a cd"
  - "a feature requires an agent session to work from a fixed folder"
  - "a Stop hook block names a fix the session may not be able to apply"
  - "the session was started in, or entered, a folder under .claude/worktrees/"
retire_when: "Claude Code lets an EnterWorktree-isolated session move its working directory to another worktree; check by running cd into a sibling worktree from an isolated session and seeing whether the next command still runs there"
tags: [harness-worktree, enterworktree, cwd, stop-hook, deadlock, programme-worktree, fix-line, unclearable-block]
---

# Never ask a session to move out of a Claude Code harness worktree

## Context

Auto 0.16 (#128 "give each programme one fixed PM working directory") required the programme PM to work from `worktrees/programme-<run>`. The stop hook blocked with `cwd_drift` whenever the PM's cwd was elsewhere. `programme_worktree.cd_can_stick` decided whether a `cd` would last by checking only the session's start directory.

The Peek PM session had been switched into a Claude Code harness worktree, `.claude/worktrees/task+focus-flash`. Its transcript rows carry `worktreeSession` and `worktreePath`. In that state, Claude Code:

- resets the shell to the harness worktree after every Bash command, so `cd` never sticks;
- refuses any command run from another worktree ("This session is isolated in the worktree … Refusing to run it there");
- refuses `EnterWorktree` for any path outside `.claude/worktrees/`;
- refuses every later command, including programme verbs, after Shawn ran `/cd` to the programme worktree himself.

The session start directory was the main checkout, so `cd_can_stick` said yes. The hook kept blocking. It blocked 12 times in one night, and the PM asked Shawn the same three-option question every hour for nine hours.

## Guidance

- **Do not require an agent session to work from a fixed folder.** The PM now works from wherever its session runs, harness worktrees included. Nothing in auto asks it to move. Programmes that already recorded a programme worktree still release it safely at end; see `docs/solutions/logic-errors/a-clean-git-status-does-not-prove-a-worktree-is-safe-to-remove.md`.
- **Before advising a move, check what the session can change from inside itself.** A start-directory check misses harness isolation. A session pinned by Claude Code can follow no cwd advice at all.
- **A block the session cannot clear must not fire again on every turn.** The stop hook now shows a programme block once per session, programme and reason set, then lets the stop through until the reasons change. The record lives in the programme home, keyed by session id, so a cwd change does not reset it.
- **Every refusal names a fix that works in the calling session.** A fix line that sends the agent back to the step that refused it is a loop, just like the move advice.

## Why This Matters

`cwd_drift` was a correction aid, not a security bound: the PM controls its own cwd. See `docs/solutions/best-practices/a-switch-that-restrains-an-agent-cannot-read-the-agents-environment.md`. A correction aid that cannot be satisfied gives no protection. It costs a turn on every stop and pushes the agent into asking Shawn about something nobody can fix. Before relying on any rule keyed on where a session works, look for harness worktree isolation (transcript `worktreeSession`, paths under `.claude/worktrees/`).

## When to Apply

Apply this to any hook, verb or skill that reads the session cwd to decide whether to block, refuse or advise. Plans: `docs/plans/2026-10-22-0954-feat-programme-worktree-plan.md` added the requirement, and `docs/plans/2026-10-27-0918-feat-pm-self-setup-plan.md` removed it.
