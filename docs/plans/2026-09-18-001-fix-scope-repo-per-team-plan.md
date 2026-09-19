# A project's repository is decided per team, not once for the project

Date: 2026-09-18 · Plugin: `work` · Branch: `feature/work-scope-repo-per-team` (on `feature/work-bind-handoff`)

## Problem

A Linear project can span several repositories, one per team. "AI Editor: keep
both people in frame" is one of them: the work lands in more than one repo, and
which one has to be settled before a worktree is made.

Today the first answer decides the project forever, and silently:

- `lib/start.sh:336` records the answer under **both** the project key and the
  team key (`record_scope_repo "$answer" "$key" "$team_key"`).
- `lib/repos.sh:131` (`_scope_answering_key`) answers from the **first key that
  holds anything**, and `lib/start.sh:342` passes the project key first.

So after one WEB issue is answered with `web-app`:

| Issue | Team | What happens now | What should happen |
|---|---|---|---|
| WEB-1 | Web | asks, records, makes the worktree in `web-app` | same |
| AND-2 | Android | project record holds exactly one repo, so **no question** — the worktree is made in `web-app` | asks, records for Android, makes it in `android` |

A worktree in the wrong repository is expensive to unwind, and nothing in the
run says a choice was skipped. Recording a second repository against the project
does not fix it either: the project record then holds two, so **every** issue in
the project asks again, for ever, including the ones already settled.

## What the fix has to do

1. An issue whose team is known resolves against **its team's** record. The
   project record is the fallback for an issue with no team.
2. An answer for an issue with a team is recorded **for that team only**. The
   project record keeps its meaning: the repository for issues the project has
   no team for.
3. Asking happens before anything is made — already true, and it stays true.
4. A wrong answer is removable without hand-deleting a file in the store.

## Changes

### 1. Resolution order (`lib/start.sh`)

`scope_repos` / `no_repo_reason` are called with the team key first and the
project key second, so a team that has an answer never consults the project.
The project key stays in the list, so an issue with no team still resolves.

Nothing in `lib/repos.sh` changes for this: `_scope_answering_key` already
returns the first key holding anything, and both callers pass the same order.

### 2. Recording (`lib/start.sh`, `lib/repos.sh`)

`record_scope_repo "$answer" "$team_key"` when the issue has a team, else
`record_scope_repo "$answer" "$key"`. The function itself is unchanged; it
already writes every key it is given.

A scope record still holds a list, because a team genuinely can own two repos.
Several recorded for the resolving scope remains a question, which is right:
that is the case where the plugin cannot know.

### 3. A verb for forgetting (`skills/start/SKILL.md`, `lib/repos.sh`)

`SKILL.md` says today: *"A wrong answer is undone by deleting the scope's record
file … There is no verb for that yet."* Add `herdr_linear::forget_scope_repo
<key> [repo]` — one repository, or the whole record when no repository is given
— and say in the skill how to reach it. Deleting a record is local only and
touches nothing in Linear.

### 4. Migration

An existing project record written by the old rule holds an answer that may
belong to one team. Leave it: it is the fallback, and the first issue of a team
with no team record asks once and settles that team. No store migration, no
version bump of the record format.

## Tests (bats, `tests/unit/`)

Each one must be seen failing before the change.

1. Two teams, one project: answering `web-app` for a WEB issue leaves an AND
   issue in the same project still asking, and the AND answer does not reach the
   project record.
2. An issue with no team resolves from the project record.
3. A team with two recorded repositories asks and names both.
4. `forget_scope_repo` with a repository drops that one; without one drops the
   record; a missing record is not an error.
5. The old project record keeps working as the fallback for an issue whose team
   has no record yet.

## Out of scope

- The board's bind handoff: it hands `/work:bind` an existing worktree, so it
  never chooses a repository. Unchanged.
- Any mapping of repository to team held in Linear rather than in the store.
- Showing a card's repository on the board.

## Done when

Two teams in one project each make worktrees in their own repository, the second
team is asked exactly once, no answer silently decides another team's issue, and
a wrong answer can be forgotten with a verb.
