---
description: Alias for /start-session — spin the current work off into a new tab on the current cmux workspace
---

`/start` is a back-compat alias for **`/start-session`**. Treat this invocation exactly as `/start-session`: spin the current topic/plan/idea off into a fresh worktree + a briefed Claude session in a new tab on the current cmux workspace.

Invoke the **cmux-spinoff** skill and follow it end to end with `--target tab`:
1. Synthesize the handoff (goal, why-now, key decisions, open questions, starting point) from everything we've discussed in this session.
2. Confirm the branch base with me (recommend branching off the current HEAD; offer develop for a clean-room start). Ask this here — it can't be asked once the work is backgrounded.
3. Resolve this session's transcript + cwd, then **dispatch a background agent** to run the spinoff script (`--target tab`) so the mechanical work doesn't fill this session's context.
4. Relay the agent's summary: branch, worktree path, the new cmux tab, and the session link.

Anything I typed after the command is the workstream name/hint — use it to pick the kebab-case feature name and focus the handoff: $ARGUMENTS
