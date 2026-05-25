"""r13-positive fixture: os.unlink on a user agent path."""
import os
os.unlink(os.path.expanduser("~/.claude/agents/foo.md"))
