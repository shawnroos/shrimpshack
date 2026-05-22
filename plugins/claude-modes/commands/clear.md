---
allowed-tools: Bash
---

Return to the no-modes-active state ("Claude Mode") for the current
branch. Removes the per-branch mode pointer and re-runs the cascade with
no tier-3 contribution — `<repo>/.claude/settings.local.json` reflects
tiers 1+2+4 only. The user-catalog symlink rebuild runs with an empty
manifest, restoring the day-zero topology (all `.user-catalog/` files
linked back).

Tier-4 `_repo.yaml` (if present + trusted) is intentionally NOT
subtracted by `/mode:clear` — it represents "always-on while in this
repo regardless of mode."

Run `/reload-plugins` after to deactivate the previous mode's plugin set.

Usage: `/mode:clear`

`bash ${CLAUDE_PLUGIN_ROOT}/lib/set-mode.sh --clear`
