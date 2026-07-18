---
description: "Harvest rendered components from a running dev server and write them into the target Paper file"
argument-hint: "[--repo <path>] [component names] (optional — defaults to the config harvest batch)"
---

# Refresh components in Paper

Harvest the rendered structure and computed styles of a target codebase's components from a running dev server, map computed values back to that codebase's design-token references (`var(--…)`), and write them into the configured Paper file — replacing any prior representation rather than duplicating it.

Which components to harvest, the selectors and routes, the live theme signal, and the target Paper `fileId` all come from the codebase's `token-bridge.config.json`, found via `--repo <path>`. Requires a logged-in dev server session and a non-empty `fileId` in that config.

Use the Skill tool to invoke: `refresh-components`
