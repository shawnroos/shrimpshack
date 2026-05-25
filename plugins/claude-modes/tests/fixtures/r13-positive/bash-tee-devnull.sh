#!/usr/bin/env bash
# r13-positive fixture: tee /dev/null truncation.
tee "$HOME/.claude/commands/foo.md" < /dev/null
