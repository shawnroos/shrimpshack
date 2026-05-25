#!/usr/bin/env bash
# r13-positive fixture: find -delete inside user commands tree.
find "$HOME/.claude/commands" -type f -name '*.md' -delete
