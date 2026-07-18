---
description: "Sync WCS --wcs-* design tokens from the merged develop SCSS into the target Paper file (idempotent reconcile)"
argument-hint: "(no args — reads source from origin/develop and target from wcs-paper.config.json)"
---

# Sync WCS tokens to Paper

Read the WCS design tokens from the merged `develop` ref and reconcile them into the configured Paper file: create new tokens, update changed values, delete tokens no longer in source, and recreate any whose Paper type changed. Values Paper cannot represent (shadows, motion) are reported, never written.

The target Paper file comes from `wcs-paper.config.json`; the command refuses to run if no `fileId` is set. Re-running with an unchanged source produces no writes.

Use the Skill tool to invoke: `sync-tokens`
