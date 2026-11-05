# Behaviours

Read this when Shawn gives standing guidance on how the work is done, and before you record, move, retire or propose a behaviour. `P` means `bash "${CLAUDE_PLUGIN_ROOT}/lib/programme.sh"`.

A behaviour is Shawn's standing guidance on how the work is
done. It carries no authority and no done bar: who decides stays with
Authority and Rulings, and acceptance stays with Done standards.
- Before you record one, run `P check-behaviour` with the fields you drafted (or `--from-proposal <id>`). It
  records nothing. It lists the behaviours in force the new one applies
  alongside (`behaviours`) and the parts of the programme contract it touches
  (`contract`), each with the reason that listed it. `flag: may_contradict` marks a
  structural clash. Read each listed pair's `lines` yourself: code does not detect
  opposite meaning, so an empty list is not a pass. When the new one disagrees
  with a behaviour, pass `--conflicts-with <id>`. The new one wins, because the
  narrower layer wins (programme over repo over personal).
- Draft the checks from his words. A check you can test from what the sweep
  sees (item state, a claim, a merge, a block, the tracker) is `--pm-check`.
  One only the agent doing the work can judge is `--agent-check`. Keep as many
  PM checks as you can. You cannot see a PR being opened unless the worker
  reports it, so ask the worker to name the PR in its claim or make that check
  an agent check.
- In one message, show Shawn the checks it printed, the ones you cannot test
  and why, the behaviour result and the contract result (what each lists and
  what is flagged), the `undo` line it printed, any conflict and which one wins,
  and ask: "Keep it for this programme, move it to the repo, or make it global?"
  Run `P offer <key> --command 'move-behaviour <id> --to repo'` with one `--command`
  per layer, ask with the input it prints, and move it on his answer. See
  [own words](own-words.md) when he answers in his own words.
- `synergies` says how the new behaviour should fit with one it listed: `link`
  (a shared moment or tool: record it with `--relates-to`, or ask whether the
  two should merge) and `ending_rule` (one ends the work its situation names,
  and the other's `do` lines never say what happens then). It never blocks
  recording. Code gives the target and the field, not the wording: write the
  proposed change yourself from the row's `lines` and show it in the same
  message as the conflicts. Apply an offered edit only on Shawn's answer:
  - `route: programme_edit`: `P propose-behaviour --edit-of <id>` with the
    fields to change (give a full replacement for each field you name, for
    example the whole `do` list), tell him the proposal id, and run
    `P record-behaviour --from-proposal <id> --prompt <id>` once he approves its
    offer. The old wording stays in force until then.
  - `route: copy_default_then_settle`: a shipped or file behaviour; follow
    "Edit a default" below (copy it, then edit the copy).
  - `route: record_with_conflicts_with`: a stored repo or personal behaviour;
    record the new wording as a programme behaviour with `--conflicts-with <id>`.
  - `action: adjust_new`: the change belongs in the behaviour you are
    recording, so redraft it before you record.
- Answer what the check listed when you record: `--relates-to <id>` for an item
  that applies (a behaviour id, or `term:<key>`, `tool:<id>`, `ruling:<id>`,
  `authority:<action>`, `done:<deliverable>`), and `--unrelated <id>=<reason>` for
  one that does not. The output's `unanswered` counts the listed items you did
  not answer. The check never refuses to record. A flagged item you did not
  resolve goes to Shawn in the same message.
- When the output shows a disagreement you did not link, name it the same way.
  If he wants it linked, undo the new one and record it again with
  `--conflicts-with`, `--relates-to` or `--unrelated`.
- A new or changed behaviour reaches work in progress as a reminder from now
  on (step 5). Never send back work that already passed its trigger.
- A behaviour has a trigger (`--trigger claim|merge|block|start`; none reads as
  claim): the item change after which it applies. Once an item's trigger has
  passed, the digest lists the behaviour as due until you answer it with a
  reminder or `skip-behaviour`. A behaviour recorded after the trigger passed is
  never due for that item. A behaviour that applies to the PM only and has no
  trigger is never listed: it has no item moment, so read it from `P rules`.
  A trigger passes at the item's first claim, first merge, first wait or hand,
  or first worker start, so a behaviour recorded after that is not due for the
  item; a worker that was never started by `start-worker` has no start. The
  digest shows 20 lines. After answering them, run `P sweep-inputs --save`
  again while its `behaviours_due.overflow` is above 0. A reminder answers only
  the trigger it was sent for, so pass `--trigger` as the line shows it.
  `skip-behaviour` needs no prompt: it records
  your judgment, not Shawn's approval.
- A do line, skill, tool or agent that names a protected escalation
  (production deploys, releases, spend over cap, merging around the gate,
  refused permissions) is refused. Tell Shawn those still come to him.
- When Shawn corrects you twice on the same thing, you may draft a behaviour
  from his words with `P propose-behaviour`. It applies only when he approves
  `P offer <key> --command 'record-behaviour --from-proposal <id>'`.
- Once per programme, offer to move preferred tools out of the agreement's
  Scope. For each preferred tool `P status --agreement` lists, run
  `P propose-behaviour --from-term <term-id>`. Show him each term with its
  drafted behaviour and ask which are tool preferences, one offer per behaviour:
  `record-behaviour --from-proposal <id>` and `retire-behaviour <id> --as retired`
  as its two options. The term itself stays as it is; from then on, read the
  preferred tool from the behaviour.

## Guided flow: a standing preference as a file

Offer it when Shawn states a standing preference ("always", "never", "from now
on") or asks to change a default. After two corrections for the same thing you
may suggest a behaviour, but only as a proposal: nothing is written. A proposal
is not an adoption, and you cannot write the personal behaviours folder or
`behaviours.json` yourself: a direct Write, Edit or shell write there is denied.
The files get written by the verbs below, after he approves their offer.

1. Draft the whole file from his words: id (the file name), `when`, `trigger`,
   `applies_to`, the checks (`pm:` or `agent:`), the Do and Don't lines, and a
   `why`. Say which choices you inferred.
2. Ask with the picker only when you are unsure: personal, repo or programme,
   or which trigger fits. Otherwise decide and say so.
3. Write the draft to a scratch path and show the finished file in chat, whole:
   a large draft does not fit a picker. Run
   `P offer <key> --command 'adopt-behaviour-file <id> --file <path>'` and ask
   with the input it prints. Auto stores the content's hash, and he carries
   nothing: on his answer run `P adopt-behaviour-file <id> --file <path> --prompt
   <id>`. If the draft changed since the offer the verb refuses, so show the new
   draft and offer again. Keep the path; `--file -` cannot be offered.
4. Edit a default: offer `copy-default <id>` and on his answer run
   `P copy-default <id> --prompt <id>`. Draft the
   edited file at a scratch path, show the difference against the shipped file,
   and offer `settle-default-update <id> --as merge --file <path>` (the adopt
   verb refuses to overwrite a file that exists).
5. Update notice: a copy made with `copy-default` is flagged `update available`
   when the shipped default changed. Raise the update prompt only when the row
   also says `not yet shown`. Show the shipped difference once, then record it
   with `P settle-default-update <id> --as shown` (no approval needed); the
   row stops saying `not yet shown`, so later sweeps stay quiet. Then offer
   keep mine, take theirs or merge: one offer whose three commands are
   `settle-default-update <id> --as keep`, `--as take` and
   `--as merge --file <path>`, so each is an option. Run the one he picks.

To switch a shipped default off, no verb retires it: write a personal file whose
`overrides` names its id, or record a programme behaviour with
`--conflicts-with <id>`. A broken behaviour file is reported to Shawn once; do
not repeat it every sweep.

Shipped files and personal files carry no adoption record: shipped ones count
by install, personal ones by where they sit. A file's start time is its last
edit, so an edited file reaches work in progress as a reminder only; never send
back work that already passed its trigger.
