# Moving to work 0.6.0

Work 0.6.0 stops keeping its own store. The herdr board keeps the bindings in its own database, agents write Linear through Linear's MCP tools, and the plugin's hook tells the board about each write.

Follow these steps in order. Doing them out of order can lose a binding.

## Before you start

- Install a herdr-board release that has `board linear report` and `board import work-store`. Check it:

  ```bash
  board linear report --help >/dev/null 2>&1; echo $?
  ```

  `0` means the board is new enough. `64` means it is too old, so stop here.
- In a herdr pane, run `board linear space list`. If it refuses your herdr version, the board's Linear view will not open until the board accepts that version. The hooks and `bind` still work without it.

## Steps

1. Stop the old daemon, so the new binary starts a new one:

   ```bash
   board daemon stop
   ```

2. Register the board's MCP server for every Claude Code session:

   ```bash
   claude mcp add --scope user board -- board mcp
   ```

3. Preview the import, create the first marker, then import:

   ```bash
   board import work-store --dry-run
   touch "$HOME/.work-cutover-M0"
   board import work-store
   ```

4. Update the plugin: run `/plugin update work` in Claude Code.

5. End every Claude session that started before the update. That includes:
   - board-dispatched agent panes;
   - sessions in other herdr sessions;
   - sessions in plain terminals;
   - the desktop app.

   An old session keeps the old hooks until it ends, and ending it still runs the old SessionEnd hook, which writes the old store. Wait until the last one has closed.

6. Create the second marker, then import again. Save the output for step 8:

   ```bash
   touch "$HOME/.work-cutover-M1"
   board import work-store | tee "$HOME/.work-cutover-import-2.txt"
   ```

7. Check that nothing wrote the store after the second marker:

   ```bash
   cd ~/.claude/work
   find board.json bindings workspaces contexts scopes -newer "$HOME/.work-cutover-M1" -type f 2>/dev/null
   ```

   It should print nothing. A newer file under `board/` or in `shadow.log` means an old session is still running: end it, then repeat steps 6 and 7.

8. Find edits that the second import could not carry. The import only adds rows the board does not hold, so a change an old session made between the two imports to a binding the board already held is skipped. List the candidates:

   ```bash
   cd ~/.claude/work
   find bindings workspaces -newer "$HOME/.work-cutover-M0" -type f 2>/dev/null
   grep -E 'already in the board|already bound' "$HOME/.work-cutover-import-2.txt"
   ```

   For each binding that appears in both lists, bind it again by hand, either in the board TUI or by asking an agent to call the `board mcp` `bind` tool with that worktree as `cwd`.

9. Unbind bindings whose worktree no longer exists. When this guide was written they were AI-308, AI-416, WEB-3465 and WEB-3472. Unbind each from the board TUI, or ask an agent to call `unbind` with the old path as `cwd`.

   Do this only after the last import. `unbind` removes the board's row, and an import puts back any old-store binding the board does not hold.

10. Optional:
    - Remove `HERDR_LINEAR_SLATE_ROOT` from your settings and set `HERDR_LINEAR_PROJECTS_ROOT` instead.
    - Check whether Linear's GitHub integration moves your issues when a pull request merges. The plugin no longer does it.

## What changes

| Before | Now |
|---|---|
| `/work:new`, `/work:new-sub-issue`, `/work:new-project` | Ask the agent. It creates the issue through Linear's MCP and follows the `linear-rules` skill. |
| `/work:describe`, `/work:doc` | Ask the agent. It writes through Linear's MCP, using the headings in `docs/linear-conventions.md`. |
| `/work:bind` | The agent calls `board mcp` `bind`, or the board links the worktree when an agent saves an issue from it. Bind a space to a project in the board TUI. |
| `/work:declare` | Bind the space to a project in the board TUI. Session-team declarations are not used any more. |
| `/work:board` | Nothing yet. The grouping stays as the first import set it until the board can edit it. |
| The issue moved to Done when its PR merged | The agent moves it through Linear's MCP when you ask, or Linear's GitHub integration does it. |
| Notices for pending consent, pending placement, and misplaced or stale bindings | Gone. The board does not compute misplaced or stale yet. |
| `/work` | Shows the board binding and checks that the board can hear this session's writes. |

Nothing writes `~/.claude/work` any more. `start` still reads its `scopes/` once, to find a repository you already chose for a team.
