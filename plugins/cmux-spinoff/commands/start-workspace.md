---
description: Spin the current topic/plan/idea off into a fresh worktree + a brand-new two-pane cmux workspace (briefed Claude + handoff viewer)
---

The current topic, plan, or idea we've been discussing is becoming its own batch of work. Spin it off into a **brand-new cmux workspace** — briefed Claude on the left, the handoff rendered in a live-reload markdown viewer on the right.

Invoke the **cmux-spinoff** skill and follow it end to end with `--target workspace`:
1. Synthesize the handoff (goal, why-now, key decisions, open questions, starting point) from everything we've discussed in this session.
2. Confirm the branch base with me (recommend branching off the current HEAD to carry context; offer develop for a clean-room start). Ask this here — it can't be asked once the work is backgrounded.
3. Resolve this session's transcript + cwd so the resume link is correct, then **dispatch a background agent** to run the spinoff script (`--target workspace`). The background agent does the mechanical work — worktree, handoff finalization, doc carry-over, creating the new workspace, launching + briefing Claude, and opening the handoff viewer alongside — so it doesn't fill this session's context.
4. Relay the agent's summary: branch, worktree path, the new workspace + agent surface, and the session link.

Anything I typed after the command is the workstream name/hint — use it to pick the kebab-case feature name and focus the handoff: $ARGUMENTS
