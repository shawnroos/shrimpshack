---
description: Take over this herdr space's auto programme from this session when its PM is gone, or replace a named PM
argument-hint: "[--replace <PM session id>]"
allowed-tools: Bash, Skill, Monitor, CronCreate, CronDelete, TaskStop, AskUserQuestion
---

Shawn typed this in the session that should become the PM. The prompt hook has
already journaled the request. A takeover works at once when herdr shows the
old PM is gone: the pane that ran it is closed, or now runs another session or
terminal. It also works when the lease is orphaned (the PM stopped beating for
two cadence periods) and the request was typed while it was. Otherwise it needs
Shawn to name the PM he is replacing: `/auto:programme-takeover --replace <PM
session id>` (a pane name also works inside the PM's own herdr workspace). The
session id works from any workspace or machine, because herdr pane and tab ids
differ per workspace and per machine. The old PM's next programme write is then
refused. If herdr cannot
be read, auto does not count the PM as gone. Pass `--replace` on the dispatch
line only when Shawn typed it; the typed text, not the argument, is what counts.

Shawn does not have to type the command. Whenever he asks this session,
in any words, to be the PM, to replace the PM or to take over as PM,
run `programme.sh become-pm` first and follow the one step it prints:

- `start`: no programme holds this space; run `/auto:programme`.
- `already-pm`: this session drives it; run the sweep.
- `takeover`: the PM stopped (lease orphaned, or herdr shows it gone). Run
  `programme.sh takeover --prompt <id>`, citing the prompt id auto journaled
  for Shawn's ask in this session. No picker. The takeover is journaled as
  unrequested.
- `ask-shawn`: the PM is live. Offer its `label` as the recommended option of one
  AskUserQuestion picker, with a decline option that keeps the current PM. When
  Shawn picks the label, run `programme.sh takeover --prompt <pick id>`. When he
  declines, stop.
- `stand-down`: another session now drives the programme this session drove.
  Cancel this session's programme cron (CronDelete) and Monitor (TaskStop)
  wake-ups and stop. Do not message Shawn.
- `refused`: run its `fix:` line.

A takeover refusal prints a `fix:` line; run it.

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
  in full with `programme.sh recover --get <id>`. The PM works from this
  session's own folder; it never needs to move. Then:
  1. If `programme.sh status --json` has a `setup` part, the agreement is not
     accepted yet: resume `/auto:programme` step 5 at the first step not done,
     and finish the setup before you arm any wake-up.
  2. Re-arm the remit watcher under Monitor, and every watcher for the waits it
     listed (`programme-watch.sh --item <id> -- <command>`). Record each Monitor
     with `watcher-beat <watcher id> --task-id <Monitor task id> --kind monitor`.
  3. CronCreate the cadence fallback again and record it with
     `watcher-beat cron --task-id <id> --kind cron --prompt "<exact cron text>"` (the text is
     in `/auto:programme` step 8).
  4. If the context lists an uncertain action, run `reconcile-operations` before
     any retry.
  5. Load the `auto:programme-sweep` skill and run a sweep.
