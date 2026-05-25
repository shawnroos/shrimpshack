"""r13-negative fixture: os.remove on a plugin-owned tmp file in modes/. Allowed."""
import os
tmp_path = os.path.expanduser("~/.claude/modes/.cascade-meta.json.tmp.abc123")
os.remove(tmp_path)
