---
allowed-tools: AskUserQuestion, Bash, Read, Task
argument-hint: <what to change about the active mode>
---

# /mode:edit

Open a conversation with the **mode agent** to reshape the active mode —
add or drop plugins/skills/agents, or just ask what the active mode
currently enables and why. Use this when you'd rather describe what you
want in natural language than name an exact identifier; for a one-shot
mechanical edit, `/mode:add <x>` and `/mode:drop <x>` are faster.

This command dispatches the **`mode` agent** (shipped by this plugin at
`agents/mode.md`). Per the plugin's Phase 0 verification, plugin-shipped
agents resolve by their namespaced subagent type — dispatch
`subagent_type: claude-modes:mode` (the bare `mode` form does not resolve
at the harness level).

To run: dispatch the mode agent with the user's edit intent as the
prompt. If `/mode:edit` was invoked with no further description, ask the
user what they want to change about the active mode, then dispatch the
agent with their answer.

The agent has its own context window (so the editing conversation doesn't
clutter the main session), reads the active mode via
`lib/active-mode.sh`, walks the user through accept/reject via
`AskUserQuestion`, and persists atomically through the same
`lib/mode-add.sh` / `lib/mode-drop.sh` orchestrators the slash commands
use. It will redirect you to `/mode:suggester` if you actually want to
switch modes, and to `mode-author` if you want to create a new one.

`@mode` is the conversational shorthand for the same agent — say
"@mode add figma" or "@mode, what's enabled here?" and the agent is
dispatched with that intent.
