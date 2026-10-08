# Waits and watchers

"May stop" (the default stop rule, "nothing it can act on") lets the PM stop only
when every unfinished item waits on someone else and each wait is covered:

| Wait | Covered by | How |
|---|---|---|
| Something the PM can poll (a CI run, a deploy, a job) | a live watcher | Monitor `programme-watch.sh --item <item> -- <command>`; it beats the item's watcher each interval until the command exits, then prints `item-exited <item> exit=<n>` |
| A person who will report back | a named reporter | `set-waiting <item> --who <who> --reporter <name>` |
| An item no rule matches | Shawn | `propose-rule`, then `set-waiting <item> --who shawn --reporter shawn` |
| A checker that returned unknown twice | a retry watcher | the queued `arm_retry_watcher` entry; arm it, then remove the entry |

A watcher counts as live only while its heartbeat is newer than the cadence
term. A watcher whose Monitor expired stops beating, so the wait turns
unwatched and the Stop hook holds the PM until it is re-armed.

The remit watcher (`programme-watch.sh` with no `--item`) prints one line and
exits when anything in the space changes:

| Line | Do |
|---|---|
| `remit-changed ...` | sweep: new or changed panes |
| `claim <n> new` | sweep: read the inbox |
| `wait-due <item>` | check that item's wait |
| `tracker-changed ...` | sweep: issue states moved |
| `tasks-changed <session> <before>-><after> ...` | sweep: a worker's task list moved (counts are pending/in progress/completed) |
| `plans-changed +<repo>/<path> ...` | sweep: a plan was added (`+`) or edited (`~`) in a remit repo |
| `source-unavailable <name> missing`, or a reason naming `op unsupported` | `set-source <name> --unsupported` (this machine cannot read it; it never holds the stop) |
| any other `source-unavailable <name> <reason>` | `set-source <name> --unavailable --watcher remit` (a watched outage does not hold the stop) |
| `source-available <name>` | `set-source <name> --available` |

Record every watcher's kind with its task id: `--kind cron` for the cadence
cron, `--kind monitor` for a Monitor. `/auto:programme-end` prints
`CronDelete <id>` for cron watchers and `TaskStop <id>` for Monitor watchers.

Every Monitor expires after at most 30 minutes; re-arm the remit watcher at the
end of every sweep. The cron fallback (default hourly) wakes the PM when no
watcher is running, and survives a resume.

After a takeover or handover, the old session's watchers can no longer beat
(their calls are refused, and the remit watcher exits after three refusals).
Re-arm every watcher from the new driving session.
