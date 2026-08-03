---
description: Spin the current topic/plan/idea off into a fresh worktree + a brand-new two-pane workspace (briefed Claude + handoff viewer)
---

The current topic, plan, or idea we've been discussing is becoming its own batch of work. Spin it off into a **brand-new workspace** — briefed Claude on the left, the handoff rendered on the right. (On cmux that's the live-reload markdown viewer; herdr and ghostty use a pager instead, and ghostty's "workspace" is a new window.)

Invoke the **spinoff** skill and follow it end to end with `--target workspace`. The skill owns the workflow — synthesize the handoff, confirm the branch base (here, before backgrounding), resolve this session's transcript, dispatch a background agent to run the spinoff script, and relay the result.

Anything I typed after the command is the workstream name/hint — use it to pick the kebab-case feature name and focus the handoff: $ARGUMENTS
