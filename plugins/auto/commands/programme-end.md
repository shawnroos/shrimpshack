---
description: End this herdr space's auto programme
argument-hint: ""
allowed-tools: Bash, CronDelete, TaskStop
---

Shawn typed this to end the programme. The prompt hook has already journaled the
request. It is accepted when typed in the driving session, or from any session
when the lease is orphaned.

First offer to carry Rulings. `end` releases the lease, so the offer comes
before it.

1. Run `bash "${CLAUDE_PLUGIN_ROOT}/lib/programme.sh" carry-rulings`. It lists
   each active Ruling on a `carry-over offer:` line and records that the offer
   was made. If it refuses because this session does not drive the programme
   (an orphaned lease), tell Shawn in one line that Rulings can be carried only
   from the driving session, and go straight to the dispatch line.
2. No `carry-over offer:` lines: go straight to the dispatch line.
3. Otherwise, show Shawn those lines and ask which Rulings to carry to the next
   programme on this project. Then wait for his typed reply.
4. When he names Rulings to carry, run
   `bash "${CLAUDE_PLUGIN_ROOT}/lib/programme.sh" carry-rulings --prompt <id> <ruling-id>...`,
   citing his reply's prompt id. Carry none when he says none.
   - Carried Rulings arrive in the next programme pending, with no items, and
     bind only when his typed prompt there names the items.

Run the dispatch line below:

`bash "${CLAUDE_PLUGIN_ROOT}/lib/programme.sh" end "$ARGUMENTS"`

- Exit 1: show Shawn the refusal line and stop. The refusal is journaled.
- Success: the leases are released and the run shows "ended" (apart from done).
  Ended is not archived: no new work starts, and the home keeps everything.
  1. Run each `CronDelete <task id>` line it prints, then record it with
     `release-resources --run <run> --watcher <watcher id> --stopped` (or
     `--denied` if the tool refused). Pass the watcher id the line names, not
     the task id; an id the programme does not owe is refused.
  2. Run each `TaskStop <task id>` line it prints, record it the same way, then
     stop any other watcher Monitor this session still runs.
  3. Run `release-resources --run <run>`. It removes leftover lease files and
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
