#!/usr/bin/env bash
# r13-negative fixture: rm of a non-user-catalog path (plugins/, hooks/, etc.). Allowed.
rm "$HOME/.claude/plugins/some-plugin/cache.json"
rm "$HOME/.claude/hooks/stale.json"
