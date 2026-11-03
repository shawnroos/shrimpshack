# Rituals

Read this when the digest has a "Rituals" section, and before you record, move, retire or propose a ritual. `P` means `bash "${CLAUDE_PLUGIN_ROOT}/lib/programme.sh"`.

A ritual is a named workflow you run when a calendar rule or a programme moment fires (programme-rituals-format.md). It carries no authority: a step cannot widen what you or a worker may decide, and a step that names a protected escalation is refused. To write one from Shawn's words, use the `programme-ritual` skill.

## A ritual with a check

`P run-ritual-checks` is chained in step 1 of the sweep, before `sweep-inputs`. It runs the named check of each due or missed calendar ritual that carries one, once per slot. A pass moves the ritual's clock and writes one `ritual_checked` row: you do nothing and the sweep stays quiet. A fail or error leaves the ritual due, and its row in the digest has a `check` field: `result`, `reason`, how many plugins were checked, the plugin names that failed and the age of the clone's last fetch (a stale clone reads stale). Treat that field as the facts. The check is a read of the repo, so you never run it yourself; to re-run one after the cause is fixed, `P run-ritual-checks --ritual <id>`. A `not_run` check was not reached this sweep (time limit or a session that does not drive): it stays due.

## Run a due ritual

A `due` row means the trigger passed within the last two cadence periods and nothing has answered it.

1. `P start-ritual <id>`. It prints the steps and records that the ritual is in flight.
2. Do the steps, in order. A step is Shawn's plain words: a PM action, a message to a worker, or a report to Shawn. Do not do more than the steps say. If the ritual has `offers`, they are questions for Shawn, never steps: ask him (picker or typed words), and act on one only on his typed pick.
3. `P run-ritual <id> --outcome "<one line>"`. If you cannot finish, `P fail-ritual <id> --why "<one line>"`, and tell Shawn in the next report.

## Offer a missed ritual

A `missed` row means no PM ran it in time. Never run it silently late.

1. Collect every `missed` or `in_flight` row with `offered` false (an in-flight ritual is one a previous PM began and did not finish). An offer from a previous PM's tenure does not count: ask again once.
2. `P offer-rituals <id>...` for all of them in one call. This is what stops the next sweep from asking again.
3. Ask Shawn in AskUserQuestion pickers, one picker per ritual (a picker holds one decision), posted together. Each option is the exact text `P approval-label <command>` prints for the command it approves: `start-ritual <id>` for run now (for an in-flight ritual, finishing it), `skip-ritual <id>` for skip this time, `retire-ritual <id> --as retired` for retire. A pick approves only that exact label; free text such as "Skip r1" approves nothing.
4. On his answer, make one call per ritual citing that ritual's pick: `P start-ritual <id> --prompt <pick id>`, the steps, then `P run-ritual <id> --prompt <pick id>`; or `P skip-ritual <id> --prompt <pick id>`; or `P retire-ritual <id> --as retired --prompt <pick id>`. A typed reply naming the ritual id works the same way.
5. Do not ask again for a miss that is already offered. Ask again only when a new miss appears.

## Handover and end

`P handover` and `P end` refuse while a handover or end ritual is unanswered in your tenure. Run it (`start-ritual`, the steps, `run-ritual`), or ask Shawn to skip it, then retry. If you cannot (you are about to lose the session), pass `--without-rituals`: the ritual stays missed and the next PM offers it. Only the driving session is gated: an orphaned programme has no PM to run a ritual, so `end` from another session is never refused.

## Resume after a gap and going quiet

A `resume` ritual becomes due after a write that follows a silence longer than two cadence periods. A `quiet` ritual becomes due when the stop rule fires, once per active-to-quiet change. Run both like any other due ritual.
