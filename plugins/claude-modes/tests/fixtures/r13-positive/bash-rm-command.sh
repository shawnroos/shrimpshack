#!/usr/bin/env bash
# r13-positive fixture: bare rm of a user command. MUST be caught by the lint.
rm "$HOME/.claude/commands/foo.md"
