---
name: status
description: >
  Show where a codebase's tokens and its connected Paper file disagree, in both
  directions, without writing anything — then offer to normalize. Use when someone asks
  for the sync status, whether code and design are in sync, what's drifted, or which way
  to reconcile. Reads the connection from the codebase's token-bridge.config.json (via --repo).
allowed-tools: Bash, Read
---

# Sync status

The script computes the drift read-only; your job is to run it, present the drift plainly, and then offer the two normalize directions — never apply automatically.

## Workflow

1. Run the status script:

   ```bash
   python3 "${CLAUDE_PLUGIN_ROOT}/lib/status.py" run --repo /path/to/codebase
   ```

2. Read the exit code and JSON report:
   - **Exit 2 (refused):** no config / no `fileId` under `--repo` (`error` is `no_config` / `no_target_file` / `bad_config`). Tell the user to run `connect` first, and surface `note`.
   - **Exit 4 (error):** the source read or the Paper daemon failed. Relay it.
   - **Exit 0 (ok):** report the drift from the fields below.

3. Present the drift plainly (nothing was written):
   - **`inSync`** — when true, code and design already agree; say so and stop.
   - **`onlyInCode`** — tokens the code defines that the Paper file lacks.
   - **`onlyInDesign`** — tokens the Paper file has that the code lacks (within the configured prefix).
   - **`differ`** — tokens both carry with different values (a genuine conflict to resolve deliberately).
   - **`declined`** — source tokens Paper can't represent (shadows, motion), for context.

4. Then offer the two directions (this is the "which way?" decision — do not pick for the user):
   - To make the **design match the code** (code wins): run **`normalize-to-code`**.
   - To make the **code match the design** (design wins): run **`normalize-to-design`**.

   If the user chooses one, invoke that skill with the same `--repo`. Point out that `differ` tokens are where the two directions actually disagree — the choice matters most there.
