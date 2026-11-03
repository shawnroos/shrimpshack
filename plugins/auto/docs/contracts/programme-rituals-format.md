# Programme rituals format

A ritual is a named workflow the PM runs when a calendar rule or a programme moment fires. It carries no authority: who decides stays with the agreement's terms and the protocol's autonomy levels. `lib/programme_rituals.py` checks, stores and resolves rituals; `lib/programme_rituals_due.py` says which are owed. This document is the format they enforce. The verbs are in agent-tool-surface.md ("Rituals"). Layers, the store file, adoption and moves follow programme-behaviours-format.md; this file records only what differs.

## 1. Entry

| Field | Type | Check |
| --- | --- | --- |
| `id` | string | Required. `^[a-z][a-z0-9-]*$`; the verbs mint `r` plus 6 hex digits. |
| `layer` | string | Required. `programme`, `repo` or `personal`. |
| `when` | object | Required. `{text, trigger, schedule?}`. `trigger` is `calendar`, `start`, `takeover`, `handover`, `end`, `resume` or `quiet`. `schedule` is present exactly when the trigger is `calendar`. |
| `steps` | list of strings | Required, at least one line, none empty. Shawn's plain words. |
| `offers` | list of strings | Optional, at least one line when present, none empty. A question for Shawn that may name a protected action, such as "ask whether to publish the plugin now". An offer is shown, never run: the PM asks, and acts on the action only through the normal gates after Shawn's typed pick. The protected-word check covers `steps` only. An older plugin copy reads the machine-wide store too and rejects `offers` as `unknown_key`, so the ritual stops firing there until that copy updates. |
| `why`, `source`, `state`, `repo_key`, `moved_to`, `moved_repo_key`, `history`, `at`, `adoption` | | As for a behaviour. `state` is `active` (the default), `proposed` or `retired`. |

Any other key rejects the entry (`unknown_key`). A step that names a protected escalation rejects it (`protected_escalation`) using the same words as a behaviour's `do` lines. The detail names the escalation kind, the step number and the matched word, such as `full_release: step 2 names "publish"`; the fix is to reword that step, or to move the question into an `offers` line. A typed approval does not change this refusal. Resolution re-validates every entry, so a ritual stored before a protected word was added is rejected on load and never runs.

## 2. Calendar rules

`schedule` is `{every, at, weekday?, day?}` in the machine's local time (the time zone of the machine running the verb, so `daily 09:00` keeps reading 09:00 across a daylight-saving change). `record-ritual` and the Programme view say so and show the next due time in both UTC and local time with the zone name. `record-ritual` returns `first_due_at`, `first_due_local` and `clock` for a scheduled ritual. A ritual recorded after today's slot is first due tomorrow. `--ran-now [--outcome <text>]` records that the first slot was done by hand and moves the first due time one slot later; an event ritual has no slot and refuses it. `every` is `day`, `week` (with `weekday` 0 for Monday to 6) or `month` (with `day` 1 to 31). `at` is `HH:MM`. A day past the end of a short month lands on its last day. The verbs read `daily 09:00`, `weekly mon 09:00` and `monthly 1 09:00`.

The entry holds the rule only. Each programme keeps its own clock in `programme.ritual_clock[<id>].next_due_at`, because a stored entry is shared by every programme on the machine. Without a clock a ritual becomes pending at the first slot after it came into force. Every answer sets `next_due_at` to the first scheduled time after now, so an old miss is never offered again.

## 3. Triggers read from the journal

| Trigger | Pending from |
| --- | --- |
| `start` | the latest `programme_started` row |
| `takeover` | the latest `taken_over` row |
| `handover` | the latest `handed_over` row |
| `end` | the latest `programme_ended` row |
| `quiet` | the latest `stop_quiet` row |
| `resume` | the latest `ritual_event` row with `trigger: resume` |

A trigger before the ritual came into force does not make it pending. A `handover` or `end` ritual runs before its verb, in the tenure that is ending, so an answer anywhere in that tenure answers it; the verb refuses once while it is unanswered.

## 4. States

For each ritual in force, the due function returns one state. Answers are `ritual_ran` and `ritual_skipped`.

| State | Meaning |
| --- | --- |
| `in_flight` | a `ritual_started` row has no later `ritual_ran`, `ritual_failed` or `ritual_skipped` |
| `due` | pending, with no answer since, and at most two cadence periods old |
| `missed` | pending, with no answer since, and older than two cadence periods |

Two cadence periods is the lease's own orphan threshold. A missed ritual is only ever offered, never run silently late: `start-ritual` and `run-ritual` need Shawn's answer naming the ritual when it is missed, and `skip-ritual` needs it in every state. The state is checked again under the programme lock, because a due ritual can become missed between the probe and the write. `offer-rituals` records the offer, and the due function then marks the miss `offered`, so an unanswered picker is not posted again. A `missed` or `in_flight` ritual is computed from the record, the store and the journal alone, so `P status` shows it when no PM is alive.

The repo layer is a section of the machine-wide store (`repos.<key>` in `rituals.json` beside the personal protocol). `move-ritual --to repo` writes nothing inside the repository, so a repo-layer ritual does not travel with a clone of the repo.

## 5. Rejection reasons

`unknown_key`, `missing_field`, `bad_value`, `protected_escalation`, `wrong_layer`, `wrong_key`, and the adoption reasons of programme-protocol-format.md §4.
