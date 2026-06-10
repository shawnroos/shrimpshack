---
description: Spin the current topic/plan/idea off into a fresh worktree + a new briefed Claude session in a new cmux tab
---

The current topic, plan, or idea we've been discussing is becoming its own batch of work. Spin it off into its own parallel workstream.

Invoke the **cmux-spinoff** skill and follow it end to end:
1. Synthesize the handoff (goal, why-now, key decisions, open questions, starting point) from everything we've discussed in this session.
2. Confirm the branch base with me (recommend branching off the current HEAD to carry context; offer develop for a clean-room start).
3. Run the spinoff script to create the worktree, finalize the handoff with a link back to this session's transcript, carry over recent plan/brainstorm docs, open a new tab on the left-hand agent surface of the current cmux workspace, and launch a Claude session there already briefed on the handoff.
4. Report back the branch, worktree path, the new cmux tab, and the session link.

Anything I typed after the command is the workstream name/hint — use it to pick the kebab-case feature name and focus the handoff: $ARGUMENTS
