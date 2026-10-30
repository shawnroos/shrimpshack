# Behaviours

Read this when Shawn gives standing guidance on how the work is done, and before you record, move, retire or propose a behaviour. `P` means `bash "${CLAUDE_PLUGIN_ROOT}/lib/programme.sh"`.

A behaviour is Shawn's standing guidance on how the work is
done. It carries no authority and no done bar: who decides stays with
Authority and Rulings, and acceptance stays with Done standards.
- Before you record one, read the behaviours in force (`P rules`). When the
  new one overlaps or disagrees with one of them, pass `--conflicts-with <id>`.
  The new one wins, because the narrower layer wins (programme over repo over
  personal).
- Draft the checks from his words. A check you can test from what the sweep
  sees (item state, a claim, a merge, a block, the tracker) is `--pm-check`.
  One only the agent doing the work can judge is `--agent-check`. Keep as many
  PM checks as you can. You cannot see a PR being opened unless the worker
  reports it, so ask the worker to name the PR in its claim or make that check
  an agent check.
- In one message, show Shawn the checks it printed, the ones you cannot test
  and why, the `undo` line it printed, any conflict and which one wins, and
  ask: "Keep it for this programme, move it to the repo, or make it global?"
  It moves only on his typed answer naming the layer.
- When the output's `related` list shows a disagreement you did not link, name
  it the same way. If he wants it linked, undo the new one and record it again
  with `--conflicts-with`.
- A new or changed behaviour reaches work in progress as a reminder from now
  on (step 5). Never send back work that already passed its trigger.
- A behaviour has a trigger (`--trigger claim|merge|block|start`; none reads as
  claim): the item change after which it applies. Once an item's trigger has
  passed, the digest lists the behaviour as due until you answer it with a
  reminder or `skip-behaviour`. A behaviour recorded after the trigger passed is
  never due for that item. A behaviour that applies to the PM only and has no
  trigger is never listed: it has no item moment, so read it from `P rules`.
  `skip-behaviour` needs no typed prompt: it records
  your judgment, not Shawn's approval.
- A do line, skill, tool or agent that names a protected escalation
  (production deploys, releases, spend over cap, merging around the gate,
  refused permissions) is refused. Tell Shawn those still come to him.
- When Shawn corrects you twice on the same thing, you may draft a behaviour
  from his words with `P propose-behaviour`. Tell him its id. It applies only
  when his typed reply names it (the "Apply a behaviour you proposed" row).
- Once per programme, offer to move preferred tools out of the agreement's
  Scope. For each preferred tool `P status --agreement` lists, run
  `P propose-behaviour --from-term <term-id>`. Show him each term with its
  drafted behaviour id and ask which are tool preferences. Apply the ids his
  typed reply names with `--from-proposal`, and retire the rest with
  `--as retired`, citing the same reply. The term itself stays as it is; from
  then on, read the preferred tool from the behaviour.
