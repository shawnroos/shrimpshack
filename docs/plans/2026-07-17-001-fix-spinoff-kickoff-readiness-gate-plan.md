---
title: "fix: spinoff sends the kickoff without waiting for readiness (herdr path)"
created: 2026-07-17
type: fix
artifact_readiness: diagnosis-complete
artifact_contract: none — this is a defect report + proposed fix, right-sized. Not a
  ce-unified-plan/v1; run /ce-plan against it if you want the full treatment.
origin: live failure during a /start-session spinoff, 2026-07-17
affects: plugins/spinoff 0.8.2 — herdr path confirmed, cmux path same shape (unverified)
execution: code
---

# fix: spinoff sends the kickoff without waiting for readiness

## Symptom

A `/start-session` spinoff does everything right — correct worktree, correct branch, correct tab,
Claude launched — and then leaves the kickoff message **staged in the input box, unsubmitted**. The
new session sits idle and unbriefed. The script exits **0** and prints a `✓ Spinoff complete` block.

The only signal is one line inside that success block:

```
herdr tab:  w1:pE — new Claude session launched (readiness not confirmed — check the surface)
```

## What actually happened

Live, 2026-07-17, spinoff 0.8.2, herdr backend, spinning off `minions` → `feature/job-record`:

- Script exited 0 with the summary above. Worktree, branch, handoff, and doc carry-over were all
  correct.
- `herdr agent list` → that pane: `{"pane_id":"w1:pE", ..., "agent_status":"idle"}`.
- `herdr agent read w1:pE --source visible` → the kickoff text
  (`Read docs/handoff.md — it's the brief for this worktree…`) sitting on the `❯` input line,
  never submitted. The same pane shows `⚠ 1 MCP server needs authentication · run /mcp`.

So: Claude booted slowly (MCP servers), the Enter went nowhere, and the run reported success.

## Root cause

Two facts combine. Neither is a bug alone.

**1. The readiness wait has a 30s ceiling.** `launcher_wait_ready_herdr()` (`spinoff.sh:376`) blocks
on `herdr agent wait <pane> --status idle --timeout 30000` and sets `LB_READY=0` on timeout. A Claude
loading MCP servers routinely exceeds 30s — the MCP-auth warning in the pane corroborates the slow
boot in this run.

**2. The send never checks `LB_READY`.** `launcher_send_kickoff_herdr()` (`spinoff.sh:391`) stages the
text and fires Enter **unconditionally**, then reads `LB_READY` only at `:403` to pick which *message*
to print:

```sh
"$HERDR" agent send "$HERDR_PANE" "$KICKOFF" >/dev/null 2>&1     # stage literal text
"$HERDR" pane send-keys "$HERDR_PANE" Enter >/dev/null 2>&1      # single submit
sleep 2
# … retry one Enter if still staged …
if [ "$LB_READY" = "1" ]; then
  step "  … (Claude ready, briefed)"
else
  step "  … (Claude launched; readiness not confirmed — check the $LAUNCH_WHERE)"
fi
```

**`LB_READY` is a narration variable where it should be a control variable.** The script knows it
isn't ready, says so honestly, and sends anyway.

## Why the safety net didn't catch it

The function has a retry: `sleep 2`, re-read the pane, and if the kickoff is still staged, send one
more Enter. Both Enters land inside the *same* boot window, ~2s apart. If boot outruns `30s + 2s`,
the retry is as lost as the original. The net is sized for a UI that is up-but-busy, not one that
hasn't drawn yet.

## The part that makes it dangerous

The failure is rendered **inside a `✓ Spinoff complete` block, with exit 0.**

The spinoff skill mandates running the script from a background agent and relaying the summary — so
a failure formatted as a success line inside a success block is a failure that gets relayed to the
user as success. That's how this reached "done" today. Fixing the gate without fixing the reporting
leaves the trap intact.

## Scope

- **herdr path: confirmed.** Any spinoff where Claude's boot exceeds 30s. The timeout is a fixed
  constant and MCP loading is routine, so this is not a one-off.
- **cmux path: same shape, unverified.** `launcher_wait_ready_cmux()` (`:133`) polls
  `read-screen` 30× at `sleep 1` — also a ~30s ceiling — and `launcher_send_kickoff_cmux()` (`:147`)
  reads `LB_READY` only at `:159`, again for the message. Structurally identical. Its glyph-match
  readiness signal may be more forgiving in practice, but I did not test it. Fix both; verify both.

## Proposed fix

1. **Gate the send on readiness.** If `LB_READY=0`, do not fire. Prefer: keep waiting against a much
   larger overall deadline, and only past a hard ceiling skip the send and report loudly.
2. **Raise the ceiling.** 30s is too tight. `herdr agent wait` is a real blocking primitive that
   returns the instant the agent is idle, so a large timeout (≈180s) costs nothing on a fast boot —
   there is no reason to pay for the wait you don't use. Prefer a bigger ceiling over a bigger sleep.
3. **Make the retry readiness-aware.** Re-wait before the retry Enter instead of a fixed `sleep 2`.
4. **Stop reporting an unbriefed session as complete.** If the kickoff can't be confirmed submitted,
   exit non-zero, or at minimum print the failure *outside* the `✓ Spinoff complete` block with the
   exact one-liner to brief the tab by hand. This is the one that turns a silent trap into a visible
   failure — arguably worth doing first.

Preserve the documented **"EXACTLY ONE submit (KTD-4 / R7)"** invariant: `agent send` stages, one
Enter submits. The fix is about *when* to send, not *how many times*.

## How to verify

- **Deliberate fail first.** Force `LB_READY=0` (set the timeout to `1`) and assert the script does
  **not** submit and does **not** print `✓ Spinoff complete`. Watch it fail before the fix, so the
  test is known to bite.
- **The real case.** Spin off into a repo with MCP servers configured (a slow boot). Assert
  `herdr agent read` shows the kickoff submitted — not sitting on the `❯` line — and the agent moves
  to `working`.
- **Regression.** A fast-boot spinoff still briefs with exactly one submit: no double-send, no
  duplicated kickoff.
- `scripts/smoke.sh` already exists next to `spinoff.sh` — check whether this belongs there.

## What I did NOT verify

Stated plainly so nobody inherits my confidence:

- Observed **once**, live. Not reproduced a second time. The diagnosis is one failure plus a read of
  the script.
- I did not establish where the two Enters actually went — terminal buffer, or a UI that hadn't drawn.
  Only that the text ended up staged and the agent idle. The 30s-timeout-plus-unconditional-send path
  is certain from the code; "the Enters were swallowed by the boot" is the most plausible mechanism,
  not a proven one.
- The cmux path is **untested** — structural read only.
- I did not edit `spinoff.sh`, in the source or the plugin cache.

## Provenance

- Live failure spinning off the minions job-record workstream, 2026-07-17.
- Cache copy that ran: `~/.claude/plugins/cache/shrimpshack/spinoff/0.8.2/skills/spinoff/scripts/spinoff.sh`.
- Source (same 0.8.2, same bug, line numbers above):
  `plugins/spinoff/skills/spinoff/scripts/spinoff.sh`.
- **Not** the bug fixed by the existing `.claude/worktrees/spinoff-herdr-tab-fix` worktree — that
  addressed herdr workspace resolution and split→tab placement, published as 0.8.1 → 0.8.2. This is
  unfixed in source as of `41e6f1a`.
- The affected tab from this run is `w1:pE` (`minions·job-record`), left staged and awaiting one
  Enter, deliberately not hand-submitted — the spinoff skill forbids sending the kickoff by hand.
