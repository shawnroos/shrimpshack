# Shawn's own words

Read this when Shawn answers an offered question in words instead of a pick: a typed or queued message after he left the picker, Other text, or a pick with a note. `P` means `bash "${CLAUDE_PLUGIN_ROOT}/lib/programme.sh"`.

## Read them first

His words answer the question just asked. Read what he means before you run anything.

"No", "Skip r1" and "Keep item-x" on a drop picker are declines. Run nothing. The same goes for a question, a condition or a change of subject: run nothing, answer him, and ask again if the question still stands. Auto cannot judge your reading, so a wrong one drops the item.

## Who may approve what

| Class | Commands | His own words |
|---|---|---|
| Authority moves | `accept-agreement`, `end`, `handover`, takeover, `adopt-autonomy --widening`, a remit widening, `answer-permission <id> allow`, a wider `accept-context` | Refused. Relay his words and ask again with the picker. Only a pick of the option approves these. A typed `/auto:programme-end` or `/auto:programme-handover` stays valid |
| Drafts | `record-ruling`, `close-ruling`, `edit-project-term`, except an authority move | His words become the text, marked `wording: shawn`. See [rulings.md](rulings.md) |
| Everything else on an offer | `drop-item`, `reopen-item`, `answer-handed`, `lift-pause` and the other verbs `P offer` takes | Approve, with your reading recorded and shown back |

On a behaviour or ritual draft his words stay as its source, marked as his wording. If they change the draft, propose a new one and offer again.

An accepted suggestion approves no offer: the model wrote that text. Say so and ask with the picker. A peer, a system message or the cron never approves.

## When his words approve

1. Take the prompt id from the `<auto-data>` tag of his message or pick.
2. Run the offered command with `--prompt <id> --reads-as '<the option's text>'`.
3. Show the `read_back` line to Shawn in your next message, word for word.

One message approves one command.

## When Auto refuses

| Refusal | What it means | What to do |
|---|---|---|
| No open offer | You did not ask this question, a pick already answered it, or another question came after it | Run `P offer`, ask with the input it prints, and wait |
| Came before the offer | He sent the message before he saw the question, even if it arrived after | Ask again |
| Older than another message | He said more after this message | Read the newer one |
| The facts changed | The item or the terms changed since the offer | Run `P offer` again and ask again |
