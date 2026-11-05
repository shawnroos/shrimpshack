---
name: programme-remit
description: >
  Work out an auto programme's remit: the spaces, the git repos and the
  issue-tracker scope (teams, projects, initiatives) the PM looks after. Use at
  /auto:programme start, and whenever Shawn asks to change the remit ("only the
  Cue jobs project", "add repo ai-chat-backend").
---

# Work out the remit

The remit says what the PM looks after. It has three parts:

- **spaces**: the spaces. `start` already holds the lease for the first one.
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
- **After acceptance**, ask him with one picker. Run
  `P offer remit --command 'set-remit' < remit.json`, ask with the `input` it
  prints, and run `P set-remit --prompt <his answer's id> < remit.json` with the
  same JSON. The picker shows only what changes, so he names nothing. Adding
  anything widens the remit and takes a pick: if he answers in his own words,
  relay them and ask again. A change that only removes also takes his own words:
  add `--reads-as '<the option's text>'` and show him the `read_back` line.
- **Workers you start yourself need no picker.** `P start-worker` records
  the worker's repo in the remit's `worker_repos`, apart from the declared
  `repos`, and `P close-gone-pane` removes it when it closes the worker's
  pane. Start workers with `start-worker`, not by running spinoff yourself; a
  direct run adds nothing and leaves the declared list as it is. A start's output names what
  it recorded (`remit_added`) or why it recorded nothing (`remit_reason`).
  Worker repos widen the sweep only: authority, rulings, PR checks and
  `set-remit` read the declared repos alone, so a worker in a repo that no declared
  entry names cannot confirm a merge until Shawn adds that repo by picker. Nothing a
  worker says or does adds to the remit. A takeover or handover keeps
  `worker_repos`, because the remit moves with the programme.
- **A repo whose folder is gone never blocks `set-remit`.** The verb drops it
  and says so (`dropped_stale`) with no approval, unless that
  would empty the list: an empty list means no limit, so it is kept.

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
