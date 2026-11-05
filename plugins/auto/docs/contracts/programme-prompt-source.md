---
authors: Claude
type: contract
project: auto
topics: [programme, approval, prompt-origin]
---
# Programme prompt source

Programme approvals require a verified human source, not a journal label alone.

## Capture and verification

1. `UserPromptSubmit` records the runtime session, prompt ID, transcript path, raw-text hash, transcript byte offset, and prefix hash.
2. The runtime appends its source row after the hook returns.
3. Approval checks read the transcript after the captured offset and verify the prefix has not changed.
4. The first matching user row must identify human input and contain the exact captured text.
5. Existing session, target, lease, and request-consumption checks still apply.

The journal captures unmatched prompts as `unknown`. Registered cron prompts remain `cron`.
A prompt typed in a session that does not drive the programme is not journaled, apart from a typed `/auto:programme-takeover`, `-handover` or `-end` request. His own words and accepted suggestions never approve `takeover --prompt`: that verb takes only a pick of its option on the picker `become-pm` prints, whatever state the PM is in.
A verified human row resolves `unknown` to `typed` at authorization time.
An older human row cannot authorize a later event that reuses its prompt ID, even when their text matches.

The source reader supports the transcript shapes observed in Claude Code 2.1.302:

- Plain input requires `promptSource` of `typed` or `suggestion_accepted`, `turnOrigin: human`, and `origin.kind: human`. Any other `promptSource` stays `unknown`, apart from `queued` below.
- `suggestion_accepted` is Shawn pressing Enter on Claude Code's suggested prompt. Its text is model-written, so it resolves to `suggested`, not `typed`. A suggested prompt approves exactly what a pick may approve.
- Slash commands require human origin, human turn origin, CLI entrypoint, and matching command-name and command-args fields.
- Slash-command source text reconstructs the original slash command and arguments before comparing their hash.
- Meta messages, sidechains, compaction summaries, SDK input, and tool-result rows do not supply human authority.

Words sent while a turn runs, observed in Claude Code 2.1.318:

- `UserPromptSubmit` fires when the words are sent. Its `prompt_id` is the id of the running turn, not an id on any row these words produce. The row lands after the captured offset.
- The words land in one of two shapes. A message absorbed mid-turn is an `attachment` row with `attachment.type: queued_command`, `commandMode: prompt`, `humanTurn: true` and `origin.kind: human`, and it has no user row. A message that waits for the turn to end is a user row with `promptSource: queued`, its own `promptId`, `turnOrigin: human` and `origin.kind: human`.
- Either shape resolves to `typed` when it comes after the captured offset, sits in the same session and holds the exact captured text. The text hash replaces the prompt-ID match. Peer messages, task notifications and auto-continuations use the attachment shape with another origin, so they stay `unknown`.
- The running turn's own tool results carry the hook's `prompt_id`. They do not refuse queued words.
- The hook fires at send time, so `source.offset` is the enqueue position: on Claude Code 2.1.318 the hook's offset equals the byte where the `queue-operation` enqueue row lands, and delivery comes later. Own-words binding reads the question from before that offset (`question_before`), so words sent before a picker never answer it.

## Picker answers

A picker (AskUserQuestion) answer is a pick, with origin `picked`.
`UserPromptSubmit` does not fire for it.

The hooks find the programme through the same lease lookup that journals takeover requests (`request_lease` in `lib/on-user-prompt.py`): the lease this session drives, else the lease of this session's space. A session in a space with no lease is not journaled and not denied.

1. `PostToolUse` on AskUserQuestion journals a prompt row with origin `unknown` and a source record of kind `pick`. A row from a session that does not drive the programme also carries `driving: false`. A row without the key is a driving-session row.
2. The record holds the session, transcript path, tool-use ID, transcript byte offset, prefix hash, a hash of the answers map, and the redacted question-to-answer map.
3. The row resolves to `picked` only when the transcript check passes. The journal never stores `picked` as a label, and a stored `picked` label is not trusted.
4. The check needs one plain assistant row (same session, no sidechain or meta) with the `tool_use` for that ID, named AskUserQuestion, whose input has no `answers` key.
5. It needs one plain user row linked to that assistant row by `sourceToolAssistantUUID`, carrying the `tool_result` for that ID and a `permissionDecision.source` that starts with `user`.
6. That row's `toolUseResult.answers` must match the captured hash, and its redacted form must match the stored map.
7. The result row can sit before or after the captured offset. The prefix must be unchanged.
8. A result with `afkTimeoutMs` resolves `unknown`. The picker resolved itself after an idle timeout, so nobody chose the answer.

The PreToolUse AskUserQuestion hook denies a call whose input carries `answers` from the driving session or from any session in a leased space. It gates on the lease files, not on a repo `.claude/auto` folder.
The transcript check is the second line against a pre-filled answer.

The source reader supports the picker shapes observed in Claude Code 2.1.304.
A change to the secrets file can change the redacted map and make an older pick unverifiable.
A verified pick shows that Shawn chose the answer. Each verb that takes a pick checks what the pick may approve and that it is not cited twice.

A verified pick can still fail to approve an option. Each gate reads these from the transcript at approval time (`read_pick` in `lib/programme_pick_source.py`):

- A pick with `annotations[question].notes`, or the literal answer `(notes only)`, is verified but counts as Shawn's own words. It approves no option and no setup choice. A `preview` annotation with no note is a plain pick.
- A picker with a question left unanswered approves nothing. The check compares the questions on the asking row with the answers on the result row. A person can submit such a picker from the review screen.
- A label comparison reads the raw answer from the transcript, because the journal holds a redacted copy. The approval still stores the redacted answer.

The `PostToolUse` payload's `tool_input` holds `answers` and `annotations` after any pick, so it says nothing about a pre-filled answer. The asking row in the transcript is the only source for that check.

A `driving: false` pick verifies the same way, but it serves only the takeover. Every other approval gate (`programme_approval.prompt` and `programme_setup._picked`) refuses it, even after its session takes over and becomes the driver. Picks collected before a takeover therefore never become PM approvals after it.

A newer word from Shawn voids an older prompt for a Ruling change (`check_newest` in `lib/programme_rulings.py`). A later `typed` prompt, including queued words, or a later verified pick from the driving session counts, unless something has cited or spent it.

An approval verb (`PICK_VERBS` in `lib/programme_approval.py`, the same set as the offer renderers) binds only to Shawn's answer to an open offer of that command. A message or pick with no such offer approves nothing, whatever it says, and the refusal's fix says to run `programme.sh offer`. A `suggested` prompt approves nothing: the model wrote it. The list is default-deny: a new verb has no approval until it has a renderer.

A pick cited this way must hold exactly one question on the exact picker `offer` printed, and its answer must be one of that offer's options. A trailing " (Recommended)" is ignored. The option holds the hash of its command, so a pick approves no other command, and the facts it showed, so a change to them forces a new offer. `set-remit` gives the offer the same JSON on stdin that the verb reads. A pick with a note, Other text and a message in the session count as Shawn's own words: on an authority move they are refused, and on any other verb they need `--reads-as <the option's text>`, recorded and shown back. Earlier free-text checks on the answer leaked three review rounds running ("No", "Skip r1", "Keep item-x" approving drop-item). One pick approves one change: a pick that any earlier row cites, under any prompt id journaled for the same picker answer, is refused. The approval records `origin: picked` or `origin: typed`, and how the PM read it.

A pick of a picker that `programme.sh offer` printed binds by stored offer, not by label: `agent-tool-surface.md` gives the rule. The label comparison stays only for a picker with no matching offer, as an alias until the instructions move to `offer`.

## Failure behavior

Missing, malformed, changed, truncated, or unsupported source records refuse approval without changing programme state.
A row that has not arrived yet can be checked again later.
Historical `typed` entries without captured source evidence are unverified; there is no legacy trust fallback.

Immediate approvals, persisted local adoption loading, lifecycle requests, and cited lifecycle prompts use the same source check.
Non-driving takeover and orphaned-end requests carry their own source evidence because they lack driving prompt citations.

Resume and compaction do not grant authority. Transcript removal or rewriting can make a previous approval unverifiable.
Source reads reject prefixes or subsequent transcript sections larger than 64 MiB.
These refusals favor approval safety over availability; they do not classify missing records as human.

## Trust and limits

Runtime transcripts and hook input share the existing local-files trust boundary.
The hashes bind an event occurrence; they are not signatures and do not protect against another process rewriting all local state.
Source verification establishes who supplied the prompt, not whether every requested operation was intended.
Keys sent to a pane by a terminal host write the same rows as Shawn's key presses, measured on Claude Code 2.1.318: an Enter or a digit into an open picker gives `permissionDecision.source: user_temporary`, and text sent to the prompt gives `promptSource: typed` or a queued row. Text sent into an open picker with no focus on its text field is dropped, and the Enter after it chooses the highlighted option.
Existing operation-specific approval checks remain necessary.

The existing other-machine personal-protocol exception remains unchanged.
Its non-widening rules are governed by `programme-protocol-format.md`, not a new local transcript guarantee.

Synthetic source rows belong only in isolated automated test fixtures.
They do not count as live human approval or a genuine human runtime positive control.
