---
description: Spin the current topic/plan/idea off into a fresh worktree + a briefed Claude session in a split beside this pane
---

The current topic, plan, or idea we've been discussing is becoming its own batch of work. Spin it off into a **split beside the pane I'm in**, in this same tab — herdr, cmux or ghostty, whichever this session is running in.

Invoke the **spinoff** skill and follow it end to end with `--target split`. The skill owns the workflow — synthesize the handoff, confirm the branch base (here, before backgrounding), resolve this session's transcript, dispatch a background agent to run the spinoff script, and relay the result.

One extra thing this target needs: resolve the **originating pane** here, in this session, and pass it as `--from-surface`. The background agent that runs the script doesn't inherit it, and without it the script opens a tab instead of a split. On herdr pass `$HERDR_PANE_ID`, on cmux pass `$CMUX_SURFACE_ID`, and on ghostty pass `$(tty)` — not `$GHOSTTY_SURFACE_ID`, which matches nothing.

If none of those is set, this session is not running inside a pane of any of them, so there is no originating pane to split. Say that plainly and run `--target tab` instead — do not invent an id from `herdr pane list` or `cmux tree`, which would split some other pane the user is not sitting in.

The split goes to the right by default. If I said "left" below, pass `--split-direction left`.

Anything I typed after the command is the workstream name/hint (plus an optional "left") — use it to pick the kebab-case feature name and focus the handoff: $ARGUMENTS
