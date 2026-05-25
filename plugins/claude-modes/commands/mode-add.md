---
allowed-tools: AskUserQuestion, Bash, Read
argument-hint: <plugin-or-skill>
---

# /mode:add

Add a plugin, skill, or agent to the **active mode's** catalog, in-flow —
no leaving your work to hand-edit YAML. The change persists to the active
mode's tier-3 YAML and a reload prompt is printed.

The orchestrator lives at `lib/mode-add.sh`. It resolves the active mode,
resolves the argument string to one or more candidates, applies the delta
atomically (via `lib/apply-delta.sh`, which enforces R22), and prints the
`/reload-plugins` prompt (via `lib/post-write-reload.sh`). It is
deterministic and non-interactive; disambiguation is delegated back to you
(this command) through the exit-code contract below.

## Dispatch

`bash ${CLAUDE_PLUGIN_ROOT}/lib/mode-add.sh "$ARGUMENTS"`

## Interpreting the result (exit-code contract)

- **exit 0** — applied. The YAML is written and the reload prompt printed
  to stderr. Relay the reload prompt to the user.
- **exit 2** — no argument supplied. Tell the user the usage:
  `/mode:add <plugin-or-skill>`.
- **exit 1** — orchestrator failure (no active mode, zero candidates,
  drift detected, R22 refusal, or writer failure). The stderr message
  explains which. Relay it; for "no active mode" point the user at
  `/mode:set <name>` first.
- **exit 10** — **ambiguous: more than one candidate matched.** stdout
  carries a `__SNAPSHOT__=<hash>` line followed by the candidate TSV rows
  (`kind=… id=… source=… installed=…`). Do this:
  1. Pre-load the question tool: call `ToolSearch` with query
     `select:AskUserQuestion` once (it is a deferred tool).
  2. Present the candidates via `AskUserQuestion` so the user picks one.
  3. Re-invoke the orchestrator with the chosen **fully-qualified id**
     AND the snapshot value, so the drift-check can confirm the mode
     YAML hasn't changed while the user was deciding:
     `bash ${CLAUDE_PLUGIN_ROOT}/lib/mode-add.sh "<chosen-fqn>" "<snapshot>"`
  4. Interpret that second invocation's exit code by the same rules. A
     re-invocation that returns exit 1 with a drift message means the
     mode changed during the choice — tell the user to retry.

Do not silently pick a candidate on exit 10. The user chooses.
