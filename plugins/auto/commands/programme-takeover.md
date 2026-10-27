---
description: Take over this herdr space's auto programme from this session when its PM is gone, or replace a named PM
argument-hint: "[--replace <PM session id>]"
allowed-tools: Bash, Skill, Monitor, CronCreate, CronDelete, TaskStop, AskUserQuestion
---

Whenever Shawn asks this session, in any words, to be the PM, to replace the PM
or to take over as PM, run `programme.sh become-pm` first and follow the one
step it prints:

- `start`: no programme holds this space; run `/auto:programme`.
- `already-pm`: this session drives it; run the sweep.
- `ask-shawn`: another session holds the programme, live or stopped. Offer its
  `label` as the recommended option of one AskUserQuestion picker, with a
  decline option that keeps the current PM. When Shawn picks the label, run
  `programme.sh takeover --prompt <pick id>`; the pick id is in the
  `<auto-data>` tag the hook adds after his answer. When he declines, stop.
  Nothing else Shawn types or accepts approves a takeover; only that pick does.
- `stand-down`: another session now drives the programme this session drove,
  and it has not stopped. CronList shows this session's programme cron; delete
  it with CronDelete. Stop each Monitor task this session started with
  TaskStop. Then stop. Do not message Shawn.
- `refused`: run its `fix:` line.

If `takeover --prompt` refuses, run its `fix:` line: it names the
`approval-label` command whose output to offer in a new picker, then the
takeover to rerun with that pick id.

Run the dispatch line below only when Shawn typed `/auto:programme-takeover`
himself. The prompt hook journaled that typed request; the typed text, not the
argument, is what counts, so pass `--replace` only when Shawn typed it.

`bash "${CLAUDE_PLUGIN_ROOT}/lib/programme.sh" takeover "$ARGUMENTS"`

A typed takeover works at once when herdr shows the old PM is gone (its pane is
closed, or now runs another session or terminal), when the lease is orphaned
and the request was typed while it was, or when the typed request names the PM
with `--replace <PM session id>` (a pane name also works inside the PM's own
herdr workspace). If herdr cannot be read, auto does not count the PM as gone.

- Exit 1: run the refusal's `fix:` line and follow the step it prints. The
  refusal is journaled.
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
