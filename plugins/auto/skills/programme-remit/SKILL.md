---
name: programme-remit
description: >
  Work out an auto programme's remit: the herdr spaces, the git repos and the
  issue-tracker scope (teams, projects, initiatives) the PM looks after. Use at
  /auto:programme start, and whenever Shawn asks to change the remit ("only the
  Cue jobs project", "add repo ai-chat-backend").
---

# Work out the remit

The remit says what the PM looks after. It has three parts:

- **spaces**: the herdr spaces. `start` already holds the lease for the first one.
- **repos**: the git repos, each as an absolute top-level path plus its GitHub
  `owner/name` when the origin is GitHub.
- **tracker**: the issue-tracker scope: `teams` (issue key prefixes such as
  `AI`), `projects` and `initiatives` (each as a name and an id).

You work the remit out with your own tools. Code only stores it and enforces it.
`P` below means `bash "${CLAUDE_PLUGIN_ROOT}/lib/programme.sh"`.

## Find it

1. **Spaces and panes.** `P sweep` lists the space's panes with their cwd,
   branch, title and the issues they name.
2. **Repos.** For each worker pane's cwd, run `git -C <cwd> rev-parse --show-toplevel`.
   For the GitHub name, run `gh repo view --json nameWithOwner -q .nameWithOwner`
   in that repo. Leave `github` null when the origin is not GitHub.
3. **Tracker scope.** For the issues the panes name, read each with
   `mcp__linear__get_issue`. Note its team key, project and initiatives. Use
   `mcp__linear__list_teams`, `list_projects` or `list_initiatives` to get ids
   for names Shawn gives you.
4. **Ask.** Anything you cannot tell (a pane with no repo, an issue in a team
   nobody else works in, a project you are not sure about) goes into one
   question to Shawn. Do not guess.

Keep it tight. Each part you set narrows what the PM may adopt and write. An
empty part means "no limit" for that part.

## Store it

```sh
P set-remit <<'JSON'
{"spaces": ["w2"],
 "repos": [{"path": "/Users/shawnroos/projects/ai-labs", "github": "shawnroos/ai-labs"}],
 "tracker": {"teams": [{"key": "AI", "name": "AI Labs", "id": "<team id>"}],
             "projects": [{"name": "Cue jobs", "id": "<project id>"}],
             "initiatives": []}}
JSON
```

A part you leave out keeps its value. Adding a space takes its lease, and
removing one releases it. A space another programme holds is refused.

- **At start**, before the agreement is accepted, `set-remit` needs no prompt.
  Accepting the agreement is Shawn's approval of the remit.
- **After acceptance**, it needs `--prompt <id>` of Shawn's typed message, and
  that message must name each space, repo, team, project or initiative added or
  removed. If it does not, the verb lists the missing names. Ask Shawn to
  confirm in words that name them, then cite that reply.

## Show it

Show the remit as three short lines, for example:

```
spaces: default.w2
repos: shawnroos/ai-labs, ai-chat-backend
tracker: teams AI; projects Cue jobs; initiatives none
```

Shawn changes it in plain words ("only the Cue jobs project", "add repo
ai-chat-backend"). Work out the new remit, run `set-remit` with the changed
part, and show the three lines again.

## What the remit changes

- The sweep proposes only issues inside the tracker scope, and skips a pane
  whose repo is outside the repos (`repo_out_of_remit`) or whose issues are
  outside the scope (`issue_out_of_remit`, or `project_unknown` when the
  project could not be read; record the issues through the MCP to fix that).
- In-scope issues no pane works on show as `unstaffed`. They come from the
  board's issues and from the issues you record with `P record-issues` (read
  the scope with `mcp__linear__list_issues` to fill it). They are never
  adopted by themselves; decide whether to start a worker.
- Plans are read in every remit repo.
- The merged check gives unknown for a PR outside the remit repos.
- Tracker writes stay inside the scope; a hook denies a write to an issue of a
  team outside it.
