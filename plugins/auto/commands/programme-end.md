---
description: End this herdr space's auto programme
argument-hint: ""
allowed-tools: Bash, CronDelete, TaskStop
---

Shawn typed this to end the programme. The prompt hook has already journaled the
request. It is accepted when typed in the driving session, or from any session
when the lease is orphaned.

First offer to keep corrections. `end` releases the lease, and every verb
refuses an ended programme, so this comes before it.

1. Run `bash "${CLAUDE_PLUGIN_ROOT}/lib/programme.sh" status --terms --json`
   and read its `terms.corrections` list (the corrections still applied). While
   corrections are switched off this list is always empty.
2. Empty list: go straight to the dispatch line.
3. Otherwise, list each correction in one line (its id, the kind of choice,
   who decides it now, and Shawn's quote), and ask which ones to keep for the
   next programme on this project. Then wait for his typed reply.
4. When he names corrections to keep, run
   `bash "${CLAUDE_PLUGIN_ROOT}/lib/programme.sh" keep-corrections --prompt <id> <correction-id>...`,
   citing his reply's prompt id. Keep none when he says none.
   - It refuses with "corrections are not on yet": tell him so in one line and
     go on.
   - It refuses because this session does not drive the programme (an
     orphaned lease): tell him in one line that corrections can be kept only
     from the driving session, and go on.

Run the dispatch line below:

`bash "${CLAUDE_PLUGIN_ROOT}/lib/programme.sh" end "$ARGUMENTS"`

- Exit 1: show Shawn the refusal line and stop. The refusal is journaled.
- Success: the leases are released and the run shows "ended" (apart from done).
  1. Run each `CronDelete <id>` line it prints.
  2. Run each `TaskStop <id>` line it prints, then stop any other watcher
     Monitor this session still runs.
  3. Tell Shawn in one line that the programme ended and the space is free.
