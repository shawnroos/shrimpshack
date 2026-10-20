---
description: Hand this session's auto programme to another Claude session
argument-hint: "<session-id>"
allowed-tools: Bash, CronDelete, TaskStop
---

Shawn typed this in the programme's driving session to move the PM to another
session. The prompt hook has already journaled the request, with the session id
he named. Only a typed request in the driving session counts.

Run the dispatch line below:

`bash "${CLAUDE_PLUGIN_ROOT}/lib/programme.sh" handover "$ARGUMENTS"`

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
     accepted yet (`programme.sh status --json` has a `setup` part), the new
     session must resume `/auto:programme` step 5 at the first step not done
     before its first sweep. Nothing from this session's chat carries over.
