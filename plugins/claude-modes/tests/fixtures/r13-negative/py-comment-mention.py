"""r13-negative fixture: only comments and docstrings reference the destructive
shapes; no actual call site executes against ~/.claude/commands/. Allowed."""

# do not call os.remove(...) on ~/.claude/commands/foo.md
# do not call shutil.rmtree("/Users/u/.claude/agents") either
print("plugin only mentions the patterns in docstrings/comments")
