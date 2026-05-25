---
allowed-tools: AskUserQuestion, Bash, Read
argument-hint: <plugin-or-skill>
---

# /mode:drop

Remove (disable) a plugin, skill, or agent from the **active mode's**
catalog, in-flow. For a plugin this is a cascade-subtraction — the
identifier is added to the mode's `disable.enabledPlugins` so it's
subtracted from the cascade total, not deleted from a positive list. For
a user-catalog skill/agent the basename is removed from the list.

The orchestrator lives at `lib/mode-drop.sh` (a thin delegate to the
shared edit machinery in `lib/mode-add.sh`). Same resolve → drift-check →
apply → reload flow, same exit-code language as `/mode:add`.

## Dispatch

`bash ${CLAUDE_PLUGIN_ROOT}/lib/mode-drop.sh "$ARGUMENTS"`

## Interpreting the result (exit-code contract)

- **exit 0** — dropped (includes the idempotent "already dropped" no-op;
  the YAML is unchanged in that case). Relay the reload prompt.
- **exit 2** — no argument. Usage: `/mode:drop <plugin-or-skill>`.
- **exit 1** — failure. The headline drop-specific case: **dropping
  `claude-modes` itself is refused (R22)** — claude-modes must remain
  enabled in every mode. Relay the R22 message and suggest a different
  target, or `/mode:registry` to see what's already disabled.
- **exit 10** — ambiguous (N candidates). Identical protocol to
  `/mode:add`: pre-load `AskUserQuestion` (deferred tool), present the
  candidate rows from stdout, then re-invoke with the chosen
  fully-qualified id AND the `__SNAPSHOT__` value:
  `bash ${CLAUDE_PLUGIN_ROOT}/lib/mode-drop.sh "<chosen-fqn>" "<snapshot>"`

Do not silently pick a candidate on exit 10.
