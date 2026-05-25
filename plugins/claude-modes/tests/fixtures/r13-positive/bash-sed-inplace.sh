#!/usr/bin/env bash
# r13-positive fixture: sed -i in-place edit of a user command.
sed -i '' 's/foo/bar/' "$HOME/.claude/commands/foo.md"
