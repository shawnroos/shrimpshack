---
name: programme-ritual
description: >
  Turn Shawn's plain description of a routine into a stored ritual: a workflow the PM runs on a calendar
  rule (every Monday) or at a programme moment (start, end, handover, takeover, resume after a gap, going
  quiet). Use when Shawn describes something the PM should do regularly or at one of those moments, asks to
  change or retire such a routine, or asks what rituals exist.
---

# Write a ritual

`P` means `bash "${CLAUDE_PLUGIN_ROOT}/lib/programme.sh"`. Read [the sweep's rituals reference](../programme-sweep/references/rituals.md) for how a ritual runs; this skill only writes one.

A ritual is whatever Shawn describes. There is no fixed list. Your job is to turn his words into a trigger, steps and a layer, show him the result, and store it only on his answer.

## Steps

1. **Read what exists.** `P status agreement` lists the rituals in force with their state, in its Rituals section. If one already does what he describes, say so and offer to change it instead.
2. **Pick the trigger from his words.**
   - A repeating time ("every Monday at 9", "daily", "on the 1st") is `--schedule 'weekly mon 09:00'`, `'daily HH:MM'` or `'monthly 1 HH:MM'`, in this machine's local time. Ask for the hour only if he gave none; default to 09:00 and say so.
   - A programme moment is `--trigger start`, `takeover`, `handover`, `end`, `resume` (the PM was silent for longer than two cadence periods and came back) or `quiet` (the stop rule fired, just before the programme idles).
   - Anything else (an item change such as a claim or a merge) is a Behaviour, not a ritual. Say so and use the behaviours reference instead.
3. **Write the steps in his words.** One line per step. A step is a PM action, a message to a worker, or a report to Shawn. Keep his wording; do not add steps he did not ask for. A step that deploys to production, cuts a release, spends over the cap, merges around the gate or uses a refused permission is refused, so tell him that and leave the step out.
4. **Draft, then show.** Run `P propose-ritual --when "<his words>" <trigger or schedule> --step "<line>"...`. A step must not name a protected action (publish, release, deploy, spend). When the check should end in a question about one, put the question in `--offer "<line>"` instead: an offer is shown to Shawn, so list each offer next to the steps when you show the proposal, and you act on it only on his answer. If a refusal names a step and a word, reword that step; an approval does not help. If the check is mechanical, a ritual can name one from the fixed list with `--check versions-bumped` (and `--check-repo <remit repo>` when the remit holds more than one repo): the sweep runs it and wakes you only when it fails. The offer shows Shawn the check. A repo can also ship a ritual as `.auto/rituals/<id>.md` on its default branch; that is proposed to Shawn, not recorded by you (see the sweep reference). A check cannot be a command; if he wants one that does not exist, say that a new check is a code change. It stores a proposal and applies nothing. Show Shawn, in one message: when it runs, each step, and which layer you recommend (programme for this programme only, repo for every programme on this repo, personal for every programme). Run `P offer <key> --command 'record-ritual --from-proposal <id>'` and ask with the input it prints.
5. **Store it on his answer.** If you already did the first check by hand, add `--ran-now --outcome "<what you found>"`; the result gives `first_due_at` and the clock (machine local time).   `P record-ritual --from-proposal <id> --prompt <his answer's id>`. If he chose repo or personal, ask again with `P offer <key> --command 'move-ritual <id> --to repo'` and run it on that answer: one answer approves one change.
6. **Change or retire.** To change one, propose a new ritual with the new steps and retire the old: `P retire-ritual <id> --as retired --prompt <id>`. To undo one you just recorded, `--as undone`.

## What the PM does with it

Nothing else runs from here. The sweep finds the ritual when its time comes: it runs a due one, and offers a missed one to Shawn in a single picker. You do not arm a timer; the programme stores each ritual's next due time.

## Offer more, once

After storing one, you may name one or two more rituals that fit what he asked for, as proposals only (`propose-ritual`), and mention them in one line. Candidates: a handover brief when he writes a Monday report, a takeover read-back, a resume check after a gap. Never store a proposal he has not answered.
