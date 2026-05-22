---
argument-hint: install | uninstall | status
allowed-tools: Bash
---

Manage the claude-modes statusline integration with the user's existing
Claude Code statusline script.

The plugin ships an ambient mode-visibility segment (`🔧 example-delivery`)
that composes into the user's existing statusline at the right edge.
Because Claude Code has a single user-level statusline slot, the plugin
cannot own that slot directly — it ships a snippet that the user's
statusline script chains into, via a marker-wrapped block + a tiny
edit to the final `printf`.

This command lets the agent perform the wiring/unwiring on the user's
behalf, so the user never has to touch the statusline script directly.

Subcommands:

- `install` (default with no args): inserts the snippet block and
  augments the final printf. Idempotent — re-running is a no-op if
  already installed. Creates a timestamped backup before mutation.
- `uninstall`: removes the snippet block and reverses the printf
  augmentation. Idempotent. Creates a timestamped backup.
- `status`: reports whether the snippet is currently installed in the
  user's configured statusline script, and where the script lives.

To dispatch, run:

`bash ${CLAUDE_PLUGIN_ROOT}/lib/statusline-dispatcher.sh "$ARGUMENTS"`
