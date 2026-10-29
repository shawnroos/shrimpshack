---
description: Start an auto programme for this space, with the PM running in this session
argument-hint: "[<server.workspace>]..."
allowed-tools: Bash, Skill, Monitor, CronCreate, CronDelete, TaskStop, AskUserQuestion
---

Start a programme: this session becomes the PM for the space it runs in.
Do the steps in order. Run every programme verb in your own Bash tool, never from
a dispatched Agent.

Whenever Shawn asks this session, in any words, to be the PM, to replace the PM
or to take over as PM, run `programme.sh become-pm` first and follow the one
step it prints. Only `start` continues with step 1 below. For
`ask-shawn` or `stand-down`, follow `/auto:programme-takeover`; for
`already-pm`, run the sweep; for `refused`, run its `fix:` line. When
`$ARGUMENTS` names spaces, go straight to step 1: become-pm reads only this
session's own space.

1. Take the lease first. Run the dispatch line below before anything else:

   `bash "${CLAUDE_PLUGIN_ROOT}/lib/programme.sh" start "$ARGUMENTS"`

   - Exit 1 naming a run and session means another programme holds this space.
     Run `programme.sh become-pm` and follow the step it prints.
   - On success, note the `run` id from the JSON line. The other verbs find the
     programme from this session's lease.
2. Check for a native goal. If a `/goal` condition is active in this session
   (you see a goal condition in your context), tell Shawn in one line that a
   native goal fights the programme's own stop rule, and ask him to run
   `/goal clear`. A Bash command cannot see the goal, so this check is yours.
3. Propose the agreement with the defaults: `programme.sh propose-agreement`.
   Then probe the sources: `programme.sh sweep --record-sources`. It reads the
   space's shape and records each source's state through set-source, so the
   first sweep starts from them. If the space suggests a different term value
   (for example a `tabs` remit), pass it as `--term <key>=<value>`.
   Then work out the remit: load the `auto:programme-remit` skill, find the
   repos and the tracker scope with your own tools, and store them with
   `programme.sh set-remit`. Accepting the agreement in step 6 approves it.
   Its output lists `carried_over`: project terms kept from an earlier
   programme on the same repos, already added to this agreement. `notices`
   names any carried-over entry it dropped.
   Then pre-fill the project terms from evidence, not from questions to Shawn. Each
   term is one area and one short text: who decides that area (Shawn, the PM or
   a worker), the existing skills or tools to prefer for a kind of job
   (ideation, options, requirements, implementation, optimisation,
   acceptance), or what acceptance means for this project. Read the evidence
   yourself:
   - the remit repos: their README, CLAUDE.md or AGENTS.md, plan docs and test
     commands;
   - prior runs: the `carried_over` terms, and plans and run records under each
     repo's `.claude/auto/`;
   - Shawn's installed skills: name only skills in your own skill list. Never
     name one you cannot see there.
   Add them with `programme.sh propose-agreement --project-term "<area>=<text>"
   --source "<where it came from>"`. One call takes one `--source`, so make one
   call per source. An area Shawn keeps for himself goes in as
   `--reserved-term "<area>=<text>"`. An area that already has a term
   (carried over or earlier) refuses; leave it. An area about deploys,
   releases, spend, permissions, risk or cost limits, or settled decisions is
   refused unless it is reserved for Shawn.
4. Record what the probe saw, so the pane can show what is in and what is out:
   `programme.sh setup-seen --json -` with `{"tabs": [...], "repos": [...],
   "tracker": [...], "items": [{"item", "title", "pane", "session"}]}` on
   stdin: every terminal-host tab, repo and tracker scope the sweep saw (in the remit
   or not), and the items it proposes to adopt (`"items": []` when it found
   none; the items step stays open until this is recorded). When the tracker is
   unavailable, read the remit's issues through `mcp__linear__list_issues` and
   record them with `programme.sh record-issues` first (see the
   programme-tracker skill).
5. Walk Shawn through setup, one question per step. The Programme pane beside
   the chat shows the whole draft; the chat carries only the current question.
   Print nothing else: no setup screen, no rules dump, no recap.
   - Your first line, once: "If the Programme pane is not beside this chat,
     type /programme-view."
   - Read the steps from `programme.sh status --json` (its `setup` part: steps
     in order, each with `state`, `values`, `recommendation`,
     `recommendation_source`, `needs_typed`, `reply` and, for a term,
     `options`). Re-read it after every write; the pane redraws from the same
     data.
   - First question (AskUserQuestion): "Take all my recommendations?" with
     "take all recommendations (Recommended)" first and "walk each step" second.
     On take-all, run `programme.sh take-recommendations --pick <id>` and go to
     the first step that is still not done.
   - For each step that is not done: run `programme.sh setup-step <key>`, then
     ask one AskUserQuestion. Name the setting in the question text. Put the
     recommendation first, marked "(Recommended)", with its source in the
     option description; offer the step's other `options` by their exact
     names, since a pick must name the value it sets.
     - The answer's `<auto-data>` tag names the pick's prompt id. Apply it with
       `programme.sh pick-term <key> <value> --pick <id>`.
     - Never put answers into the AskUserQuestion call yourself; a pre-filled
       picker is refused and approves nothing.
   - Steps with `needs_typed` (rulings and reserved areas, shared settings):
     during setup these take a typed reply. Ask in a picker
     whether to keep it as is or change it. Keep: `programme.sh setup-keep
     <key>`. Change: show the step's `reply` as "Type this:" and wait for his
     typed line; then apply it as in step 6.
   - When a verb refuses a pick, say why in one line and ask that step again.
   - Shawn can change an earlier answer before the accept by naming the step;
     ask that step again.
   - Sources (`tools_of_record`) are a step like any other: each option label
     names only the sources that stay on, never "no X" or "skip X". A pick is
     refused when its answer names a source the value leaves out.
   - Items to adopt: ask which of the step's items to adopt (multiSelect), then
     adopt them as in step 7.
   - Last step: the accept, offered as a pick. Run
     `programme.sh approval-label accept-agreement`; it prints
     `Approve accept-agreement --terms <digest>`, where the digest names the
     terms `status` shows now.
     Offer that exact text as one AskUserQuestion option. On that pick, run
     `programme.sh accept-agreement --prompt <pick id> --terms <digest>`.
     Shawn can also type "accept the agreement"; a typed accept needs no
     `--terms`.
   - On a re-run, a handover or a takeover before acceptance, start at the first
     step that is not done; never start over.
6. When he types a reply, the `<auto-data>` tag in your context names the
   prompt id.
   - Acceptance: `programme.sh accept-agreement --prompt <id>`, plus
     `--terms <digest>` when the prompt is a pick.
   - A term change: `programme.sh amend-term <key> <value> --prompt <id>`.
   - A project term change: `programme.sh edit-project-term <term-id> "<text>"
     [--reserved|--unreserved]`, or a new one with `propose-agreement
     --project-term "<area>=<text>" --source "Shawn at startup"`.
     `accept-agreement` refuses a prompt older than the last proposal, pick,
     term amend or project-term edit, and a `--terms` digest that no longer
     matches the terms, so ask for the accept again after any change. It
     refuses an accepted suggestion.
   - Turning sources off or on by a typed reply: `programme.sh amend-term
     tools_of_record <list> --prompt <id>`, where the list holds the sources
     that stay on, comma separated (`tracker,tasks`), or `none`. His reply must
     name each source that changes. A source turned off is never read or
     watched and never holds the stop.
   - If a verb refuses because the agreement expired, run `programme.sh expire`
     and tell Shawn to run `/auto:programme` again.
7. Adopt the items he chose. For each sweep proposal with action `adopt`:
   `programme.sh add-item <item> --title <title> --pane <pane> --session <session_id>`
   (leave out an option the proposal does not give). For `alias`, decide
   whether the pane's work is the same item and use `alias-item` or `add-item`.
8. Arm the wake-ups:
   1. Monitor the remit watcher, with the longest timeout:
      `bash "<plugin root>/lib/programme-watch.sh"` (add `--tracker` only when
      the sweep found a tracker provider). It also watches tasks and plans
      unless the agreement turns them off. Each line it prints wakes you.
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
