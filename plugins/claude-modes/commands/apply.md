---
allowed-tools: Bash
---

Re-apply the current branch's active mode. Useful when
`settings.local.json` has drifted from the cascade's expected output
(manual edit, partial write, restore from backup), or when you want to
force a refresh after editing the active mode YAML.

Idempotent: if the cascade output is already correct,
`settings.local.json` is rewritten byte-identical and the symlink
topology is verified unchanged. If no mode is active (Claude Mode),
applies the no-tier-3 cascade — equivalent to re-running `/mode:clear`
without removing the per-branch state.

Run `/reload-plugins` after to pick up any changes.

Usage: `/mode:apply`

`bash ${CLAUDE_PLUGIN_ROOT}/lib/apply-mode.sh`
