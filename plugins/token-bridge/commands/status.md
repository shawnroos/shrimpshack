---
description: "Show where a codebase's tokens and its Paper file disagree, in both directions (read-only), then offer to normalize"
argument-hint: "--repo <path> (reads the connection from the codebase's token-bridge.config.json)"
---

# Sync status — where code and design stand

Report the drift between a codebase's CSS tokens and its connected Paper file in both directions, writing nothing: tokens only in the code, tokens only in the design, and tokens both carry with different values. Then decide which way to reconcile — `normalize-to-code` to make the design match the code, or `normalize-to-design` to make the code match the design.

Reads the connection from the codebase's `token-bridge.config.json` (found via `--repo`).

Use the Skill tool to invoke: `status`
