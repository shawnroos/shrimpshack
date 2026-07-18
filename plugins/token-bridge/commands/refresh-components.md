---
description: "Harvest rendered WCS components from a running dev server and write them into the target Paper file"
argument-hint: "[component names] (optional — defaults to the harvest_batch.json set)"
---

# Refresh WCS components in Paper

Harvest the rendered structure and computed styles of WCS components from a running web-app dev server, map computed values back to `--wcs-*` token references, and write them into the configured Paper file — replacing any prior representation rather than duplicating it.

Requires a logged-in dev server session and a `fileId` in `wcs-paper.config.json`. The first batch is the uikit typography components, which carry the type scale that has no token representation.

Use the Skill tool to invoke: `refresh-components`
