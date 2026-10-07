---
description: Take over an orphaned auto programme in this herdr space from this session
argument-hint: ""
allowed-tools: Bash, Skill, Monitor, CronCreate, CronDelete, TaskStop
---

Shawn typed this in the session that should become the PM. The prompt hook has
already journaled the request. A takeover works only when the space's lease is
orphaned (its PM stopped beating for two cadence periods); a live programme
moves only by `/auto:programme-handover` typed in its driving session.

Run the dispatch line below:

`bash "${CLAUDE_PLUGIN_ROOT}/lib/programme.sh" takeover "$ARGUMENTS"`

- Exit 1: show Shawn the refusal line and stop. The refusal is journaled.
- Success: the lease and the driving session now name this session. Read the
  rules in force it printed; they bind you from now on. Then:
  1. Re-arm the remit watcher under Monitor, and every watcher for the waits it
     listed (`programme-watch.sh --item <id> -- <command>`).
  2. CronCreate the cadence fallback again and record it with
     `watcher-beat cron --task-id <id> --prompt "<exact cron text>"` (the text is
     in `/auto:programme` step 8).
  3. Load the `auto:programme-sweep` skill and run a sweep.
