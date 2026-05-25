#!/usr/bin/env bash
# r13-negative fixture: a literal-string comment mentioning the patterns. Allowed.
# example: do not rm ~/.claude/commands/foo.md from production code
# example: avoid unlink "$HOME/.claude/agents/zombie.md"
echo "plugin code only mentions the path in comments"
