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
  1. Run each `CronDelete <id>` line it prints.
  2. Run each `TaskStop <id>` line it prints, then stop any other watcher
     Monitor this session still runs.
  3. Tell Shawn in one line that the programme ended and the space is free.
