---
description: "Normalize the design to the code — fix the Paper file's tokens to match the codebase (code is source of truth; idempotent reconcile)"
argument-hint: "--repo <path> (reads source, prefix, theme conventions, and target fileId from the codebase's token-bridge.config.json)"
---

# Normalize the design to the code

Code is the source of truth. Read the codebase's CSS design tokens and reconcile them into the connected Paper file: create new tokens, update changed values, and recreate any whose Paper type changed (scoped to the configured prefix). It does NOT delete: a live token absent from the source is reported as `prunable` and left in place, because a gap in the parse looks identical to a deletion. Pass `--prune` to actually remove them. Values Paper cannot represent (shadows, motion) are reported, never written.

The source path, token prefix, theme conventions, and target Paper `fileId` all come from the target codebase's `token-bridge.config.json` (found via `--repo`, written by `connect`). The source is read from the working tree by default, or from a git ref when the config's `source.ref` is set. The command refuses to run if no `fileId` is set. Re-running with an unchanged source produces no writes.

Use the Skill tool to invoke: `normalize-to-code`
