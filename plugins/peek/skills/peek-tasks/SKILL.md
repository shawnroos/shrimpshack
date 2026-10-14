---
name: peek-tasks
description: Keep the person's small tasks and your own work in peek, where both of you can see what is open, what is next and what each agent is doing. Use whenever the person mentions something to do ("task:", "remind me to", "we should also", "after this, fix…"), when you plan your own multi-step work, when you need to move, adopt or finish a task, when you group tasks by a rule, or when you write a peek view definition.
allowed-tools: ToolSearch, mcp__peek__list_tasks, mcp__peek__read_task, mcp__peek__save_task, mcp__peek__move_tasks, mcp__peek__check_view, mcp__peek__list_groups, mcp__peek__read_group, mcp__peek__save_group
---

# Peek tasks

Peek keeps every piece of work too small or too non-code for a Linear ticket.
A task is a markdown doc with props (name, id, status, creator, and optionally
parent, sequence, due and attachments). The person's list lives in the repo's
`.peek/tasks/` folder, or in a user-level list outside any repo. Peek also
mirrors every agent session's own task list, so the person sees what each
agent is doing.

## 1. Load the tools

Call ToolSearch with the query
`select:mcp__peek__list_tasks,mcp__peek__read_task,mcp__peek__save_task,mcp__peek__move_tasks,mcp__peek__check_view`.
If the tools do not resolve, peek is not loaded in this session. Tell the person
to check that the peek mod is on (`/plugin`) and start a new session.

## 2. Save a task whenever the person mentions one

When the person names something to do, save it first and confirm after. Do not
ask whether to save it.

1. If the task sits before or after another one, or belongs under one, call
   `list_tasks` to find that task's id.
2. Call `save_task` with `name`, `on_behalf: "person"`, and any `sequence`
   (`{ "after": "<id>" }`), `parent`, `due` (`YYYY-MM-DD`) or `attachments` the
   person gave.
3. Tell the person in one line what you saved.

Example: "task: fix the crumb hover, after the Esc work" becomes
`save_task { name: "Fix the crumb hover", on_behalf: "person", sequence: { after: "<id of the Esc task>" } }`.

Peek records the creator itself. `on_behalf: "person"` makes the person the
creator; `on_behalf: "self"` makes this session the creator. Never pass a
creator; peek ignores it.

## 3. Keep your own work in a task list

For work with more than one step, keep your plan in your session's task list
(TaskCreate and TaskUpdate). Peek mirrors that list into a group for the
person, folds it when every item is done, and archives it later. Keep each
item's status current as you work. To split your list into sections, give your
items a prop and group by it (`save_group` with `split`).

If a piece of your work should outlive this session, save it with
`save_task { on_behalf: "self" }` instead.

## 4. Which tool to use

| Tool | Use it when |
|---|---|
| `list_tasks` | You need a task's id, or want to see what is open. Filter by `status`, `creator` (`person`, `self` or a session id) or `list`. |
| `read_task` | You need one task in full: every prop, its body, and any required prop it is missing. |
| `save_task` | You capture a task (no `id`), or change one: its status, name, sequence, parent, due date, attachments or description. A mirrored task changes only its status. |
| `move_tasks` | A task or an agent list belongs somewhere else. `to` is `mine` (this repo's list), `user` (the user-level list) or a folder in another repo. Moving a mirrored item adopts it: it becomes a task doc that keeps its id and creator. |
| `save_group` with `rule` | The person wants a group that fills itself, such as every task he created (`creator=shawn`) or one agent list (`list=<session>#1`). Add `split: "status"` to section it by status. |
| `check_view` | You write or change a view definition for `~/.local/share/claude-peek/views/`. Pass the text before you save it; fix every problem it reports. |

## 5. Status

A task's status is `todo`, `doing`, `done` or `cancelled`. Set `doing` when you
start a task and `done` when you finish it. Every status change is logged; when
two changes collide, the latest one wins.
