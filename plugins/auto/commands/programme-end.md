---
description: End this herdr space's auto programme
argument-hint: ""
allowed-tools: Bash, CronDelete, TaskStop
---

Shawn typed this to end the programme. The prompt hook has already journaled the
request. It is accepted when typed in the driving session, or from any session
when the lease is orphaned.

Run the dispatch line below:

`bash "${CLAUDE_PLUGIN_ROOT}/lib/programme.sh" end "$ARGUMENTS"`

- Exit 1: show Shawn the refusal line and stop. The refusal is journaled.
- Success: the leases are released and the run shows "ended" (apart from done).
  Ended is not archived: no new work starts, and the home keeps everything.
  1. Run each `CronDelete <id>` line it prints, then record it with
     `release-resources --run <run> --watcher <id> --stopped` (or `--denied`
     if the tool refused).
  2. Run each `TaskStop <id>` line it prints, record it the same way, then stop
     any other watcher Monitor this session still runs.
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
