# Rituals

Read this when the digest has a "Rituals" section, and before you record, move, retire or propose a ritual. `P` means `bash "${CLAUDE_PLUGIN_ROOT}/lib/programme.sh"`.

A ritual is a named workflow you run when a calendar rule or a programme moment fires (programme-rituals-format.md). It carries no authority: a step cannot widen what you or a worker may decide, and a step that names a protected escalation is refused. To write one from Shawn's words, use the `programme-ritual` skill.

## A ritual file in a repo

The digest's `file_proposals` and the Programme view list ritual files that sit on a remit repo's default branch and are not in force for this programme (`proposed`, or `changed` since Shawn adopted an earlier version). Put them to Shawn: the id, when it runs, each step and offer, the check if any, the short hash, and the commit and the age of the clone's last fetch. Run `P offer <key> --command 'adopt-ritual-file <repo key>/<id>' --command 'decline-ritual-file <repo key>/<id>'`, ask with the input it prints, and run the one he answers with `--prompt <id>`. You never adopt on your own, an answer is refused if the file changed since the offer, and an adopted ritual keeps running from the snapshot he approved until he adopts or declines the new content. A rejected file (`id_collision`, a protected step, a bad key) is for the repo's maintainers to fix, not for you to work around.

## A ritual with a check

`P run-ritual-checks` is chained in step 1 of the sweep, before `sweep-inputs`. It runs the named check of each due or missed calendar ritual that carries one, once per slot. A pass moves the ritual's clock and writes one `ritual_checked` row: you do nothing and the sweep stays quiet. A fail or error leaves the ritual due, and its row in the digest has a `check` field: `result`, `reason`, how many plugins were checked, the plugin names that failed and the age of the clone's last fetch (a stale clone reads stale). Treat that field as the facts. The check is a read of the repo, so you never run it yourself; to re-run one after the cause is fixed, `P run-ritual-checks --ritual <id>`. A `not_run` check was not reached this sweep (time limit or a session that does not drive): it stays due.

## Run a due ritual

A `due` row means the trigger passed within the last two cadence periods and nothing has answered it.

1. `P start-ritual <id>`. It prints the steps and records that the ritual is in flight.
2. Do the steps, in order. A step is Shawn's plain words: a PM action, a message to a worker, or a report to Shawn. Do not do more than the steps say. If the ritual has `offers`, they are questions for Shawn, never steps: ask him, and act on one only on his answer.
3. `P run-ritual <id> --outcome "<one line>"`. If you cannot finish, `P fail-ritual <id> --why "<one line>"`, and tell Shawn in the next report.

## Offer a missed ritual

A `missed` row means no PM ran it in time. Never run it silently late.

1. Collect every `missed` or `in_flight` row with `offered` false (an in-flight ritual is one a previous PM began and did not finish). An offer from a previous PM's tenure does not count: ask again once.
2. `P offer-rituals <id>...` for all of them in one call. This is what stops the next sweep from asking again.
3. Ask Shawn in AskUserQuestion pickers, one picker per ritual (a picker holds one decision), posted together. For each, run `P offer <key> --command 'start-ritual <id>' --command 'skip-ritual <id>' --command 'retire-ritual <id> --as retired'` and ask with the input it prints: start is run now (for an in-flight ritual, finishing it), skip is skip this time. A pick approves only its own option.
4. On his answer, make one call per ritual citing that ritual's answer: `P start-ritual <id> --prompt <id>`, the steps, then `P run-ritual <id> --prompt <id>`; or `P skip-ritual <id> --prompt <id>`; or `P retire-ritual <id> --as retired --prompt <id>`. His own words work too: see [own words](own-words.md).
5. Do not ask again for a miss that is already offered. Ask again only when a new miss appears.

## Handover and end

`P handover` and `P end` refuse while a handover or end ritual is unanswered in your tenure. Run it (`start-ritual`, the steps, `run-ritual`), or ask Shawn to skip it, then retry. If you cannot (you are about to lose the session), pass `--without-rituals`: the ritual stays missed and the next PM offers it. Only the driving session is gated: an orphaned programme has no PM to run a ritual, so `end` from another session is never refused.

## Resume after a gap and going quiet

A `resume` ritual becomes due after a write that follows a silence longer than two cadence periods. A `quiet` ritual becomes due when the stop rule fires, once per active-to-quiet change. Run both like any other due ritual.
