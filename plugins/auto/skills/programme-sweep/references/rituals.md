# Rituals

Read this when the digest has a "Rituals" section, and before you record, move, retire or propose a ritual. `P` means `bash "${CLAUDE_PLUGIN_ROOT}/lib/programme.sh"`.

A ritual is a named workflow you run when a calendar rule or a programme moment fires (programme-rituals-format.md). It carries no authority: a step cannot widen what you or a worker may decide, and a step that names a protected escalation is refused. To write one from Shawn's words, use the `programme-ritual` skill.

## Run a due ritual

A `due` row means the trigger passed within the last two cadence periods and nothing has answered it.

1. `P start-ritual <id>`. It prints the steps and records that the ritual is in flight.
2. Do the steps, in order. A step is Shawn's plain words: a PM action, a message to a worker, or a report to Shawn. Do not do more than the steps say.
3. `P run-ritual <id> --outcome "<one line>"`. If you cannot finish, `P fail-ritual <id> --why "<one line>"`, and tell Shawn in the next report.

## Offer a missed ritual

A `missed` row means no PM ran it in time. Never run it silently late.

1. Collect every `missed` row with `offered` false, and every `in_flight` row (a ritual a previous PM began and did not finish).
2. `P offer-rituals <id>...` for all of them in one call. This is what stops the next sweep from asking again.
3. Ask Shawn once, in one AskUserQuestion picker, listing every ritual by id and what it does. Per ritual the options are: run now, skip this time, retire. For an in-flight ritual, "run now" reads "finish it".
4. On his typed answer, make one call per ritual, each citing the answer and naming that ritual's id. For "run now": `P start-ritual <id> --prompt <id>`, the steps, then `P run-ritual <id> --prompt <id>`. For "skip this time": `P skip-ritual <id> --prompt <id>`. For "retire": `P retire-ritual <id> --as retired --prompt <id>`.
5. Do not ask again for a miss that is already offered. Ask again only when a new miss appears.

## Handover and end

`P handover` and `P end` refuse once while a handover or end ritual is unanswered in your tenure. Run it (`start-ritual`, the steps, `run-ritual`), or ask Shawn to skip it, then retry. If you cannot (you are about to lose the session), pass `--without-rituals`: the ritual stays missed and the next PM offers it. Only the driving session is gated: an orphaned programme has no PM to run a ritual, so `end` from another session is never refused.

## Resume after a gap and going quiet

A `resume` ritual becomes due after a write that follows a silence longer than two cadence periods. A `quiet` ritual becomes due when the stop rule fires, once per active-to-quiet change. Run both like any other due ritual.
