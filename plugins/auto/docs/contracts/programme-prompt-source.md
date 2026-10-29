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
A prompt typed in a session that does not drive the programme is not journaled, apart from a typed `/auto:programme-takeover`, `-handover` or `-end` request. Typed text and accepted suggestions never approve `takeover --prompt`: that verb takes only a pick of its exact label, whatever state the PM is in.
A verified human row resolves `unknown` to `typed` at authorization time.
An older human row cannot authorize a later event that reuses its prompt ID, even when their text matches.

The source reader supports the transcript shapes observed in Claude Code 2.1.302:

- Plain input requires `promptSource` of `typed` or `suggestion_accepted`, `turnOrigin: human`, and `origin.kind: human`. Any other `promptSource` stays `unknown`.
- `suggestion_accepted` is Shawn pressing Enter on Claude Code's suggested prompt. Its text is model-written, so it resolves to `suggested`, not `typed`. A suggested prompt approves exactly what a pick may approve.
- Slash commands require human origin, human turn origin, CLI entrypoint, and matching command-name and command-args fields.
- Slash-command source text reconstructs the original slash command and arguments before comparing their hash.
- Meta messages, sidechains, compaction summaries, SDK input, and tool-result rows do not supply human authority.

## Picker answers

A picker (AskUserQuestion) answer is a pick, not a typed prompt.
`UserPromptSubmit` does not fire for it.

The hooks find the programme through the same lease lookup that journals takeover requests (`request_lease` in `lib/on-user-prompt.py`): the lease this session drives, else the lease of this session's herdr space. A session in a space with no lease is not journaled and not denied.

1. `PostToolUse` on AskUserQuestion journals a prompt row with origin `unknown` and a source record of kind `pick`. A row from a session that does not drive the programme also carries `driving: false`. A row without the key is a driving-session row.
2. The record holds the session, transcript path, tool-use ID, transcript byte offset, prefix hash, a hash of the answers map, and the redacted question-to-answer map.
3. The row resolves to `picked` only when the transcript check passes. The journal never stores `picked` as a label, and a stored `picked` label is not trusted.
4. The check needs one plain assistant row (same session, no sidechain or meta) with the `tool_use` for that ID, named AskUserQuestion, whose input has no `answers` key.
5. It needs one plain user row linked to that assistant row by `sourceToolAssistantUUID`, carrying the `tool_result` for that ID and a `permissionDecision.source` that starts with `user`.
6. That row's `toolUseResult.answers` must match the captured hash, and its redacted form must match the stored map.
7. The result row can sit before or after the captured offset. The prefix must be unchanged.

The PreToolUse AskUserQuestion hook denies a call whose input carries `answers` from the driving session or from any session in a leased herdr space. It gates on the lease files, not on a repo `.claude/auto` folder.
The transcript check is the second line against a pre-filled answer.

The source reader supports the picker shapes observed in Claude Code 2.1.304.
A change to the secrets file can change the redacted map and make an older pick unverifiable.
A verified pick shows that Shawn chose the answer. Each verb that takes a pick checks what the pick may approve and that it is not cited twice.

A `driving: false` pick verifies the same way, but it serves only the takeover. Every other approval gate (`programme_approval.prompt` and `programme_setup._picked`) refuses it, even after its session takes over and becomes the driver. Picks collected before a takeover therefore never become PM approvals after it.

A verified pick, or a `suggested` prompt, also approves the `--prompt` verbs on the pick list (`PICK_VERBS` in `lib/programme_approval.py`). Every verb on that list checks that the approval names its target. `accept-agreement` is on the list for a pick only: the pick must answer its terms-bound label and the verb must pass the same `--terms` digest, and an accepted suggestion never approves it. Any other verb, including `edit-project-term`, `record-ruling`, `close-ruling`, `carry-rulings`, `record-behaviour` and `define-requirement`, needs a typed prompt. A Ruling binds only on a typed prompt: `accept-context` takes a pick or a suggestion for a requirement, and refuses one for a Ruling. The list is default-deny: a new verb refuses picks until it is added.

A pick cited this way must hold exactly one question, and its answer must equal the approval label of the command being run: "Approve " followed by the shell-quoted verb and arguments, without `--prompt` and `--run`. `programme.sh approval-label <verb> <args>` prints it. A trailing " (Recommended)" is ignored. `set-remit` takes its change on stdin, which no label can show, so a pick never approves it; a typed prompt or an accepted suggestion does. An option value that starts with `--` is refused, so a label cannot hide `--run` inside another option. Any other answer approves nothing, so a decline cannot be misread as approval whatever its wording. Earlier free-text checks on the answer leaked three review rounds running ("No", "Skip r1", "Keep item-x" approving drop-item). Naming checks still read only the answer. An accepted suggestion containing a negation word (including "never") approves nothing; type it instead. One pick approves one change: a pick that any earlier row cites, under any prompt id journaled for the same picker answer, is refused. The approval records `origin: picked` or `origin: suggested`.

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
Existing operation-specific approval checks remain necessary.

The existing other-machine personal-protocol exception remains unchanged.
Its non-widening rules are governed by `programme-protocol-format.md`, not a new local transcript guarantee.

Synthetic source rows belong only in isolated automated test fixtures.
They do not count as live human approval or a genuine human runtime positive control.
