---
allowed-tools: Bash
---

Show the active mode for the current branch, the cascade tiers in effect,
the compiled plugin catalog, and the user-catalog inventory.

Reports:

- The active mode (or "Claude Mode" if no per-branch pointer is set).
- Which cascade tiers are visible right now: tier 1 (~/.claude/settings.json),
  tier 2 (~/.claude/modes/_global.yaml), tier 3 (active mode YAML), and
  tier 4 (<repo>/.claude/modes/_repo.yaml when in a repo). Each line is
  marked "contributed" or "inactive".
- The compiled `enabledPlugins` from `<repo>/.claude/settings.local.json`
  (when in a repo and a cascade compile has already run).
- User-catalog inventory: count of plugin-owned symlinks under
  ~/.claude/commands/ and ~/.claude/agents/.
- Paths to the compiled settings file and the cascade-meta sidecar.

Drift detection between the live `settings.local.json` and the sidecar
fingerprint is deferred to V2.1 per R23 — `/mode:status` surfaces a
single-line reminder of this rather than performing the check.

To dispatch, run:

`bash ${CLAUDE_PLUGIN_ROOT}/lib/status.sh`
