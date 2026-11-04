---
description: Hand this session's auto programme to another Claude session
argument-hint: "<session-id>"
allowed-tools: Bash, CronDelete, TaskStop, AskUserQuestion
---

Shawn typed this, or asked in any words, to move the PM to another session. A typed
`/auto:programme-handover <session-id>` in the driving session is journaled by the
prompt hook. Otherwise ask him with the handover picker; never tell him to type this
command.

If Shawn typed the command, run the dispatch line below:

`bash "${CLAUDE_PLUGIN_ROOT}/lib/programme.sh" handover "$ARGUMENTS"`

If he did not, run `programme.sh offer hand-pm --command 'handover <session-id>'`, ask
with the `input` it prints, unchanged, and run nothing on "Not now". On his pick run
`programme.sh handover <session-id> --prompt <pick id>`. His own words never approve it:
relay them and ask again with the same picker.

- Exit 1: show Shawn the refusal line and stop. The refusal is journaled.
- Success: the lease and the driving session now name the new session. This
  session is no longer the PM and is no longer held at stop.
  1. Stop this session's watcher monitors with TaskStop, and delete the cron
     fallback with CronDelete; their beats now refuse.
  2. Tell Shawn in one line to open the new session and run the
     `auto:programme-sweep` skill there, re-arming the watcher and the cron
     fallback as its first sweep. The new session's first write refuses and
     prints the restored context (the rules in force, decisions, limits and
     pending questions from the store); it reads them and runs
     `programme.sh rules --ack` before it acts. If the agreement is not
     accepted yet (`programme.sh status --json` has a `setup` part), that
     restored context tells the new session to
     resume `/auto:programme` step 5 at the first step not done before any
     sweep. Nothing from this session's chat carries over.
