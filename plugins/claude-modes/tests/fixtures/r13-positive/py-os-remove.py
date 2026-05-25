"""r13-positive fixture: os.remove on a user command path."""
import os
os.remove(os.path.expanduser("~/.claude/commands/foo.md"))
