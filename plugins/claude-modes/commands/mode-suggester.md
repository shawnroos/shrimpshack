---
allowed-tools: AskUserQuestion, Bash, Read
---

# /mode:mode-suggester

Propose a switch to a different mode when the current work doesn't fit the
active mode. Use when:

- The active mode's constraints explicitly ask the agent to surface a
  mode-switch (the mode's prose layer says so).
- The work being asked for is plainly outside the active mode's scope
  (e.g. design mode is active but the user is asking for debugging).
- You want to see the list of available modes with a "switch to" picker
  rather than running `/mode:registry` then `/mode:set` separately.

The skill at `.claude/skills/mode-suggester/SKILL.md` does the work —
it reads available modes from `~/.claude/modes/*.yaml`, resolves the
currently active mode via `lib/active-mode.sh`, presents 2-4 candidates
via `AskUserQuestion`, and runs `bash lib/set-mode.sh <name>` on accept.

To dispatch, just say "suggest a mode" or "should I switch modes?" — the
harness will load the skill. This command file is the discoverable entry
point; the skill is the actual flow.
