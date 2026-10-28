---
title: Spinoff REX Backend - Plan
type: feat
date: 2026-10-28
topic: spinoff-rex-backend
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-brainstorm
execution: code
---

# Spinoff REX Backend - Plan

## Goal Capsule

- **Objective:** A person who runs Claude Code inside REX can run `/start-session`, `/start-split` or `/start-workspace` and get a briefed session in the right place, without herdr, cmux or any other multiplexer installed.
- **Means:** Add REX as a fourth peer backend in `plugins/spinoff/skills/spinoff/scripts/spinoff.sh`, beside herdr, cmux and ghostty.
- **Product authority:** This plan owns the REX backend and a gap audit of the existing ghostty backend. Refactoring the existing backends and a capability-table redesign are not active scope.
- **Open blockers:** None. Two forks are parked under Outstanding Questions.

---

## Product Contract

### Summary

Spinoff gains a REX backend with the same behavior herdr gives today: tab, split and workspace targets, a readiness wait, and answers to Claude's startup prompts. The plugin is shared, so REX detection must be strict and every behavior must be testable on a machine that has no REX. Ghostty already exists as a full backend (shipped in 0.9.0). It gets one audit pass against herdr's behavior, and only gaps that break the core promise ("one command, a briefed session appears") get fixed.

### Problem Frame

Spinoff's full experience depends on herdr. Someone using REX gets either a bare worktree with a manual `cd … && claude` line, or a bare Ghostty window that ignores their REX layout. REX is a real multiplexer with a CLI that can create tabs and splits, read a terminal's screen (`capture`), type into it (`send`, `send-key`) and wait on it, so it can match herdr instead of the weaker Ghostty path. The `rex` binary is not on `PATH` by default; it ships inside the Rex Server app bundle.

### Key Decisions

- KD1. **Finish line is REX parity with herdr.** Ghostty gets an audit and small fixes only. (session-settled: user-directed — chosen over equal-weight upgrades of both and over launch-only everywhere.)
- KD2. **Audience is a portable plugin for other people.** Detection must be strict and tests must not need REX installed. (session-settled: user-directed — chosen over a build tuned to Shawn's machine.) Governs R1, R8, R9.
- KD3. **REX is a peer backend added to `spinoff.sh`.** No refactor of herdr, cmux or ghostty, and no capability-table redesign. (session-settled: user-directed — chosen over splitting backends into files first and over a capability adapter.) Governs R2–R7.

### Requirements

**Detection and resolution**

- R1. Spinoff treats a session as announcing REX when `REX_SESSION` is set and the `rex` CLI resolves; an announced REX session never falls through to ghostty.
- R2. `rex` resolves from an explicit override, then `PATH`, then the Rex Server app bundle's install location, and the skill passes the resolved path down from the main session as it does for herdr and cmux.
- R3. A REX session whose binary cannot be resolved exits 4, and one whose server will not take the launch exits 5, each with a message that names the cause.

**Launch targets**

- R4. `--target tab` opens a new REX tab in the current session, rooted at the worktree, running a briefed Claude, named with `--label`.
- R5. `--target split` opens the briefed Claude beside the originating pane (right by default, left on request), unfocused, with the originating pane handed over as `--from-surface`.
- R6. `--target workspace` opens a new REX session with the briefed Claude on the left and `docs/handoff.md` rendered on the right, and the viewer is best-effort like herdr's.

**Readiness and honesty**

- R7. The new session's startup prompts (chiefly "new MCP servers found") are read from the screen and answered, so the session starts with its MCP servers.
- R8. A launch that failed to brief the session reports exit 3, never success.

**Proof and docs**

- R9. A drift test compares every `rex` subcommand and flag the script calls against the installed CLI's help, and fails (does not skip) when `rex` is present.
- R10. Stubbed tests cover tab, split left, split right, workspace, binary-missing and server-refused for REX without needing REX installed.
- R11. The spinoff skill documents the REX backend: detection, the `--from-surface` value, the binary override, and the exit codes.
- R12. An audit lists where ghostty falls short of herdr on the core promise, and each gap is either fixed or recorded as a known limitation in the skill.

### Key Flows

- F1. **Spin off from inside REX.** Covers R1, R4, R5, R6, R7. Shawn runs `/start-session`; the skill resolves `rex` and the originating pane; the script creates the worktree, opens the tab, launches Claude with the brief, answers any startup prompt, and prints the summary.
- F2. **REX is announced but unusable.** Covers R2, R3. The binary cannot be found or the server refuses; nothing launches, the worktree survives, and the exit code and message say which.

### Acceptance Examples

- AE1. **Covers R4, R7.** Given a REX session in repo A, when `/start-session` runs, a new tab named by the label opens in that session, Claude is in the worktree, and its brief is the first prompt.
- AE2. **Covers R1.** Given REX running inside Ghostty with `REX_SESSION` set, the launch goes to REX, not to a bare Ghostty window.
- AE3. **Covers R5.** Given `--target split --split-direction left`, the new pane sits left of the originating pane and focus stays where it was.
- AE4. **Covers R3.** Given `REX_SESSION` set and no resolvable `rex`, the run exits 4 and names the override that fixes it.
- AE5. **Covers R9.** Given a rename of a `rex` flag the script uses, the drift test fails.

### Scope Boundaries

- Not refactoring herdr, cmux or ghostty code.
- Not adding screen reading to Ghostty; its AppleScript dictionary has none.
- Not supporting REX on a remote server (`rex -S`): worktree paths would need to exist on the remote machine.
- Not changing the brief, handoff content or label convention.

### Outstanding Questions

**Deferred to Planning**

- Does an unannounced REX arm (server live but `REX_SESSION` unset) earn a place in detection like herdr's? Default is no, which keeps detection strict (KD2).
- How does the workspace target make a new REX session visible in the app (`rex new` does not display it; `rex do session.select` does)?
- Which static viewer renders the handoff in the right pane when the user has no pager preference?

### Dependencies / Assumptions

- Assumes the `rex` CLI keeps the verbs read from `rex --help` on 2026-10-28: `new`, `window new`, `run`, `split`, `capture`, `send`, `send-key`, `wait`, `whoami`. R9 exists because this is a beta.
- Assumes Claude Code sessions inside REX inherit `REX_SESSION` and `REX_BLOCK` as the REX guide states. Not yet verified from inside a REX pane.

---

## Planning Contract

Product Contract preservation: unchanged. The R/F/AE/KD IDs and meaning are as the brainstorm left them; the probe notes moved here from the Product Contract as Research.

### Research

All paths are under `plugins/spinoff/skills/spinoff/`.

- **Backend seam.** `scripts/spinoff.sh` dispatches seven verbs by `case "$LAUNCHER"` (`launcher_new_tab`, `launcher_new_workspace`, `launcher_new_split`, `launcher_find_left_pane`, `launcher_launch_agent`, `launcher_wait_ready`, `launcher_open_viewer`, defined together after `resolve_launcher`). Each backend supplies `launcher_<verb>_<backend>`. The shared launch region (after the `step "launcher:"` line) calls them and owns the brief-file guard, `KICKOFF_OK`, `LB_READY`, `VIEWER_OK`, and the summary and exit codes 3, 4 and 5.
- **Closest template: ghostty.** Ghostty's placement verbs create nothing: they record `GHOSTTY_PLACE` and set `LAUNCH_SFC="ghostty:pending"`, and `launcher_launch_agent_ghostty` creates the surface already running `$LAUNCH_CMD`. REX fits this shape because `rex window new` and `rex split` take the command at creation, so no unbriefed window can exist.
- **Closest template for readiness: herdr.** `launcher_wait_ready_herdr` polls the screen through `_screen_tail`, answers the folder-trust modal (`_trust_cursor`, `SPINOFF_FOLDER_TRUST`) and the MCP modal (`SPINOFF_MCP_MODAL`), and treats a ready footer (`shift+tab to cycle`, `bypass permissions`, `? for shortcuts`) as ready. It matches claude's footer, never a bare `❯`, which is also the shell prompt.
- **Resolution.** `resolve_bin NAME OVERRIDE EXTRA` walks override, `PATH`, `$SPINOFF_BIN_PATHS`, then colon-separated full-path extras (spaces in a path are fine). `_record_loud` and `resolve_launcher` hold the announce-then-fail logic behind exit 4 and 5; a forced backend falls through a catch-all `*)` arm so a new backend cannot silently launch nothing at exit 0.
- **Tests.** `scripts/spinoff.bats` stubs backends as scripts on a per-test `PATH` that log argv; `scripts/cli-drift.test.sh` extracts `"$HERDR" …` and `"$CMUX" …` call sites and checks each subcommand and long flag against the installed CLI's `--help`; `scripts/smoke.sh` forces `--launcher none`.
- **Not applicable.** No external research: three local backends set a strong pattern, and the REX CLI is the only external surface, probed live below.

Live probes on 2026-10-28 (Rex Beta 0.0.1792697926-gbd4573; ghostty backend from a herdr pane):

- The CLI is `/Applications/Rex Beta.app/Contents/Helpers/Rex Server.rex/Contents/MacOS/rex`, not on `PATH`. `/Applications/Rex Beta.app/Contents/MacOS/Rex` is the GUI app; running it hangs.
- `rex` has global flags `--autostart` (default true, starts a missing local server), `--timeout` (default 10s) and `-C CLIENT`. A probe that leaves `--autostart` on would start a server as a side effect.
- Inside a REX-spawned terminal the environment carries `REX_SESSION`, `REX_BLOCK`, `REX_SERVER`, `REX_BIN_DIR` and `TERM_PROGRAM=rex`. This confirms the guide's claim; outside REX, `rex whoami --json` still succeeds against a live server, so a live server alone proves nothing about the caller.
- `rex block inspect BLOCK --json` returns `.session_id` and `.block.window_id`, so a block ID is enough to find its session.
- `rex new LABEL --json` returns `.session_id` and `.initial_windows[0].block_ids`; `rex window new -s S LABEL -c DIR --keep-open --json -- CMD` and `rex split -s S -b B --split=right --focus=false --json -- CMD` return new block IDs in `.block_ids[0]`; `rex capture -s S -b B --trim` prints the screen; `rex kill SESSION` removes a session. `rex send-key`, `rex wait` (returns the child's exit status; `--for DURATION` bounds it) and `rex events` exist but were not exercised against a running Claude.
- `rex client ls` lists connected app clients; `rex -C CLIENT do session.select session_id=ID` shows a session in the app (from the REX guide; not exercised).
- Ghostty, from a herdr pane with `--launcher ghostty`: `--target tab` and `--target workspace` (window plus handoff viewer) work; `--target split` with a terminal ID as `--from-surface` splits right; `--target split` without `--from-surface` opens a tab and exits 0, with the downgrade named only in the summary's "NOT what was asked for" block. Ghostty still cannot read the screen, so its readiness is "the pid exists" and it cannot answer the MCP prompt; `launcher_find_left_pane_ghostty` is an empty stub.

### Key Technical Decisions

- KTD1. **REX is added as seven `launcher_<verb>_rex` functions plus a `rex)` arm in each dispatcher.** The new code mirrors the herdr and ghostty shape and shares nothing new with them; the modal-answering logic is copied from the herdr wait loop rather than extracted, because extraction edits the existing backends. (session-settled: user-directed — chosen over splitting backends into files first and over a capability adapter: keep the change small and reviewable; this KTD instantiates KD3 and governs R4–R8.)
- KTD2. **Resolution is `REX_BIN`, then `PATH`, then `$SPINOFF_BIN_PATHS`, then the Rex Server bundle path as the extra candidate.** The bundle path is the full `…/Rex Server.rex/Contents/MacOS/rex`; the GUI binary is never a candidate. Because another tool named `rex` can sit on `PATH`, a resolved binary only counts after `rex whoami --json` exits 0 (R2, R3).
- KTD3. **A session is announced when `REX_SESSION` is non-empty.** `resolve_launcher` records the announcement with `_record_loud rex …` and picks REX after the announced herdr and cmux arms and before the unannounced-herdr and ghostty arms; the ghostty arm gains a `-z "${REX_SESSION:-}"` guard so an announced REX session never falls through to ghostty (R1). Placing REX after herdr and cmux keeps every existing session's behaviour identical; a REX terminal opened inside a herdr pane resolves to herdr, and `--launcher rex` overrides it.
- KTD4. **Every `rex` call goes through one wrapper that passes `--autostart=false`.** A spinoff must never start a server, and a probe must never have side effects. Liveness is `rex whoami --json` exiting 0 through that wrapper; a failure after an announcement is exit 5 and prints what `rex` said on stdout and stderr.
- KTD5. **The target session comes from the main session, as `--from-surface` does.** The skill passes `REX_SESSION` and `REX_BLOCK` explicitly when it dispatches the background agent. The script uses `REX_SESSION` for `--target tab`, and for `--target split` derives the session from `--from-surface` with `rex block inspect BLOCK --json` (`.session_id`), falling back to `REX_SESSION`. A session that `rex session inspect` cannot find is a launch failure, reported as exit 5 wording.
- KTD6. **Placement creates nothing; the launch creates the surface running the brief command.** As in ghostty, the placement verbs record the target and return `LAUNCH_SFC="rex:pending"`; `launcher_launch_agent_rex` runs `rex window new` (tab), `rex split` (split) or `rex new` (workspace) with `-c "$WORKTREE" --keep-open -- sh -c "$LAUNCH_CMD" --json`, and sets `SURFACE_REF` to the returned block ID. `--keep-open` leaves the pane readable if `claude` exits. Split-left is native (`--split=left`), so there is no herdr-style swap step.
- KTD7. **Readiness reads the screen with `rex capture` and answers prompts with `rex send-key enter` or `escape`.** The loop copies herdr's behaviour: the same footer markers, the same folder-trust and MCP modal handling with the same `SPINOFF_*` variables, and the same ceiling `SPINOFF_READY_TIMEOUT_MS` (R7).
- KTD8. **"Claude is gone" is the block's child having exited.** The launch command is the block's only process, so `rex wait BLOCK --for 1s` returning an exit status (instead of timing out) proves `claude` exited; that case sets `KICKOFF_OK=0` and `KICKOFF_FAIL`, giving exit 3 (R8). The implementer confirms the exact timeout-versus-exit signal with a live `rex wait` before relying on it.
- KTD9. **The workspace target creates a REX session and tries to show it.** After `rex new`, spinoff selects the session in the first connected app client with `rex -C CLIENT do session.select session_id=ID`. A session created but not shown is reported in the summary ("created, select it in the Rex app") and is not a launch failure, because the briefed Claude is running (R6).
- KTD10. **The viewer is a right split running `glow`, then `bat`, else skipped with a warning.** This matches herdr and ghostty and resolves the "which viewer" question without inventing a pager (R6).

### Assumptions

- The REX CLI keeps the verbs and flags listed under Research; R9 is the guard because the app is a beta.
- `rex wait BLOCK --for DURATION` distinguishes "still running" from "exited" by exit status or output; KTD8 depends on it and U3 verifies it live first.
- Exactly one connected app client is the normal case for `rex client ls`; with several, KTD9 picks the first labelled `app` and reports which.

### Risks & Dependencies

- A different tool named `rex` on `PATH` would be called without the whoami check; KTD2 closes that.
- `--keep-open` leaves a finished pane behind after a successful `claude` exit; accepted, matching herdr's bare-shell outcome.
- Three copies of the modal-answering loop now exist (herdr, cmux, REX); a prompt-text change must land in all three. Extracting them is follow-up work, outside KD3.
- Dependency order: U1 → U2 → U3 → U4. U5 lands with each unit. U6 needs the final flag and variable names from U1–U3.

### Deferred to Follow-Up Work

Extracting the shared startup-prompt loop; REX on a remote server (already out of scope).

---

## Implementation Units

Parallelism: U1–U4 all edit `scripts/spinoff.sh`, so run them in order in one worktree. U6 (docs) can start in parallel with U5 once U1–U3 have fixed the names.

### U1. REX resolution, detection and failure reporting

- **Goal:** `--launcher rex` and `REX_SESSION` select the REX backend; a missing or unusable `rex` fails with exit 4 or 5 and a message that names the cause.
- **Requirements:** R1, R2, R3, R9 (partly); KTD2, KTD3, KTD4.
- **Dependencies:** none.
- **Files:** `scripts/spinoff.sh`; tests in `scripts/spinoff.bats`.
- **Approach:** add `REX`/`REX_REJECTED` next to the other resolutions with `REX_BIN` and the bundle extra candidate; add the `rexc` wrapper and `_rex_probe`; add `rex` to the `--launcher` validation list and usage text; record the announcement in `resolve_launcher` and add the `rex)` forced-probe arm, the announced arm and the ghostty guard; extend the exit-4 and exit-5 blocks with rex-specific wording (what `rex whoami` printed, the `REX_BIN` override, the searched paths).
- **Execution note:** write the resolve tests first; the precedence cases are the regression risk.
- **Test scenarios:**
  - Covers AE2. `REX_SESSION` set, REX stub live, ghostty env present: `resolve_launcher` yields `rex`, not `ghostty`.
  - `REX_SESSION` set with `HERDR_ENV=1` and a live herdr stub: yields `herdr` (precedence kept).
  - `REX_SESSION` unset, live REX stub: yields `none` or the existing result (no unannounced REX arm).
  - Covers AE4. `REX_SESSION` set, no resolvable `rex`: exit 4 and the output names `REX_BIN`.
  - `REX_SESSION` set, stub whoami exits 1: exit 5 and the output quotes the stub's stderr.
  - `REX_BIN` set to a non-executable file: rejected, no silent fallback to another `rex`.
  - A `rex` on `PATH` whose `whoami --json` is not JSON-success: treated as unresolved.
  - `--launcher rex` with a dead probe: falls back with the same warning shape as the other backends.
- **Verification:** `bash -n scripts/spinoff.sh`; the new bats cases pass; the existing resolve cases still pass unmodified.

### U2. Placement and launch for tab, split and workspace

- **Goal:** the three targets open a REX tab, split or session running the briefed Claude, named by `--label`.
- **Requirements:** R4, R5, R6 (agent side), R8 (launch failure); KTD1, KTD5, KTD6, KTD9.
- **Dependencies:** U1.
- **Files:** `scripts/spinoff.sh`; `scripts/spinoff.bats`.
- **Approach:** add `launcher_new_tab_rex`, `launcher_new_split_rex`, `launcher_new_workspace_rex` (record `REX_PLACE`, return `rex:pending`), `launcher_find_left_pane_rex` (no-op), and `launcher_launch_agent_rex` (stage nothing; run the placement's `rex` call with `-c "$WORKTREE" --keep-open --json -- sh -c "$LAUNCH_CMD"`, parse the block ID, set `SURFACE_REF`, `KICKOFF_OK`, and the session for later calls; for the workspace target also set `WORKSPACE_REF` and `LAUNCH_WS` to the new session ID, as the ghostty and herdr launches do, so the summary names it). Split passes `--split` from `$SPLIT_DIRECTION` and `--focus=false`; tab passes `--focus=false`. A missing session or a failed call sets `KICKOFF_OK=0` and prints the `rex` error.
- **Test scenarios:**
  - Covers AE1. Tab: argv contains `window new -s <session>`, the label, `-c <worktree>`, `--keep-open`, `--focus=false`, and the launch command after `--`.
  - Covers AE3. Split with `--split-direction left`: argv has `--split=left` and `-b <from-surface>`; focus is not taken.
  - Split with no `--from-surface`: existing downgrade-to-tab behaviour is reported in "NOT what was asked for".
  - Workspace: argv has `new <label>` and the worktree; the `session.select` call follows; a failing select leaves exit 0 and a visible note.
  - Empty brief file: refuses to launch, exit 3, no `rex` create call made.
  - `rex window new` fails: exit 3 and the stub's error is printed, not swallowed.
  - Session from `--from-surface` differs from `REX_SESSION`: the block's session wins for split.
  - A worktree path containing a space and a single quote: the launch command reaches `sh -c` as one intact argument (the brief itself rides a file, not argv).
- **Verification:** bats cases pass; a live run (below) opens one tab and one split in a scratch REX session.

### U3. Readiness, startup prompts and claude-gone

- **Goal:** the new session's folder-trust and MCP prompts are answered from the screen, and a Claude that died is reported as exit 3.
- **Requirements:** R7, R8; KTD7, KTD8.
- **Dependencies:** U2.
- **Files:** `scripts/spinoff.sh`; `scripts/spinoff.bats`, `scripts/kickoff-gate.test.sh`.
- **Approach:** add `launcher_wait_ready_rex` (capture, `_screen_tail`, the same case arms as herdr, `rex send-key` for answers) and `rex_claude_gone`; add one clause to the shared post-wait check so `LAUNCHER = rex` also runs the gone check. First step: run a live `rex wait` on a short-lived and a long-lived command to pin down the exit-versus-timeout signal.
- **Test scenarios:**
  - Stub capture shows the ready footer: `LB_READY=1` on the first poll.
  - Stub capture shows `new MCP servers found`: `send-key enter` is sent; with `SPINOFF_MCP_MODAL=reject` it sends `escape`; with `=abort` nothing is sent and the brief is not reported ready.
  - Stub capture shows `I trust this folder` with the cursor on "No, exit": Down then Enter is sent, never a bare Enter.
  - Capture never shows a footer: loop ends at the timeout, session reported "a dialog may still be up", exit 0.
  - Stub `wait` reports the child exited: `KICKOFF_FAIL` is set and the run exits 3.
  - A modal left in scrollback above a ready screen is not re-answered (tail-only matching).
- **Verification:** bats and `kickoff-gate.test.sh` pass.

### U4. Handoff viewer

- **Goal:** `--target workspace` shows `docs/handoff.md` in a right pane beside the agent.
- **Requirements:** R6; KTD10.
- **Dependencies:** U2.
- **Files:** `scripts/spinoff.sh`; `scripts/spinoff.bats`.
- **Approach:** add `launcher_open_viewer_rex`: `rex split -b <agent block> --split=right --focus=false -- sh -c "glow …"` (or `bat --paging=always …`); set `VIEWER_OK=1` only when the call returns a block ID; name it `$VIEWER_LABEL`; never fail the launch.
- **Test scenarios:**
  - `glow` on `PATH`: argv uses glow; `VIEWER_OK=1`.
  - Only `bat`: argv uses bat.
  - Neither: warning, `VIEWER_OK=0`, exit 0.
  - Split call fails: warning, exit 0.
- **Verification:** bats cases pass.

### U5. Drift test and stubbed suites

- **Goal:** a renamed `rex` flag fails a test, and every REX behaviour is testable without REX installed.
- **Requirements:** R9, R10; KTD4.
- **Dependencies:** lands with U1–U4.
- **Files:** `scripts/cli-drift.test.sh`, `scripts/spinoff.bats` (a `rex` stub in `setup`), `scripts/smoke.sh` (export `REX_SESSION` unset so smoke never launches).
- **Approach:** add a `rex` stub that logs argv to `REX_ARGV_LOG` and emits the JSON shapes captured in Research; extend `extract_calls` and `extract_flags` to read `rexc …` call sites; call `check_backend rex REX "${REX_BIN:-…}"` with the bundle path as a fallback; keep the existing rule that an absent CLI is reported as unverified, and make a present `rex` that lacks a used verb or flag fail.
- **Test scenarios:**
  - Covers AE5. Mutate a flag in a copy of `spinoff.sh`; the drift check exits 1.
  - `rex` absent: the REX check reports SKIPPED, other backends still run, and a run with nothing verified still exits 2.
  - The stub suite covers tab, split-left, split-right, workspace, binary-missing and server-refused with `rex` removed from `PATH`.
  - `smoke.sh` opens no REX surface when run inside a REX terminal.
- **Verification:** `bash scripts/cli-drift.test.sh` against the installed beta; bats passes with `rex` absent from `PATH`.

### U6. Docs and ghostty audit

- **Goal:** the skill documents REX and records where ghostty falls short.
- **Requirements:** R11, R12.
- **Dependencies:** names from U1–U3.
- **Files:** `SKILL.md`, `../../README.md`, `../../.claude-plugin/plugin.json` (description line).
- **Approach:** add REX to the backend list and detection order (KTD3 and the nested-in-herdr caveat); add `REX_BIN` and the bundle path to the variable table; add the `--from-surface` row (`$REX_BLOCK`) and the instruction to pass `REX_SESSION`; extend exit-4 and exit-5 rows with REX causes; record in the ghostty section that `--target split` without `--from-surface` downgrades to a tab at exit 0, and that readiness and the MCP prompt are not available there.
- **Test scenarios:** `Test expectation: none -- documentation`. A reviewer checks every flag and variable named in `SKILL.md` against `spinoff.sh`.
- **Verification:** grep that each new variable and flag in the docs exists in the script.

---

## Verification Contract

Run from `plugins/spinoff/skills/spinoff/scripts/`, each through `~/.claude/tools/honest-run/run.sh` so a run that did not finish is not read as a pass:

- `bash -n spinoff.sh`
- `bats spinoff.bats` (expect the bats summary; a skip is not a pass)
- `bash smoke.sh`, `bash kickoff-gate.test.sh`, `bash session-id-passthrough.test.sh`
- `bash cli-drift.test.sh` with `REX_BIN` set to the bundle path; expect REX "exists" lines and zero failures
- `bash ~/.claude/tools/slate-unicorn-lint/run.sh` on the changed JS/TS (none expected; shell only) and `~/.claude/tools/comment-bloat/run.sh`

Live check (the plan is not done without it): create a scratch session with `rex new`, run `spinoff.sh --launcher rex` with `REX_SESSION` and `REX_BLOCK` set from that session for each of tab, split (left and right) and workspace against a scratch repo; capture each new block and confirm Claude started in the worktree with its brief; run once with `rex` removed from `PATH` and `REX_SESSION` set and confirm exit 4; `rex kill` the scratch sessions after.

## Definition of Done

- Every R in the Product Contract has a unit and a passing test or a documented live check; AE1–AE5 each map to a test above.
- The full Verification Contract passes, including the live check, with outputs read rather than assumed.
- `herdr`, `cmux` and `ghostty` code paths are unchanged apart from the shared dispatcher arms, the `--launcher` list, the ghostty guard and the one shared post-wait clause; their tests pass unmodified.
- `SKILL.md` and the README describe REX, its detection rank, the exit codes and the ghostty limitations.
- Experimental or abandoned code from the probing is removed from the diff, and no scratch worktrees, REX sessions or Ghostty windows from testing remain.
