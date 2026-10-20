---
description: Take over this herdr space's auto programme from this session when its PM is gone, or replace a named PM
argument-hint: "[--replace <PM pane name>]"
allowed-tools: Bash, Skill, Monitor, CronCreate, CronDelete, TaskStop
---

Shawn typed this in the session that should become the PM. The prompt hook has
already journaled the request. A takeover works at once when herdr shows the
old PM is gone: the pane that ran it is closed, or now runs another session or
terminal. It also works when the lease is orphaned (the PM stopped beating for
two cadence periods) and the request was typed while it was. Otherwise it needs
Shawn to name the PM he is replacing: `/auto:programme-takeover --replace <PM
pane name>`. The old PM's next programme write is then refused. If herdr cannot
be read, auto does not count the PM as gone. Pass `--replace` on the dispatch
line only when Shawn typed it; the typed text, not the argument, is what counts.

Run the dispatch line below:

`bash "${CLAUDE_PLUGIN_ROOT}/lib/programme.sh" takeover "$ARGUMENTS"`

- Exit 1: show Shawn the refusal line as it is and stop. When the old PM is still
  running, the line names its pane and gives the exact text to type to replace
  it. The refusal is journaled.
- Success: the first line says which PM it took over from and why. The lease and the driving session now name this session. Read the
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
