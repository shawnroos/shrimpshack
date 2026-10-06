---
title: "A skill that calls MCP tools must load them with ToolSearch first"
date: 2026-10-06
category: architecture-patterns
module: plugins/work
problem_type: architecture_pattern
component: tooling
severity: high
applies_when:
  - a skill or command tells the agent to call MCP tools by name
  - an MCP server is registered but its tools are deferred, with schemas not loaded
  - a flow registers an MCP server with claude mcp add and then wants to use it in the same session
tags:
  - claude-code
  - mcp
  - toolsearch
  - deferred-tools
  - allowed-tools
  - skill-authoring
---

# A skill that calls MCP tools must load them with ToolSearch first

## Context

The `/work setup` flow in the `work` plugin binds a herdr space and a worktree through the board MCP server (`mcp__board__open_board`, `mcp__board__close_board`, `mcp__board__bind`, `mcp__board__state`). The first draft of the setup skill told the agent to use those tools. It also said to take a "new session" path if "the tools are not available here", but gave no way to tell.

A code review of the branch flagged this as a warning from its agent-native reviewer. Two facts made the gap real:

- In Claude Code, MCP tools are often **deferred**. The session lists their names, but their schemas load only when ToolSearch selects them. Calling a deferred tool before that fails. An agent that sees no loaded `mcp__board__*` schema can decide the tools do not exist when they only need loading.
- The setup preflight checked the server with `claude mcp get board` (`plugins/work/bin/setup-check.sh:278-280`). That reports `ok` for any registered server, including one that `claude mcp add` registered earlier in the same session. Claude Code loads a server only in sessions started after it was added, so `ok` did not mean "callable now".

The fix is on the `feature/work-setup` branch of shrimpshack, PR pending as of this writing.

## Guidance

When a skill or slash command tells the agent to call MCP tools, do three things.

1. **Load the tools before the first call.** Name the exact tools in a ToolSearch `select:` query at the start of the step that uses them. `plugins/work/skills/setup/SKILL.md:135-137` (step 6) and `:180-182` (step 7) both say:

   > First load the board tools, which can be registered but not yet loaded: call ToolSearch with the query `select:mcp__board__open_board,mcp__board__close_board,mcp__board__bind,mcp__board__state`.

2. **List ToolSearch and the MCP tools in `allowed-tools`.** `plugins/work/commands/work.md:4` now includes `ToolSearch` and each `mcp__board__*` tool the skill calls, so the load and the calls run without a permission prompt.

3. **Treat "still not resolvable after ToolSearch" as "not available in this session", and give a fallback.** The skill does not guess. If the tools still do not resolve, it tells the person to start a new Claude Code session in the same herdr pane and run `/work setup` again, which skips everything already `ok` (`SKILL.md:138-140` for `open_board`/`close_board`, `SKILL.md:183-185` for `bind`). `SKILL.md:89-92` states the cause: a server added in this session does not load until a new session.

Keep the preflight honest about what it proves. `setup-check.sh:279-280` reports `ok` with the detail "board mcp is registered with Claude Code" — registration only. The callability check is the ToolSearch load in the skill, not the shell probe.

## Why This Matters

- **A false "missing" sends the person on a detour.** Without the load step, the agent sees no schema for a deferred tool, concludes the server is absent, and tells the person to start over in a new session or re-register a server that works.
- **A false "ok" breaks the step partway.** `claude mcp get` passing says nothing about this session. The agent goes into the binding step and fails on its first call, which is harder to recover from than a clear "start a new session" message at the start.
- **A missing `allowed-tools` entry causes prompts in a hands-off flow.** The flow then stops on a permission question the person did not expect.

## When to Apply

- Any skill, slash command, or agent prompt that calls an MCP tool by name, mainly tools from a third-party or plugin-installed server.
- Any flow that registers an MCP server (`claude mcp add`) and then wants to use it. The same session cannot use it; plan the "new session, rerun" handoff.
- Any preflight or doctor script that checks an MCP server from the shell. Word its result as "registered", and do the callability check inside the session.

Not needed for built-in tools (Bash, Read, Edit), which are always loaded.

## Examples

Before (step 6 of the setup skill, first draft): the step used `open_board` directly. A rule in step 2 said to take the new-session path "if the `open_board` and `bind` tools are not available here", with no way to detect that. `plugins/work/commands/work.md` did not list `ToolSearch`.

After:

```markdown
## 6. Bind the space to a project

Skip this step when `space_binding` is `ok`.

First load the board tools, which can be registered but not yet loaded: call
ToolSearch with the query
`select:mcp__board__open_board,mcp__board__close_board,mcp__board__bind,mcp__board__state`.
If `open_board` and `close_board` still do not resolve, take the new-session path: tell the person to
start a new Claude Code session in this herdr pane and run `/work setup` again
(it skips everything already `ok`), and go to step 8.
```

```yaml
# plugins/work/commands/work.md frontmatter
allowed-tools: Bash, Read, Skill, AskUserQuestion, ToolSearch, mcp__board__open_board, mcp__board__close_board, mcp__board__bind, mcp__board__state, mcp__claude_ai_Linear__get_issue, mcp__linear__get_issue
```

```python
# plugins/work/bin/setup-check.sh:278-280 — proves registration, not callability
rc, _ = run([claude, "mcp", "get", "board"], NETWORK_TIMEOUT)
if rc == 0:
    out["board_mcp"] = entry("ok", "board mcp is registered with Claude Code.")
```

A reusable pattern for any skill step that calls MCP tools:

```markdown
First load <tools>: call ToolSearch with `select:<tool1>,<tool2>`.
If <tool1> still does not resolve, it is not available in this session:
tell the person to start a new session and run <command> again. Do not
call it.
```
