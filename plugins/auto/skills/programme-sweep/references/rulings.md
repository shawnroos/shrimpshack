# Naming and Rulings

Read this before you cite one of Shawn's messages as an approval, record a correction, or record an answer that fits no row of step 3's table. `P` means `bash "${CLAUDE_PLUGIN_ROOT}/lib/programme.sh"`.

## What the cited message must name

The cited message must name what it approves, or the verb refuses it and
lists the missing words: the item id or key (`AI-753`) for the item rows, the
Ruling id for `record-ruling`, `close-ruling` and `carry-rulings`, the
rule id for `adopt-rule`, the decision kind and the level for `adopt-autonomy`, the
repo and the check key (`verified.lookup`) for `adopt-check`, the decision or
requirement id for `accept-context`, the pause id for `lift-pause`, the attempt
or resource for `dispose-action`, the behaviour id and the layer word
("programme", "repo", or "personal", "global" or "all projects") with no
negation before it for `move-behaviour`, the proposal id for
`record-behaviour --from-proposal`, the proposal id
(`perm-1`) and exactly one answer word for `answer-permission`: "applied" or
"apply" for applied, "not now", "later" or "postpone" for not-now, "reject" or
"decline" for no. Shawn types, for example, "applied perm-1". A `--widening`
needs the word "widen" in his message too. When his message does not name the
target, do not run the verb: ask him to confirm in words that name it, for
example "adopt eval_waiver at act_and_tell, widen it", and cite that reply.
A prompt that approves a Ruling change (`record-ruling` that binds,
`accept-context` on a Ruling, `close-ruling` with a prompt, `carry-rulings`)
must also be typed after the proposal and used once: after the latest change
to that Ruling (for a new Ruling, his newest message that no verb has cited
yet), and never one that already approved another Ruling change. An old
message that happens to name the right words is refused; ask him again and
cite the new reply.

## Corrections

A correction replies to an ask or a decision you logged: `--replies-to`
takes the ask id from the handed item (`ask_id` in `P status --json`) or
the decision-log id from `P log-decision`. The verb takes
the decision kind and the item from it, and the Ruling applies at once
because his reply is itself the typed prompt. Show Shawn the one-line notice it
prints. When a grant moves a handed item back to open, decide it:
`P log-decision <item> --kind <the same kind> --why "<why>"`.
A correction changes who decides only.

## An answer that fits no row

An answer that fits no row is a Ruling: record it. Pick the effect by what he
said: his own call is `decided`, handing a kind of choice to you for named
items is `grant`, pulling one back to himself is `restrict`. A Ruling that
gives you more than its last revision (more items, a dropped limit, a later
end; or a restrict that loses items or ends sooner) waits for a prompt that
names what it adds. A scope he sets is a
decided Ruling (`P record-ruling --effect decided`), what must be true for an item to count is a
requirement (`P define-requirement`), and an item tied to a decision is
`P assign-item <item> --decision-id <id>`. A decision or requirement recorded
without his typed prompt waits for `accept-context`. `P describe` lists every verb with its arguments
and what it refuses.
