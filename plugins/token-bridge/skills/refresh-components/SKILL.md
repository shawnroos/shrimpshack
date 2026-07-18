---
name: refresh-components
description: >
  Harvest rendered components from a target codebase's running dev server and write them
  into its Paper file. Use when someone asks to refresh components in Paper, harvest a
  component into the design file, or update the Paper component mockups from code. Needs a
  logged-in dev server and a target Paper fileId in the codebase's token-bridge.config.json
  (found via --repo).
allowed-tools: Bash, Read
---

# Refresh components in Paper

Harvest rendered components from a target codebase's running dev server, map their computed values back to that codebase's design-token refs (`var(--…)`), and write them into the configured Paper file — replacing any prior copy rather than duplicating it.

Everything codebase-specific — the harvest batch (which components, their selectors and routes), the live theme signal, and the target Paper `fileId` — comes from `<repo>/token-bridge.config.json`, loaded via `--repo <path>`.

## Prerequisites

- **Paper desktop is running** (its daemon at `http://127.0.0.1:29979/mcp`) and the target file's `fileId` is set in `<repo>/token-bridge.config.json`. The script refuses if it is empty.
- **The target codebase's dev server is up** and a **logged-in `agent-browser --profile` session** exists — an app that needs auth + a loaded project won't render its components otherwise. Without this the harvest returns `server_unreachable` / `component_not_found` per component.

## Workflow

1. Confirm the prerequisites above (dev server reachable, browser profile logged in, Paper open on the target file).

2. Run the harvest-and-write script, pointing it at the target codebase:

   ```bash
   python3 "${CLAUDE_PLUGIN_ROOT}/lib/write_component.py" --repo /path/to/codebase
   ```

   To refresh only specific components (e.g. after changing one component's code), pass `--name <component>` one or more times: `--name typography-heading --name typography-body`. Omit it to refresh the whole batch from config.

3. Relay the JSON report: `componentsWritten` / `componentsReplaced` and any `nearMisses` (values that matched a token only in the other theme, or couldn't be mapped). Re-running replaces each component's prior representation in place — the sequence is find → delete → write against a stable layer name — so the Paper node count does not grow.

Failure exits to surface verbatim rather than guessing around:

- `error: "no_config"` — no `token-bridge.config.json` under `--repo`; point `--repo` at the codebase root that carries it.
- `error: "no_target_file"` — the config has no `fileId`; set it and retry.
- `error: "no_target_node"` — could not resolve a Paper node to write under; open the target file in Paper and pass `--target-node-id <artboardId>` (or set `$TB_TARGET_NODE_ID`).
