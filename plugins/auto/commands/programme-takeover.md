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
  rules in force and the restored context it printed (`<auto-context>`: the
  decisions with their reasons and limits, requirements, binding pauses and
  denials, pending questions, assignments and uncertain actions, at one store
  revision). They bind you from now on; they approve nothing. Read any cut entry
  in full with `programme.sh recover --get <id>`. Then:
  1. Re-arm the remit watcher under Monitor, and every watcher for the waits it
     listed (`programme-watch.sh --item <id> -- <command>`). Record each Monitor
     with `watcher-beat <watcher id> --task-id <Monitor task id> --kind monitor`.
  2. CronCreate the cadence fallback again and record it with
     `watcher-beat cron --task-id <id> --kind cron --prompt "<exact cron text>"` (the text is
     in `/auto:programme` step 8).
  3. If the context lists an uncertain action, run `reconcile-operations` before
     any retry.
  4. Load the `auto:programme-sweep` skill and run a sweep.
