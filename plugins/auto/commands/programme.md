---
description: Start an auto programme for this herdr space, with the PM running in this session
argument-hint: "[<server.workspace>]..."
allowed-tools: Bash, Skill, Monitor, CronCreate, CronDelete, TaskStop
---

Start a programme: this session becomes the PM for the herdr space it runs in.
Do the steps in order. Run every programme verb in your own Bash tool, never from
a dispatched Agent: a sub-agent has its own session id and every verb refuses it.

1. Take the lease first. Run the dispatch line below before anything else:

   `bash "${CLAUDE_PLUGIN_ROOT}/lib/programme.sh" start "$ARGUMENTS"`

   - Exit 1 naming a run and session means another programme holds this space.
     Show Shawn that line and stop. A live holder moves only by
     `/auto:programme-handover` typed in its session; an orphaned one only by
     `/auto:programme-takeover` typed here.
   - On success, note the `run` id from the JSON line. The other verbs find the
     programme from this session's lease.
2. Check for a native goal. If a `/goal` condition is active in this session
   (you see a goal condition in your context), tell Shawn in one line that a
   native goal fights the programme's own stop rule, and ask him to run
   `/goal clear`. A Bash command cannot see the goal, so this check is yours.
3. Propose the agreement with the defaults: `programme.sh propose-agreement`.
   Run `programme.sh sweep` to read the space's shape. If the space suggests a
   different term value (for example a `tabs` remit), pass it as
   `--term <key>=<value>`.
4. Show one screen, and nothing else:
   - the output of `programme.sh rules` (the four terms with their proposed
     values, plus the protocol layers and rules it loaded);
   - the items the sweep proposes to adopt, one line each.

   Ask Shawn to accept, or to change terms in plain words. Then wait for his
   typed reply.
5. When he replies, the `<auto-data>` tag in your context names the prompt id.
   - Acceptance: `programme.sh accept-agreement --prompt <id>`.
   - A term change: `programme.sh amend-term <key> <value> --prompt <id>`, then
     ask again.
   - If a verb refuses because the agreement expired, run `programme.sh expire`
     and tell Shawn to run `/auto:programme` again.
6. Adopt the items. For each sweep proposal with action `adopt`:
   `programme.sh add-item <item> --title <title> --pane <pane> --session <session_id>`
   (leave out an option the proposal does not give). For `alias`, decide
   whether the pane's work is the same item and use `alias-item` or `add-item`.
7. Offer the live view in one line: "Type `/programme-view` for the live
   working model, or `/auto:programme-status` for a snapshot."
8. Arm the wake-ups:
   1. Monitor the remit watcher, with the longest timeout:
      `bash "<plugin root>/lib/programme-watch.sh"` (add `--linear` only when the
      space is bound to a Linear project). Each line it prints wakes you.
      Record it: `programme.sh watcher-beat remit --task-id <Monitor task id> --kind monitor`.
   2. CronCreate a recurring prompt at the cadence term (default hourly) with
      exactly this text: `Run the programme sweep: load the auto:programme-sweep skill and follow it.`
   3. Record the cron task: `programme.sh watcher-beat cron --task-id <cron id> --kind cron --prompt "Run the programme sweep: load the auto:programme-sweep skill and follow it."`
      The prompt must equal the cron text, or the prompt hook journals each
      cron firing as typed.
9. Load the `auto:programme-sweep` skill with the Skill tool and run the first
   sweep.

`programme.sh` above means `bash "<plugin root>/lib/programme.sh"`, with the
same plugin root as the dispatch line.
