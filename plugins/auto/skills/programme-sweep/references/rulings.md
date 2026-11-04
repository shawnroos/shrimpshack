# Naming and Rulings

Read this before you cite one of Shawn's messages as an approval, record a correction, or record an answer that fits no row of step 3's table. `P` means `bash "${CLAUDE_PLUGIN_ROOT}/lib/programme.sh"`.

## Rulings take one picker that shows your draft

You draft the Ruling. Auto writes the picker and Shawn approves the draft. He never has to name anything.

1. Run `P offer <key> --command 'record-ruling <id> --effect <effect> --kind <kind> --scope "<your draft>"'`. `close-ruling`, `accept-context`, `define-requirement` and `edit-project-term` work the same way.
2. Ask with the `input` it prints, unchanged.
3. Run the same command with `--prompt <his answer's id>`.

| His answer | What happens | The record says |
|---|---|---|
| Picks the option | Your draft binds | `wording: pm_draft`. The views do not put your words in his mouth |
| Other, a pick with a note, or a message, on a draft you read as his rewrite | Add `--reads-as '<the option's text>'`. His words replace the scope, the reason or the term text, with no second picker | `wording: shawn` |
| The same, on an authority option | Refused. Relay his words and ask again by pick | Nothing |
| Declines, or asks something | Run nothing | Nothing |

An authority option is a new or wider grant, a restrict that loosens, closing a restrict, or a wider `accept-context`. Its label says it widens, the decline comes first, and a pick binds it at once. Only his rewrite counts as content: if his words only say yes, ask him to pick the option, or his "yes" becomes the text. His text is capped at 500 characters. Auto refuses a longer one rather than cut it, so ask him for a shorter one. Show him `read_back` word for word.

## What a cited message must name when no offer is open

Always ask with `P offer` for a verb it takes. A typed message that answers no offer
must name what it approves, or the verb refuses it and
lists the missing words: the item id or key (`AI-753`) for the item rows, the
Ruling id for `carry-rulings`, the behaviour id and the layer word
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
the decision kind and the item from it. Offer it like any draft, or cite his
reply if it answers the offer. Show Shawn the one-line notice it
prints. When a grant moves a handed item back to open, decide it:
`P log-decision <item> --kind <the same kind> --why "<why>"`.
A correction changes who decides only.

## An answer that fits no row

An answer that fits no row is a Ruling: record it. Pick the effect by what he
said: his own call is `decided`, handing a kind of choice to you for named
items is `grant`, pulling one back to himself is `restrict`. A Ruling that
gives you more than its last revision (more items, a dropped limit, a later
end; or a restrict that loses items or ends sooner) takes a pick of its
widening option. A scope he sets is a
decided Ruling (`P record-ruling --effect decided`), what must be true for an item to count is a
requirement (`P define-requirement`), and an item tied to a decision is
`P assign-item <item> --decision-id <id>`. A decision or requirement recorded
with no prompt waits for `accept-context`, which you offer the same way. `P describe` lists every verb with its arguments
and what it refuses.
