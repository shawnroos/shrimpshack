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
A verified human row resolves `unknown` to `typed` at authorization time.
An older human row cannot authorize a later event that reuses its prompt ID, even when their text matches.

The source reader supports the transcript shapes observed in Claude Code 2.1.302:

- Plain input requires `promptSource: typed`, `turnOrigin: human`, and `origin.kind: human`.
- Slash commands require human origin, human turn origin, CLI entrypoint, and matching command-name and command-args fields.
- Slash-command source text reconstructs the original slash command and arguments before comparing their hash.
- Meta messages, sidechains, compaction summaries, SDK input, and tool-result rows do not supply human authority.

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
