---
description: End this space's auto programme
argument-hint: ""
allowed-tools: Bash, CronDelete, TaskStop, AskUserQuestion
---

Shawn typed this, or asked in any words, to end the programme. A typed
`/auto:programme-end` is journaled by the prompt hook and accepted in the driving
session, or from any session when the lease is orphaned. Otherwise the driving
session asks him with the end picker (below).
When the lease is expired (the agreement was never
accepted within one cadence), `end` needs no request and ends the programme
the way `expire` does, with reason agreement_unaccepted: there is no accepted
agreement to protect. A `--why` of several words must be in single quotes
(`--why 'nothing left to do'`): the dispatch line wraps the arguments in double quotes.

First make one carry-over offer: the active Rulings and the programme-layer
behaviours. `end` releases the lease, so the offer comes before it.

1. Run `bash "${CLAUDE_PLUGIN_ROOT}/lib/programme.sh" carry-rulings`. It lists
   each active Ruling and each active programme-layer behaviour on a
   `carry-over offer:` line, and records that the offer was made. If it refuses
   because this session does not drive the programme (an orphaned lease), tell
   Shawn in one line that Rulings and behaviours can be kept only from the
   driving session, and go straight to the dispatch line.
2. No `carry-over offer:` lines: go straight to the dispatch line.
3. Otherwise, show Shawn those lines in one message.
   - Rulings: ask which to carry to the next programme on this project. Run
     `programme.sh offer carry --command 'carry-rulings <ruling-id>...'` with
     up to 3 commands, one for each set you recommend, and ask with the input
     it prints.
   - Behaviours: ask which to keep and whether each goes to the repo (every
     programme on this repo) or global (every project). Run
     `programme.sh offer keep --command 'keep-behaviours <behaviour-id>... --to repo|personal'`
     and ask with the input it prints. If Shawn answers with a set no option
     offered, offer that set and ask again.
4. When he answers about Rulings, run
   `bash "${CLAUDE_PLUGIN_ROOT}/lib/programme.sh" carry-rulings --prompt <id> <ruling-id>...`,
   citing his answer's prompt id. Carry none when he declines.
   - Carried Rulings arrive in the next programme pending, with no items, and
     bind only when he approves them there with their items.
5. When he picks behaviours to keep, run one `keep-behaviours` call per picked
   option, citing that pick's id:
   `bash "${CLAUDE_PLUGIN_ROOT}/lib/programme.sh" keep-behaviours <behaviour-id>... --to repo|personal --prompt <pick id>`.
   "Global" or "all projects" is `--to personal`. When the remit holds several
   repos, add `--repo <key>` for the repo he named, in the label too. The verb
   leaves out ids the label does not name and lists them as `not_named`, so tell
   him which ones were not kept. Keep none when he picks "Keep none".
   - On a refusal (an unreadable behaviours store, a negated layer, an
     orphaned lease), tell him the reason in one line and go on.

If Shawn typed the command, run the dispatch line below:

`bash "${CLAUDE_PLUGIN_ROOT}/lib/programme.sh" end "$ARGUMENTS"`

If he did not, run `programme.sh offer end-programme --command 'end'` (add `--why` or
`--without-rituals` to the command if they apply), ask with the `input` it prints,
unchanged, and run nothing on "Not now". On his pick run the same command with
`--prompt <pick id>`. His own words never approve it: relay them and ask again with the
same picker.

- Exit 1: show Shawn the refusal line and stop. The refusal is journaled.
- Exit 2: the arguments did not parse (for example, an unquoted `--why` of
  several words). Show Shawn the line and ask him to quote the reason.
- Success: the leases are released and the run shows "ended" (apart from done).
  Ended is not archived: no new work starts, and the home keeps everything.
  1. Run each `CronDelete <task id>` line it prints, then record it with
     `release-resources --run <run> --watcher <watcher id> --stopped` (or
     `--denied` if the tool refused). Pass the watcher id the line names, not
     the task id; an id the programme does not owe is refused.
  2. Run each `TaskStop <task id>` line it prints, record it the same way, then
     stop any other watcher Monitor this session still runs.
  3. If the programme recorded a programme worktree (`pm_worktree`, made by an
     older auto) and this session is inside it, leave it first, because
     release refuses to remove the worktree while the caller is inside it:
     `cd` to its main checkout (the worktree path without
     `/worktrees/programme-<run>`), or have Shawn type `/cd <main checkout>`.
     Then run `release-resources --run <run>`. It removes leftover lease files and
     checks watcher processes and worker sessions without stopping anything.
  4. Run `check-archive --run <run>`. Each failed check names its remedy: for
     an unfinished item, `dispose-item <id> --as stopped_unfinished|handed_over
     --why <text> --run <run>`; for an uncertain action, run
     `offer dispose --command 'dispose-action ...'`, ask Shawn with the input it
     prints, and cite the pick with `dispose-action --prompt <pick id>`. A disposition records how work stopped;
     it never marks a requirement as passed.
  5. When every check passes, run `archive --run <run>`. The archive is sealed
     and read-only. If it refuses, show Shawn the failed check and stop.
  6. Tell Shawn in one line whether the programme is archived or which check
     still fails. For more work after an archive, `create-successor <run>`
     starts a new programme linked to it; its agreement waits for his acceptance.
