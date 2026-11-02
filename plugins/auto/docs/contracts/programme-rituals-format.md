# Programme rituals format

A ritual is a named workflow the PM runs when a calendar rule or a programme moment fires. It carries no authority: who decides stays with the agreement's terms and the protocol's autonomy levels. `lib/programme_rituals.py` checks, stores and resolves rituals; `lib/programme_rituals_due.py` says which are owed. This document is the format they enforce. The verbs are in agent-tool-surface.md ("Rituals"). Layers, the store file, adoption and moves follow programme-behaviours-format.md; this file records only what differs.

## 1. Entry

| Field | Type | Check |
| --- | --- | --- |
| `id` | string | Required. `^[a-z][a-z0-9-]*$`; the verbs mint `r` plus 6 hex digits. |
| `layer` | string | Required. `programme`, `repo` or `personal`. |
| `when` | object | Required. `{text, trigger, schedule?}`. `trigger` is `calendar`, `start`, `takeover`, `handover`, `end`, `resume` or `quiet`. `schedule` is present exactly when the trigger is `calendar`. |
| `steps` | list of strings | Required, at least one line, none empty. Shawn's plain words. |
| `why`, `source`, `state`, `repo_key`, `moved_to`, `moved_repo_key`, `history`, `at`, `adoption` | | As for a behaviour. `state` is `active` (the default), `proposed` or `retired`. |

Any other key rejects the entry (`unknown_key`). A step that names a protected escalation rejects it (`protected_escalation`) using the same words as a behaviour's `do` lines. Resolution re-validates every entry, so a ritual stored before a protected word was added is rejected on load and never runs.

## 2. Calendar rules

`schedule` is `{every, at, weekday?, day?}` in the machine's local time. `every` is `day`, `week` (with `weekday` 0 for Monday to 6) or `month` (with `day` 1 to 31). `at` is `HH:MM`. A day past the end of a short month lands on its last day. The verbs read `daily 09:00`, `weekly mon 09:00` and `monthly 1 09:00`.

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

Two cadence periods is the lease's own orphan threshold. A missed ritual is only ever offered, never run silently late: `start-ritual`, `run-ritual` and `skip-ritual` need Shawn's typed answer naming the ritual when it is missed. `offer-rituals` records the offer, and the due function then marks the miss `offered`, so an unanswered picker is not posted again. A `missed` or `in_flight` ritual is computed from the record, the store and the journal alone, so `P status` shows it when no PM is alive.

## 5. Rejection reasons

`unknown_key`, `missing_field`, `bad_value`, `protected_escalation`, `wrong_layer`, `wrong_key`, and the adoption reasons of programme-protocol-format.md §4.
