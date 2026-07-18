---
description: "Sync a codebase's CSS custom-property design tokens into the target Paper file (idempotent reconcile)"
argument-hint: "--repo <path> (reads source, prefix, theme conventions, and target fileId from the codebase's token-bridge.config.json)"
---

# Sync tokens to Paper

Read a codebase's CSS design tokens and reconcile them into the configured Paper file: create new tokens, update changed values, delete tokens no longer in source, and recreate any whose Paper type changed. Values Paper cannot represent (shadows, motion) are reported, never written.

The source path, token prefix, theme conventions, and target Paper `fileId` all come from the target codebase's `token-bridge.config.json` (found via `--repo`). The source is read from the working tree by default, or from a git ref when the config's `source.ref` is set. The command refuses to run if no `fileId` is set. Re-running with an unchanged source produces no writes.

Use the Skill tool to invoke: `sync-tokens`
