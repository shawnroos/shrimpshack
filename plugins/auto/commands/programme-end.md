---
description: End this herdr space's auto programme
argument-hint: ""
allowed-tools: Bash, CronDelete, TaskStop
---

Shawn typed this to end the programme. The prompt hook has already journaled the
request. It is accepted when typed in the driving session, or from any session
when the lease is orphaned. When the lease is expired (the agreement was never
accepted within one cadence), `end` needs no typed request and ends the programme
the way `expire` does, with reason agreement_unaccepted: there is no accepted
agreement to protect. A `--why` of several words must be in single quotes
(`--why 'nothing left to do'`): the dispatch line wraps the arguments in double quotes.

First make one carry-over offer: the corrections still applied and the
programme-layer behaviours. `end` releases the lease, and every verb refuses an
ended programme, so this comes before it.

1. Read two lists:
   - From `bash "${CLAUDE_PLUGIN_ROOT}/lib/programme.sh" status --terms --json`,
     `terms.corrections` (the corrections still applied). While corrections are
     switched off this list is always empty.
   - From `bash "${CLAUDE_PLUGIN_ROOT}/lib/programme.sh" status --json`,
     `contract.behaviours`, keeping only the rows with `layer` "programme" and
     `state` "active". These are the behaviours that end with this programme
     unless Shawn keeps them.
2. Both lists empty: go straight to the dispatch line.
3. Otherwise, show both in one message. Each correction gets one line (its id,
   the kind of choice, who decides it now, and Shawn's quote). Each behaviour
   gets one line (its id, its "when", its do and don't lines, and Shawn's
   quote). Ask which to keep for the next programme, and for each behaviour
   whether it goes to the repo (every programme on this repo) or global (every
   project). Then wait for his typed reply.
4. When he names corrections to keep, run
   `bash "${CLAUDE_PLUGIN_ROOT}/lib/programme.sh" keep-corrections --prompt <id> <correction-id>...`,
   citing his reply's prompt id. Keep none when he says none.
   - It refuses with "corrections are not on yet": tell him so in one line and
     go on.
   - It refuses because this session does not drive the programme (an
     orphaned lease): tell him in one line that corrections can be kept only
     from the driving session, and go on.
5. When he names behaviours to keep, run one `keep-behaviours` call per layer
   he named, citing his reply's prompt id:
   `bash "${CLAUDE_PLUGIN_ROOT}/lib/programme.sh" keep-behaviours <behaviour-id>... --to repo|personal --prompt <id>`.
   "Global" or "all projects" is `--to personal`. When the remit holds several
   repos, add `--repo <key>` for the repo he named. His reply must name each
   behaviour id and the layer; the verb leaves out ids it does not name and
   lists them as `not_named`, so tell him which ones were not kept. Keep none
   when he says none.
   - On a refusal (an unreadable behaviours store, a negated layer, an
     orphaned lease), tell him the reason in one line and go on.

Run the dispatch line below:

`bash "${CLAUDE_PLUGIN_ROOT}/lib/programme.sh" end "$ARGUMENTS"`

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
     --why <text> --run <run>`; for an uncertain action, ask Shawn and cite his
     typed answer with `dispose-action`. A disposition records how work stopped;
     it never marks a requirement as passed.
  5. When every check passes, run `archive --run <run>`. The archive is sealed
     and read-only. If it refuses, show Shawn the failed check and stop.
  6. Tell Shawn in one line whether the programme is archived or which check
     still fails. For more work after an archive, `create-successor <run>`
     starts a new programme linked to it; its agreement waits for his acceptance.
