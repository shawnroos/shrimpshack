---
allowed-tools: Bash
---

# /mode:setup

Initialize claude-modes V2 in this Claude Code environment. Captures
your current settings as a forensic pristine, generates `_global.yaml`
from your `enabledPlugins`, moves user-authored commands and agents
into a managed staging directory and symlinks them back, seeds example
modes (discovery + delivery), and creates the install registry.

First-run only — re-running on an existing install refuses unless a
crashed setup left a `.setup.in-progress` sentinel (in which case it
resumes idempotently).

bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh"
