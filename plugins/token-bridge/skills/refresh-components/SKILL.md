---
name: refresh-components
description: >
  Harvest rendered WCS components from a running dev server and write them into a Paper file.
  Use when someone asks to refresh WCS components in Paper, harvest a component into the design
  file, or update the Paper component mockups from code. Needs a logged-in dev server and a
  target Paper fileId in wcs-paper.config.json.
allowed-tools: Bash, Read
---

# Refresh WCS components in Paper

Harvest rendered WCS components from a running dev server, map their computed values back to `--wcs-*` token refs, and write them into the configured Paper file — replacing any prior copy rather than duplicating it.

## Prerequisites

- **Paper desktop is running** (its daemon at `http://127.0.0.1:29979/mcp`) and the target file's `fileId` is set in `wcs-paper.config.json`. The script refuses if it is empty.
- **A web-app dev server is up** and a **logged-in `agent-browser --profile` session** exists — the WCS editor needs auth + a loaded project before any `app-*` component renders. Without this the harvest returns `server_unreachable` / `component_not_found` per component.

## Workflow

1. Confirm the prerequisites above (dev server reachable, browser profile logged in, Paper open on the target file).

2. Run the harvest-and-write script for the configured batch (defaults to the typography components — the first batch, which carries the type scale that has no token representation):

   ```bash
   python3 "${CLAUDE_PLUGIN_ROOT}/lib/write_component.py"
   ```

   To refresh only specific components (e.g. after changing one component's code), pass `--name <component>` one or more times: `--name typography-heading --name typography-body`. Omit it to refresh the whole batch.

3. Relay the JSON report: `componentsWritten` / `componentsReplaced` and any `nearMisses` (values that matched a token only in the other theme, or couldn't be mapped). Re-running replaces each component's prior representation in place — the sequence is find → delete → write against a stable layer name — so the Paper node count does not grow.

Failure exits to surface verbatim rather than guessing around:

- `error: "no_target_file"` — `wcs-paper.config.json` has no `fileId`; set it and retry.
- `error: "no_target_node"` — could not resolve a Paper node to write under; open the target file in Paper and pass `--target-node-id <artboardId>` (or set `$WCS_PAPER_TARGET_NODE_ID`).
