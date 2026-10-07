---
name: programme-sweep
description: >
  The PM's sweep loop for an auto programme. Use when this session drives a
  programme and a watcher line, the cron fallback, a worker claim or Shawn wakes
  it: prune prompts, re-check evidence, read the remit and the inbox, check
  claims, drive workers, record waits with watchers, update the working model,
  re-arm the wake-ups, then stop.
---

# Programme sweep

One sweep, top to bottom, then stop. `P` below means
`bash "${CLAUDE_PLUGIN_ROOT}/lib/programme.sh"`. Every verb finds the programme
from this session's lease.

## Ground rules

- Run every programme verb in your own Bash tool. Never run one from a
  dispatched Agent: a sub-agent has its own session id, and every write verb
  refuses it.
- A refusal that prints the rules in force means context was compacted. Read the
  rules, run `P rules --ack`, and repeat the refused verb.
- Never use `/goal`. The programme's stop rule is the only stop rule.
- Only a checker writes evidence. A worker's "done" is a claim, never evidence.
- An approval (accept, amend, instruction, adopt a rule, an autonomy level or a
  check command, answer a handed item, drop or reopen an issue item) cites the
  prompt id from the `<auto-data>` tag of Shawn's typed message. Never cite a
  cron prompt.

## The sweep

1. **Beat and expire.** `P beat`. If it refuses because the programme ended,
   stop. `P expire` ends a programme whose agreement was never accepted; if it
   prints `"ended": true`, tell Shawn in one line and stop.
2. **Prune prompts.** `"${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}" "${CLAUDE_PLUGIN_ROOT}/lib/programme_journal.py" prune --run <run>`.
   The run id is the `run` field of `P status --json`.
3. **Apply Shawn's typed answers.** For each message Shawn typed since the last
   sweep, cite the prompt id from its `<auto-data>` tag with `--prompt <id>`:

   | Shawn's answer | Verb |
   | --- | --- |
   | Ship or decline a handed item | `P answer-handed <item> --choice ship\|decline --prompt <id>` (ship also needs `--kind <change-kind>`) |
   | A standing instruction ("always...", "until...") | `P record-instruction --prompt <id> [--applies-to <item>] [--until <text>]` |
   | Withdraw an instruction | `P close-instruction <instruction-id> --as withdrawn --prompt <id>` |
   | Adopt a proposed rule | `P adopt-rule <rule-id> --prompt <id>` (add `--widening` only when he approved the wider autonomy) |
   | Change how far the PM may go on an action | `P adopt-autonomy <action> <never\|propose\|act_and_tell\|act> --prompt <id>` (add `--widening` only when he approved a level wider than the default) |
   | Adopt a repo's build check commands | `P adopt-check <repo> verified.lookup '<argv-json>' --prompt <id>`, then the same for `verified.deployed_sha` |
   | Drop an issue item | `P drop-item <item> --reason <text> --prompt <id>` |
   | Reopen a dropped item | `P reopen-item <item> --prompt <id>` |
   | Two items are one piece of work | `P merge-item <from-item> <into-item>` |
   | He tested a build | `P record-tested-build <item> --shasum <sha> [--package <name>] [--version <v>]` |

   An answer that fits no row is an instruction: record it. `P describe` lists
   every verb with its arguments and what it refuses.
4. **Validate.** `P validate` re-checks confirmed evidence that has gone stale.
   A refuted re-check reopens its item; treat it as open work in this sweep.
5. **Read the remit.** `P sweep --record-sources`.
   - Adopt each `adopt` proposal with `P add-item` (pass `--pane`, `--session`
     and `--title` from the proposal). Decide each `alias` proposal yourself with
     `P alias-item` or `P add-item`.
   - An item whose owner pane now reports a different session: confirm the new
     owner with `P add-item <item> --pane <pane> --session <session>`.
6. **Sources.** For each watcher line `source-unavailable <name>` or
   `source-available <name>` since the last sweep, run
   `P set-source <name> --unavailable` or `--available`. The sweep records the
   changes it saw itself.
7. **Read the inbox.** `P status --json` shows `unread_claims`. Read the new
   lines of `<home>/claims.jsonl` (past the programme's `inbox_offset`), then
   `P mark-read`.
8. **Check claims.** For each claimed deliverable, run
   `P check-deliverable <item> <deliverable>`. Pass `--repo <clone>` for
   verified and released (the local clone of the item's repo). Confirmed closes
   the deliverable; unknown or refuted leaves it open, and the item's history
   shows the claim as unconfirmed.
9. **Arm retry watchers.** For each queue entry with action `arm_retry_watcher`:
   1. Read the item's `watchers["retry-<item>"].retry.argv`.
   2. Monitor `bash "${CLAUDE_PLUGIN_ROOT}/lib/programme-watch.sh" --item <item> -- bash "${CLAUDE_PLUGIN_ROOT}/lib/<argv[0]>" <argv[1:]>`.
   3. `P queue --remove <entry-id>`.
10. **Drive workers.**
   - Start a queued worker with `P start-worker <item> -- <spinoff arguments>`.
     Never pass `--session-id`; the verb mints it.
   - Prompt a worker with `P prompt-item <item> "<text>"`. It sends only to the
     item's recorded pane and owner session.
   - Every brief or prompt to a worker carries these two clauses:
     - "Record before any long background wait: send your claim first."
     - "Never prompt the PM's pane. Report with
       `bash <plugin root>/lib/programme.sh claim --run <run> --item <item> --deliverable <name> --ref <ref>`."
11. **Record waits.** Every wait has a live watcher or a named reporter.
    - A wait the PM watches: Monitor
      `programme-watch.sh --item <item> -- <watch command>` (for example
      `gh run watch <id>`), then `P set-waiting <item> --who <who> --watcher <watcher id>`. The watcher id is
      `item-` plus the item id with every character outside `A-Za-z0-9_-` turned
      into `-` (for example `item-linear-AI-753`).
    - A wait a person reports back on: `P set-waiting <item> --who <who> --reporter <name>`.
    - A wait with a due time: add `--due <ISO time>`.
    - A blocker held by another team or shared by two items: debug it at
      runtime first, then pass `--blocker --trace-id <id>` or `--job-id <id>`.
    - An item no protocol rule matches: `P propose-rule '<rule json>'`, then
      `P set-waiting <item> --who shawn --reporter shawn`.
12. **Hand product calls.** A product question goes to Shawn with
    `P hand-item <item> --question "<one question>"`. It notifies him once.
13. **Update the working model.** `P set-now "<what you do next>" --item <item>`
    (or `--clear`), and `P queue --action <name> --item <item>` or
    `--remove <entry-id>` so the queue matches your next actions.
14. **Re-arm the wake-ups.**
    - Monitor `bash "${CLAUDE_PLUGIN_ROOT}/lib/programme-watch.sh"` with the
      longest timeout. Add `--linear` only when the space is bound to a Linear
      project. A second watcher exits by itself, so re-arming is safe.
    - Keep the cron fallback. If it is missing (after a resume or takeover),
      CronCreate it again at the cadence term with the exact text
      `Run the programme sweep: load the auto:programme-sweep skill and follow it.`
      and run `P watcher-beat cron --task-id <id> --prompt "<that exact text>"`.
15. **Stop.** End the turn. The Stop hook holds you while you have a next action
    of your own or a wait with no watcher; act on the reason it gives.

Show Shawn the live view with `/programme-view`, or a snapshot with
`/auto:programme-status`. More detail on watchers and waits:
[references/waits-and-watchers.md](references/waits-and-watchers.md).
