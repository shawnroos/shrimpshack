---
authors: Claude
type: contract
project: auto
topics: [programme, permission, proposal, hooks]
---
# Programme permission proposals

A worker can be refused a read it needs, such as `gh pr checks 12`. Programme turns
the refusal into one proposal for a native allow rule. Shawn applies the rule
himself and answers by typing. Programme then checks the settings files, asks the
worker to run the read once, and settles the proposal from the worker's
transcript.

Programme never writes a settings file. It opens settings files only to read
them.

## Hook rows

The plugin hook `on-permission-event` listens to `PermissionDenied`, and to
`PostToolUse` and `PostToolUseFailure` on Bash. It writes a row only for the
programme's driving session, and for a session that owns or is listed on an
unfinished item (state `open` or `waiting`). It prints nothing and always exits 0.

| Kind | When | Payload |
|---|---|---|
| `permission_denied` | every `PermissionDenied` event | `event`, `tool`, `tool_use_id`, `item_ids`, `transcript_path`, `transcript_bytes`, `command`, `reason`, `layer` |
| `permission_tool_ran` | a post-tool event for a command that runs `gh`, while any proposal is not resolved | the same, without `reason` and `layer` |

- `item_ids` lists the unfinished items the session owns or is listed on. It is
  empty for the driving session.
- `command` is redacted and capped at 2000 characters. `reason` is redacted,
  cleaned and capped at 300 characters.
- `transcript_path` and `transcript_bytes` come from the session registry, never
  from the hook input.
- `layer` comes from the reason text: `classifier_no_verdict`,
  `classifier_unavailable`, `classifier` (a reason that starts with a bracketed
  tag), or `unknown`.
- The rows never store `tool_response` or `error`, because both can hold command
  output.

A deny rule and a `dontAsk` refusal fire no hook at all. Only the transcript
records them. Such a block reaches the PM through a worker's `report-block`.

## Worker reports

`report-block --run <id> --item <id> --command <text>` is open to any session. It
appends a `permission_block_reported` line to `<home>/blocks.jsonl` with
`{item, operations, refusal, command_hash}`. It stores the catalog operation ids
and a hash, never the command text. A report never sets a layer and never creates
a proposal. `propose-permission --item <id>` turns an item's reports into an
explanation that the denying layer is unknown.

## Confirming a row

A row changes nothing until the session's own transcript confirms it:

1. The transcript path comes from the session registry, and its file name is
   `<session id>.jsonl`. A row that names another path is ignored.
2. The transcript holds a Bash `tool_use` with the row's `tool_use_id`.
3. The redacted command from the transcript equals the row's `command`.
4. The tool result row that follows carries the runtime's own
   `permissionDecision.decision`: `reject` for a denial, `accept` for a run.

A row without a matching transcript entry is ignored and counted on the item as
unconfirmed. It never creates, resolves or reopens a proposal, and it never
notifies.

## Eligible commands

Only verified reads get a proposal. Every part of the command, split on `&&`,
`||`, `;`, `|`, `|&`, `&` and newlines, must be one of:

- a catalog operation: `gh pr checks`, `gh pr view`, `gh run view` or
  `gh run list`, each with its listed flags and argument shapes;
- a built-in read: `cat`, `echo`, `grep`, `head`, `ls`, `pwd`, `tail`, `wc`.

An unlisted flag, an environment prefix, a redirection, a comment, a subshell,
`cd`, `-C`, `-R`, `--repo` or `--hostname` makes the command ineligible.
`--log`, `--log-failed`, `--web` and `--watch` are unlisted. An ineligible command
gets an explanation on the item instead of a proposal.

## Destination

The destination is the main checkout of the item's recorded `repo`. Only
`add-item --repo` sets that field, and only to a remit repo path. The main
checkout comes from the worktree's `.git` file and `commondir`, read directly,
without running git. It must equal a remit repo path. The rule goes in
`<main checkout>/.claude/settings.local.json`.

An item with no `repo`, or a destination outside the remit, gets an explanation
instead of a proposal.

## The proposal

`programme.permission_proposals[]` holds one entry per proposal:

| Field | Meaning |
|---|---|
| `id` | `perm-<n>` |
| `destination` | the main checkout path |
| `settings_file` | `<destination>/.claude/settings.local.json` |
| `operations` | catalog operation ids, in catalog order |
| `rules` | the rendered allow rules, for example `Bash(gh pr checks *)`. Display only |
| `reach` | what the rules allow beyond the blocked read, for example other repositories through `--repo` |
| `exclusions` | what the rules do not allow: merge, comment or review, push, credential access |
| `key` | `{operations, destination}` |
| `items` | every linked item |
| `evidence` | up to 50 confirmed denials: `{tool_use_id, session_id, at, operations, command, reason, layer, items}` |
| `state` | see States |
| `created_at`, `changed_at` | ISO times; `changed_at` moves on every state change and every fold |
| `notified_at` | set only after the herdr notifier exits 0 |
| `answers` | `{at, choice, prompt_id, from, to}` for every typed answer |
| `explanation` | the latest plain-text result for Shawn |
| `verified` | `{at, outcome, files}` from the last verify |
| `reservation` | the one reserved retry: `{item, session_id, operation, target, normalized, at, transcript_offset}` |
| `attempts` | how many retries were reserved |
| `pending_answer` | a not-now or no typed while retrying, applied after the outcome |
| `outcome` | `{state, tool_use_id, detail, at}` from settlement |
| `confirmed` | true when settled after a typed applied; false when resolved without one |
| `covering` | `{rule, source}` for an unconfirmed resolution |
| `redenied_at` | set when a resolved proposal's operations are denied again |

The proposal's key is its operation ids plus its destination. A change in rule
wording does not reopen a decision.

## One proposal per need

`propose-permission --item <id>... --denial <tool_use_id>...` places each
confirmed denial:

- Operations that a postponed, rejected or otherwise decided proposal for the
  same destination already holds attach as evidence. No notification goes out.
- New operations fold into the open proposal for that destination. When its
  operations grow, `notified_at` clears and Shawn is notified once more.
- New operations with no open proposal start a new one.
- A denial on a resolved proposal attaches as evidence, sets `redenied_at`, and
  shows as a decision for Shawn. Its state stays resolved and no notification
  goes out.

The denial's session must be the owner or a listed session of a given item, or
the verb refuses. When a denial lands on an open proposal, each linked item in
`open` or `waiting` waits on Shawn, with `waiting_on.permission` set to the
proposal id. Every call, and a call with no
arguments, re-sends open proposals whose `notified_at` is empty.

## States

| State | Meaning |
|---|---|
| `open` | waiting for Shawn |
| `postponed` | Shawn said not now |
| `rejected` | Shawn said reject |
| `retrying` | the rule is in place and one retry is reserved |
| `resolved` | the blocked read ran |
| `ineffective` | a deny rule, an ask rule, `classifyAllShell` or a new denial still blocks the read |
| `retry_unobserved` | the rule covers the read, but no retry was seen |

Programme asks again about `open`, `ineffective` and `retry_unobserved`.

## Shawn's answer

Shawn types in the PM's pane, for example `applied perm-1`. The PM runs
`answer-permission <perm-id> applied|not-now|no --prompt <id>`. The verb refuses
the answer unless the prompt:

- was typed by a human in the driving session;
- names the proposal id;
- says exactly one answer: "applied" or "apply"; "not now", "later" or
  "postpone"; "reject" or "decline" ("no" alone is read as a negation);
- is newer than the proposal's `changed_at`;
- was not cited by an earlier answer to that proposal.

| Answer | From | Result |
|---|---|---|
| not-now or no | `open`, `ineffective`, `retry_unobserved` | `postponed` or `rejected` |
| not-now or no | `postponed`, `rejected` | recorded; state kept |
| not-now or no | `retrying` | recorded as `pending_answer`; applied after the outcome unless the retry ran |
| applied | `retrying` | recorded; nothing changes |
| any | `resolved` | refused |
| applied | any other state | verify, below |

## Verify

On applied, the verb reads three files:

- the user's `~/.claude/settings.json`;
- the main checkout's `.claude/settings.local.json`;
- each blocked session's worktree `.claude/settings.json`, from the session
  registry's `cwd`.

It keeps only `permissions.allow`, `ask`, `deny` and
`autoMode.classifyAllShell`, and never stores or shows other keys. A file is
`read`, `absent`, or `unknown` (unreadable, larger than 1 MiB, or not a JSON
object). Each blocked command is matched part by part: deny first, then ask,
then allow, with `*` as any text.

| Outcome | When | Next state |
|---|---|---|
| `covered` | an allow rule covers every part of every blocked command | `retrying`, or `retry_unobserved` when no linked item's owner pane has a live agent |
| `not_covered` | some part has no allow rule | `open`, naming the uncovered operations; no retry is spent |
| `blocked_elsewhere` | a deny or ask rule matches, or `classifyAllShell` is set | `ineffective`, naming the rule and file |

A proposal with several commands takes the worst outcome. The explanation names
the files read, says when the covering rule reaches more than the proposed rule,
and always says that managed settings and a command-line `--settings` flag are
not visible.

A `covered` verify reserves one retry on the oldest linked item whose owner pane
has a live agent and a registry transcript. The result returns `retry_item` and
`retry_text`:

```
Permission <perm-id> is applied. Run this once, exactly as written: <normalized command>
```

The command text comes from the catalog's normalized form, never from raw denial
text. The PM sends it once with `prompt-item`. The `permission_verified` journal
line keeps the same text.

## Settlement

`settle-permissions` runs each sweep. It never retries.

For a `retrying` proposal it reads the reserved session's transcript from the
reserved byte offset, for a Bash call with the reserved operation and target. An
added pipe or other `--json` fields still match; another operation or target does
not.

| Seen | Result |
|---|---|
| the call, decision `accept` | `resolved`, `confirmed: true`; linked items waiting on the proposal return to `open` |
| the call, decision `reject` | `ineffective`, with the layer from the hook row or the transcript's `reasonType` and the next human action |
| no call, retry sent, owner pane idle or gone | `retry_unobserved` |
| no call otherwise | pending, with the reason: no registry transcript, herdr unavailable, retry not sent, or owner pane busy |

A red CI run that makes `gh pr checks` exit non-zero still counts as a run: the
runtime's decision decides, never the exit code.

An `open` proposal resolves with `confirmed: false` when every one of its
operations ran with decision `accept` in an affected session, after that
session's last recorded denial. It shows as a decision for Shawn with its covering rule, if any.

Only a new typed applied arms one more attempt from `ineffective` or
`retry_unobserved`.

## Settings writes are refused

The PreToolUse hook refuses a Write, Edit, MultiEdit or Bash call that names a
proposal's `.claude/settings.local.json`. It applies to the driving session and
to sessions on unfinished items, for every proposal in the programme, whatever
its state. It journals `blocked_settings_write` with `{tool, path, item_ids}`,
plus the redacted `command` for Bash. Other settings files stay editable.
Shawn's own edits and "always allow" clicks are not tool calls and stay
unaffected.

## Item fields

| Field | Meaning |
|---|---|
| `repo` | the item's remit repo path, set by `add-item --repo` |
| `waiting_on.permission` | the proposal the item waits on |
| `permission_block` | `{cause, detail, at, proposals, unconfirmed, reports}`, the item's latest explanation |

`cause` is one of `proposal`, `decided`, `unconfirmed`, `ineligible`, `no_repo`,
`bad_destination`, `unknown_cause`, `verify_covered`, `verify_not_covered`,
`verify_blocked_elsewhere`, or a settled state.

## Known limits

- Workers run as the same user. A process that writes both a journal row and a
  matching transcript entry passes the transcript check. The typed-prompt gate
  has the same limit. The Bash part of the settings guard is a text match that
  such a process can get around.
- A session started outside herdr has no session registry row, so it has no
  transcript path. Its rows can never be confirmed, and it can never take a
  retry.
- A denial in the PM's own session is journaled with no items.
  `propose-permission` refuses it, because the PM's session is not on any item.
- The `PermissionDenied` payload was not observed live. The hook relies on the
  documented fields `tool_name`, `tool_input`, `tool_use_id` and `reason`.
- The classifier's rejection shape in the transcript was not observed. Any
  `reject` counts as a denial, and an unknown `reasonType` maps to layer
  `unknown`.
- Programme does not track whether an applied rule is later removed. A later
  denial shows as a decision for Shawn and changes nothing else.
