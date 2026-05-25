#!/usr/bin/env bash
# r13-negative fixture: rm of a plugin-owned tmp file. Allowed.
rm "$HOME/.claude/modes/.live-settings.json.tmp.XXXXXX"
