---
title: A both-hosts session with a stale herdr pane id still gets a host - Plan
type: fix
date: 2026-11-02
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
---

# A both-hosts session with a stale herdr pane id still gets a host - Plan

## Goal Capsule

- **Objective:** A PM session that announces both herdr and Rex keeps working when its `HERDR_PANE_ID` is stale or missing, and is refused only when auto has no recorded or installed evidence that separates the hosts.
- **Means:** After the live pane proofs fail, `detect()` falls back to two recorded or physical facts that need no live pane: which announced host commands are installed, and which host this session's own registry row names (KTD1, KTD2).
- **Authority:** The code and tests in `plugins/auto`, then `docs/handoff.md` (direction only), then the PM's direction of 2026-11-02.
- **Stop conditions:** Stop and ask if a unit needs the send-guard rules to change, or if the verb in U4 turns out to need a new typed approval.
- **Ships:** Open PR 1 and say ready with the head sha and counts. The PM merges. Nothing is published.

## Product Contract

### Summary

PR #157 (tell herdr and Rex apart by proof) fixed a session whose herdr pane id is live. It still refuses when `herdr pane get <id>` fails, because Rex cannot prove a pane either. This plan adds two fallback proofs below the live ones. It never picks a host by priority.

### Problem Frame

The PM on the Mac Studio (pane w2:pCM) inherited `REX_SESSION` from an earlier Rex launch. After its herdr pane moved, `HERDR_PANE_ID` went stale. `herdr pane get` fails, so herdr answers `resolved: env`, which `_proves` rejects. Rex cannot prove a pane. `_tell_apart` (`plugins/auto/lib/terminal_host.py:235`) returns no host and every pane read, `prompt-item` and watcher call refuses. Measured on the Studio, by file reads only (a standing rule bars worker sessions from running herdr commands):

| Fact | Studio result |
|---|---|
| `rex` command on PATH | absent. `REX_SESSION` is inherited noise there |
| registry rows with `host: rex` | 0 of 986 rows in `sessions/default.w2.jsonl` |
| registry row for pane w2:pCM | present: `host: herdr`, `resolved: herdr`, `terminal_id` set, fresh `at` |
| `CLAUDE_CODE_SESSION_ID` in the session environment | set, and equal to the registry row's `session_id` (checked on this machine) |
| `herdr` command | at `/opt/homebrew/bin/herdr` |

Not measured: a live `herdr pane get` or `herdr status server` on the Studio. Doing so would break the rule above, and the plan does not need it.

### Requirements

- R1. When no live pane proof selects a host, and exactly one announced host's command is installed, `detect()` selects that host.
- R2. When both announced hosts are installed, `detect()` selects the host named by this session's registry row (`CLAUDE_CODE_SESSION_ID`), only if that host is announced.
- R3. When neither fallback decides, `detect()` refuses as before. The refusal names which facts were missing.
- R4. A live proof still outranks both fallbacks. When both hosts prove, `detect()` still refuses.
- R5. The send-guard, `is_host_command`, `send_class` and the driver-pane typing rule do not change.
- R6. Sessions that announce one host or none resolve exactly as before, with no new process calls.
- R7. A read-only verb prints which fact decided the host for this session, so a refused session can see what is missing. It writes nothing.

### Scope Boundaries

- Not in scope: repairing a moved pane's stored `pane_id` and `terminal_id` at record time (issue #149 "repair a moved herdr pane's id and terminal id at record time"). That is PR 2.
- Not in scope: choosing a host by priority, or by `HERDR_ENV` alone.
- Not in scope: a verb that writes the registry or the environment. A running session cannot change its environment, and the write belongs to #149.
- Not in scope: publishing or version bumps.

## Planning Contract

### Key Technical Decisions

- KTD1. **Installed-command filter, then registry row.** The ladder is: live proof (existing) → exactly one announced host installed → registry row host → refuse. Each rung only runs when the one above did not decide. The installed filter is a physical fact: a host whose command is absent cannot hold the session. The registry row is the session's own proven record, written by `record_session` at SessionStart from a live proof. (Chosen after measurement over the programme space key: the space key is derived from the same registry row's server and workspace, so it adds no independent evidence, and it needs a programme to exist.)
- KTD2. **Session id comes from `CLAUDE_CODE_SESSION_ID`, read inside `_tell_apart`.** `detect(env)` has no session id argument today, and `_session_host` in `programme_lifecycle.py:219` already prefers the registry row when it has an id. The fix moves that preference down into `detect()` for the both-announced case, so callers that use `terminal_host.current()` (pane reads, `send_prompt`, the watcher) get it too. A missing or unmatched id falls through to refuse.
- KTD3. **A row only counts when its host is announced and interactive.** `lookup(sid, include_headless=False)` filters headless rows. If the row's host is not in the announced set, ignore it: the environment contradicts the record, which is the ambiguity case.
- KTD4. **Memo key.** The `_proved` memo key gains the session id and the PATH-based installed result, so a later registry write is picked up. A refusal is still never memoised.
- KTD5. **The refusal text stops advising `env -u` first.** It lists what was missing (live proofs failed, which host commands are installed, whether a registry row exists). `env -u ...` stays as the last-resort fix for a session that has no row.
- KTD6. **The verb is read-only.** U4 adds `programme.sh host`, which prints the decision rung and the facts. It needs no new typed approval because it changes nothing and reads only files and PATH. A write verb is rejected for this PR: see Scope Boundaries.

### Output Structure

No new directories. New test file `plugins/auto/tests/unit/host-stale-pane.test.sh`.

## Implementation Units

- U1. **Characterization tests for the three refused cases.**
  - Goal: pin today's behaviour before changing it, using fakes for herdr and Rex.
  - Requirements: R1 R2 R3 R4 R6.
  - Dependencies: none.
  - Files: `plugins/auto/tests/unit/host-stale-pane.test.sh` (new). Model on `plugins/auto/tests/unit/terminal-host-detect.test.sh`.
  - Test scenarios:
    - Live pane id plus `REX_SESSION`: herdr, unchanged (R4).
    - Stale pane id plus `REX_SESSION`, no `rex` on PATH: herdr (R1). Fails before U2.
    - Only `HERDR_ENV` plus `REX_SESSION`, no `rex` on PATH: herdr (R1). Fails before U2.
    - Stale pane id, both commands on PATH, registry row for the session says herdr: herdr (R2). Fails before U3.
    - Same, row says rex but `REX_SESSION` unset: refuse (KTD3).
    - Both commands on PATH, no row: refuse, text lists the missing facts (R3).
    - Both hosts prove live: refuse (R4).
    - Single-host and no-host environments make zero process calls (R6).
  - Verification: the two R1 cases and the R2 case fail on main; the rest pass.

- U2. **Installed-command rung.**
  - Goal: R1.
  - Dependencies: U1.
  - Files: `plugins/auto/lib/terminal_host.py` (`_tell_apart`), tests in the U1 file.
  - Approach: after the live proofs return no single host, take the announced names whose `host_named(n).installed()` is true; exactly one selects it, with `Detection.proof` left empty.
  - Test scenarios: the U1 cases for R1; both uninstalled refuses with a distinct reason.
  - Verification: the R1 tests pass; `terminal-host-detect.test.sh` still passes.

- U3. **Registry-row rung.**
  - Goal: R2, KTD2, KTD3.
  - Dependencies: U2 (same function, sequential).
  - Files: `plugins/auto/lib/terminal_host.py`, `plugins/auto/lib/session_registry.py` (reuse `lookup` and `host_of_row`; no new public API unless the import cycle forces one), tests.
  - Approach: when more than one announced host is installed, read `CLAUDE_CODE_SESSION_ID` from `env`, call `session_registry.lookup(sid)`, and accept `host_of_row(row)` only if that name is announced. Wrap the lookup so a broken registry file falls through to refuse, never raises.
  - Test scenarios: the U1 R2 cases; unreadable registry file; headless-only row ignored; row for another session ignored.
  - Verification: send-guard tests (`send-guard-hosts.test.sh`, `review-fixes-hosts.test.sh`) pass unchanged.

- U4. **Read-only `programme.sh host` verb and refusal text.**
  - Goal: R3, R7, KTD5, KTD6.
  - Dependencies: U3.
  - Files: `plugins/auto/lib/terminal_host.py` (a `explain(env)` helper returning the rung and facts), the `programme.sh` verb table (find the dispatch with `grep -n` during ce-work), `plugins/auto/tests/unit/host-stale-pane.test.sh`, the `docs/` wording test `host-wording.test.sh`.
  - Test scenarios: verb output names the deciding rung for each U1 case; the verb makes no write (assert the data dir is unchanged); refusal text lists missing facts.
  - Verification: if the verb needs a typed approval entry or a send-guard allowlist change, stop and bring the design to the PM.

## Parallelism Analysis

All four units edit `terminal_host.py` or its single test file, so they run in sequence: U1 → U2 → U3 → U4. Nothing here fans out to workers. Parallel work that does help after U4 is review: `ce-code-review` and the wording check can run at the same time, kept to two reviewers to stay under the rate limit.

## System-Wide Impact

- Callers of `terminal_host.current()` (`programme_sources`, `programme-watch.py`, `programme_gone_panes`, `programme_record`) change behaviour only in the both-announced case that used to refuse.
- `session_registry` imports `terminal_host`; `terminal_host` importing `session_registry` at call time (not import time) avoids a cycle. Use `load_lib_module` inside the function, as `host_herdr.py` does.
- The SessionStart hook budget (5 s) does not grow: the fallback adds a PATH lookup and a file read.

## Risks

| Risk | Mitigation |
|---|---|
| A stale registry row names the wrong host | Row must be interactive, for this session id, and its host announced. A wrong guess here needs a session that moved hosts mid-life: after a move SessionStart writes a new row |
| `CLAUDE_CODE_SESSION_ID` is inherited by subagents | They inherit the parent id, so they resolve to the parent's host, which is correct |
| The installed rung selects herdr when herdr is installed but the session is in an uninstalled Rex | Not possible: an uninstalled Rex cannot hold the session |
| A test that passes without exercising the rung | Mutate each rung's condition once and confirm a test fails (memory: a green test can be incapable of failing) |

## Sequencing

PR 1 (this plan): U1 to U4. PR 2 (later, separate): #149, which repairs the stored pane id and terminal id at record time.

## Verification Plan

- `bash plugins/auto/tests/run.sh` through `~/.claude/tools/honest-run/run.sh`, with an `--expect` marker found from the runner's own summary line.
- Mutation check for U2 and U3.
- Manual: with a fake `HERDR_PANE_ID=w9:pZZZ` and `REX_SESSION=x` in a shell where `rex` is not on PATH, `programme.sh host` names herdr and the installed rung.
