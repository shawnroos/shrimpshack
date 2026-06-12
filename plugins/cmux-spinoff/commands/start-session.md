---
description: Spin the current topic/plan/idea off into a fresh worktree + a briefed Claude session in a new tab on the current cmux workspace
---

The current topic, plan, or idea we've been discussing is becoming its own batch of work. Spin it off into its own parallel workstream — a new **tab** on the current cmux workspace.

Invoke the **cmux-spinoff** skill and follow it end to end with `--target tab`:
1. Synthesize the handoff (goal, why-now, key decisions, open questions, starting point) from everything we've discussed in this session.
2. Confirm the branch base with me (recommend branching off the current HEAD to carry context; offer develop for a clean-room start). Ask this here — it can't be asked once the work is backgrounded.
3. Resolve this session's transcript + cwd so the resume link is correct, then **dispatch a background agent** to run the spinoff script (`--target tab`). The background agent does the mechanical work — worktree, handoff finalization, doc carry-over, opening the new tab, launching + briefing Claude — so it doesn't fill this session's context.
4. Relay the agent's summary: branch, worktree path, the new cmux tab, and the session link.

Anything I typed after the command is the workstream name/hint — use it to pick the kebab-case feature name and focus the handoff: $ARGUMENTS
