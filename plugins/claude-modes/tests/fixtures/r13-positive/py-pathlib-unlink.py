"""r13-positive fixture: pathlib.Path(...).unlink() on a user command."""
import pathlib
pathlib.Path("/Users/example/.claude/commands/foo.md").unlink()
