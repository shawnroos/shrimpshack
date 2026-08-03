---
description: Alias for /start-session — spin the current work off into a new tab here
---

`/start` is a back-compat alias for **`/start-session`**. Treat this invocation exactly as `/start-session`: invoke the **spinoff** skill end to end with `--target tab`. The skill owns the workflow (synthesize the handoff, confirm the branch base, dispatch a background agent to run the spinoff script, relay the result).

Anything I typed after the command is the workstream name/hint — use it to pick the kebab-case feature name and focus the handoff: $ARGUMENTS
