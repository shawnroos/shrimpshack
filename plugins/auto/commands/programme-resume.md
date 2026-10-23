---
description: Bring a herdr space's auto programme back after a crash, a quit or a login reset — re-arm the PM, then restart every worker pane in the remit
allowed-tools: Bash, Skill, Monitor, CronCreate, CronList, CronDelete, TaskStop, AskUserQuestion, SendMessage
---

Shawn typed this in the PM session after the Mac crashed, Claude quit, or a login
reset killed the sessions. The programme's store survived; the live sessions,
watchers and cron did not. Bring them back in this order, then sweep. `P` below
means `bash "${CLAUDE_PLUGIN_ROOT}/lib/programme.sh"`.

Never run `pgrep -fl`, `ps -f` or `ps -E`: they print other sessions' environments,
secrets included. Never `git add -A`.

## 1. The PM first

1. Run `P beat`. If a verb refuses and prints the rules in force, read them and
   run `P rules --ack`, then repeat it.
2. If the lease names another session, stop and ask Shawn to type
   `/auto:programme-takeover --replace <that session id>` in this session. A
   takeover counts only when Shawn types it, so never run it yourself. Come back
   here after it succeeds. Never take over a PM that is still running.
3. Check this session's pane. The remit watcher skips only the pane in
   `HERDR_PANE_ID`, and a resumed session can carry the id of the pane it ran in
   before, so a stale id makes the watcher fire on every PM turn. Read that pane
   (`herdr pane read "$HERDR_PANE_ID" --lines 20`). If it does not show this
   conversation, ask Shawn which tab the PM runs in, with a picker over the
   labels from `herdr pane list`. Pane ids and labels differ per machine, so
   never take one from another machine or an earlier run.
4. Arm the remit watcher with that pane id, under Monitor at the longest timeout:
   `HERDR_PANE_ID=<real pane> bash "${CLAUDE_PLUGIN_ROOT}/lib/programme-watch.sh" --tracker`
   Then `P watcher-beat remit --task-id <Monitor task id> --kind monitor`.
   Use the same prefix every time you re-arm it.
5. `CronList`. If the cadence cron is missing, CronCreate it at the cadence term
   with the exact text `Run the programme sweep: load the auto:programme-sweep skill and follow it.`
   and run `P watcher-beat cron --task-id <id> --kind cron --prompt "<that exact text>"`.

## 2. Inventory

1. List the items that still have work, with their pane and session:
   ```
   P status --json | python3 -c '
   import json,sys; d=json.load(sys.stdin)
   for i in d["model"]["items"]:
       if i.get("effective_state") not in ("done","handed","dropped","decided"):
           print(i["id"], i.get("effective_state"), i.get("owner_pane"), i.get("session"), "|", i.get("title"))'
   ```
2. Read the remit's panes: `herdr pane list`. For each pane note `agent`,
   `agent_status`, `label`, `cwd` and `restore_error`.
3. Sort each item into one row:
   | Pane state | Action |
   | --- | --- |
   | Claude running and working | leave it |
   | Shell, Claude gone | resume in that pane |
   | `restore_error` ("Saved directory is unavailable") or pane missing | resume in a new tab |
   | Done, parked, or waiting on Shawn with nothing to run | skip, list for Shawn |

## 3. Restart the workers

For each item to resume:

1. Read the pane first: `herdr pane read <pane> --lines 30`. Never close a pane or
   type into it without reading it.
2. If the worktree directory is gone, recreate it at the same path with
   `git worktree add <path> <the item's branch>`. Never create the directory
   any other way: a worker resumed in a folder that is not a checkout works
   outside the repo. `claude --resume` finds a session only from the directory
   it started in, so the path must match. If you cannot recreate it, skip the
   item and list it for Shawn.
3. Resume in place:
   `herdr pane run <pane> "cd <worktree> && claude --resume <session id>"`
4. Or resume in a new tab, named `<ticket> <max 3 words>`:
   ```
   herdr tab create --workspace <ws> --cwd <worktree> --label "<ticket> <words>" --no-focus
   herdr pane run <new pane> "claude --resume <session id>"
   ```
   Add the launch flags the programme's rules name (a model, for example);
   add none of your own.
5. Re-own the item on the pane it now runs in:
   `P add-item <item> --pane <pane> --session <session id>`.

## 4. Brief each resumed session once

When a resumed session is idle (`herdr pane list` shows `agent_status` idle), send
one prompt with `P prompt-item <item> "<text>"`. If prompt-item refuses, do not
send it another way: list the item and the refusal for Shawn. The text:

> PM: your session was resumed after a <crash | quit | login reset>. Re-read your
> last state. Check your CI watchers and open PRs: their heads may have moved
> since you stopped. Re-arm any background watchers you still need, then carry on
> where you stopped. The same rules apply: technical calls to the PM, product
> calls to Shawn by picker. Never prompt the PM's pane. Report with
> `programme.sh claim`.

Then add the standing rules from the programme's rules block (`P rules`) that
apply to workers, for example its commit, test and browser rules. Write no
repo-specific rule here that the rules block does not hold.

## 5. Expired logins

A session that reports expired external auth (for example AWS `ExpiredToken` on
an MFA profile) cannot fix it. Do not work around it. Tell Shawn in one line,
with the exact `! <command>` to type in that session's pane.

## 6. Sweep and report

1. Load the `auto:programme-sweep` skill and run one sweep.
2. Report to Shawn with one table, then anything waiting on him:
   | Item | Tab / pane | Result |
   | --- | --- | --- |
   | `<ticket> "<title>"` | `<tab label>` | resumed in place / new tab / skipped (why) |
