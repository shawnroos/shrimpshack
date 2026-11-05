---
authors: Claude
type: contract
project: auto
topics: [programme, permission, proposal, transcript]
---
# Programme permission proposals

A worker can be refused a read it needs, such as `gh pr checks 12`. Programme turns
the refusal into one proposal for a native allow rule. Shawn answers through a
picker. If he picks allow, Programme writes the rule, checks the settings files,
asks the worker to run the read once, and settles the proposal from the worker's
transcript.

`answer-permission <id> allow` is the only path that writes a settings file. Every
other path opens settings files only to read them.

## Finding refusals

Claude Code writes its own ruling on every Bash call into the session transcript.
The result row after a `tool_use` carries `permissionDecision.decision`
(`accept` or `reject`), `permissionDecision.reasonType` (the layer that decided),
and `toolDenialKind`. This is the only denial evidence Programme trusts. No hook
reports refusals: a deny rule and a `dontAsk` refusal fire no hook at all.

`propose-permission` reads, for each item, the transcripts of its owner and listed
sessions:

1. The transcript path comes from the session registry, and its file name is
   `<session id>.jsonl`. Any other path is never read.
2. Reading starts at the item's scan cursor for that session
   (`permission_scan[<session id>]`, a byte offset) and the cursor then moves to the
   end. A call still waiting for its result row is read again next time.
3. Only rows timed after the session joined the item count (the earliest `at` of
   that session in the item's `sessions`). A session's earlier history is never
   replayed.

A `reject` row is then routed by its `reasonType`:

| `reasonType` | Layer | Result |
|---|---|---|
| `mode` | mode | a proposal, when the command is eligible |
| `classifier` | classifier | a proposal, when the command is eligible |
| `subcommandResults` | deny rule | an explanation naming the deny rule; no proposal |
| `hook` | hook | an explanation; no proposal |
| anything else | unknown | an unknown-cause explanation; no proposal and no guessed rule |

A named item whose sessions have no readable transcript, or no refusal in them,
gets an unknown-cause explanation instead of a proposal. That is how a block a
worker mentions, but the runtime never ruled on, reaches Shawn.

Refusal text and command output are never stored. Evidence keeps the normalized
command, the layer and the `reasonType`.

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
| `rules` | the rendered allow rules, for example `Bash(gh pr checks *)`. Display only: allow renders them again from the catalog |
| `reach` | what the rules allow beyond the blocked read, for example other repositories through `--repo` |
| `exclusions` | what the rules do not allow: merge, comment or review, push, credential access |
| `key` | `{operations, destination}` |
| `items` | every linked item |
| `evidence` | up to 50 refusals: `{tool_use_id, session_id, at, operations, command, layer, reason_type, items}` |
| `state` | see States |
| `created_at`, `changed_at` | ISO times; `changed_at` moves on every state change and every fold |
| `notified_at` | set only after the herdr notifier exits 0 |
| `answers` | `{at, choice, prompt_id, from, to}` for every answer |
| `written` | `{rules_written, file, before_hash, after_hash, at}` from the last allow. `rules_written` is empty when allow wrote nothing |
| `explanation` | the latest plain-text result for Shawn |
| `verified` | `{at, outcome, files}` from the last verify |
| `reservation` | the one reserved retry: `{item, session_id, operation, target, normalized, at, transcript_offset}` |
| `attempts` | how many retries were reserved |
| `pending_answer` | a not-now or no given while retrying, applied after the outcome |
| `outcome` | `{state, tool_use_id, detail, at}` from settlement |
| `confirmed` | true when settled after an allow or applied answer; false when resolved without one |
| `covering` | `{rule, source}` for an unconfirmed resolution |
| `redenied_at` | set when a resolved proposal's operations are denied again |

The proposal's key is its operation ids plus its destination. A change in rule
wording does not reopen a decision.

## One proposal per need

`propose-permission [--item <id>]...` places each refusal it finds. With no
`--item` it reads every unfinished item:

- Operations that a postponed, rejected or otherwise decided proposal for the
  same destination already holds attach as evidence. No notification goes out.
- New operations fold into the open proposal for that destination. When its
  operations grow, `notified_at` clears and Shawn is notified once more.
- New operations with no open proposal start a new one.
- A denial on a resolved proposal attaches as evidence, sets `redenied_at`, and
  shows as a decision for Shawn. Its state stays resolved and no notification
  goes out.

When a refusal lands on an open proposal, each linked item in `open` or
`waiting` waits on Shawn, with `waiting_on.permission` set to the proposal id.
Every call re-sends open proposals whose `notified_at` is empty.

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

The PM runs `programme.sh offer <question-key> --command 'answer-permission <perm-id>
<choice>'` and asks with the picker it prints. Auto writes the option. The allow
option shows every rule, the file, the reach and the exclusions, and comes after
the decline. All the proposal's rules are approved together. A proposal that
changes after the offer makes the offer stale, so the PM offers again.

The PM then runs `answer-permission <perm-id> allow|applied|not-now|no --prompt <id>`.
The verb refuses an answer that is not bound to an offer of that exact command,
whatever its words say.

| Answer | Means | Own words |
|---|---|---|
| `allow` | write the rule | refused: relay his words and ask again. Only a pick approves |
| `applied` | Shawn added the rule by hand; check it | approved, with the PM's reading shown back |
| `not-now` | postpone | approved, with the PM's reading shown back |
| `no` | reject | approved, with the PM's reading shown back |

| Answer | From | Result |
|---|---|---|
| not-now or no | `open`, `ineffective`, `retry_unobserved` | `postponed` or `rejected` |
| not-now or no | `postponed`, `rejected` | recorded; state kept |
| not-now or no | `retrying` | recorded as `pending_answer`; applied after the outcome unless the retry ran |
| allow or applied | `retrying` | recorded; nothing changes |
| any | `resolved` | refused |
| allow | any other state | write, below, then verify |
| applied | any other state | verify, below |

## Write

On allow, the verb:

1. Renders the rules again from the catalog, and never uses the stored `rules` text.
2. Recomputes the destination from each linked item's `repo` and the remit. A
   mismatch, or a repo no longer in the remit, is refused.
3. Runs verify. `covered` writes nothing. `blocked_elsewhere` writes nothing and
   gives `ineffective`, since an allow rule cannot beat a deny rule, an ask rule or
   `classifyAllShell`.
4. Refuses when git tracks `.claude/settings.local.json`, naming the file. If git
   cannot answer, the write goes on and the explanation says so.
5. Merges into the parsed file. Every other key, the key order and the file's mode
   stay. Only rules not already listed are appended to `permissions.allow`. A
   symlink stays a link, and its target gets the change. The verb creates an
   absent file and folder, with mode 0600.
6. Refuses a file that is not valid JSON, is not an object, is larger than 1 MiB, or
   has a `permissions` or `permissions.allow` value of the wrong type. The file stays
   as it was.
7. Runs verify again, which picks the next state, and journals `written`
   (`rules_written`, `file`, `before_hash`, `after_hash`) on `permission_verified`.

The same `--op` replays the committed result. The same pick cited again is refused.
A fresh answer on a rule already written adds no second copy.

## Verify

On allow or applied, the verb reads three files:

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
| the call, decision `reject` | `ineffective`, with the layer from the transcript's `reasonType` and the next human action |
| no call, retry sent, owner pane idle or gone | `retry_unobserved` |
| no call otherwise | pending, with the reason: no registry transcript, herdr unavailable, retry not sent, or owner pane busy |

A red CI run that makes `gh pr checks` exit non-zero still counts as a run: the
runtime's decision decides, never the exit code.

An `open` proposal resolves with `confirmed: false` when every one of its
operations ran with decision `accept` in an affected session, after that
session's last recorded denial. It shows as a decision for Shawn with its covering rule, if any.

Only a new allow or applied answer arms one more attempt from `ineffective` or
`retry_unobserved`.

## Direct settings writes are refused

The PreToolUse hook refuses a Write, Edit, MultiEdit or Bash call that names a
proposal's `.claude/settings.local.json`. Only the `allow` verb writes that file,
after Shawn's pick. The hook applies to the driving session only,
for every proposal in the programme, whatever its state. Workers may write the
file. It journals `blocked_settings_write` with `{tool, path}`, plus the redacted
`command` for Bash. Rows written before this change also carry `item_ids`. Other
settings files stay editable.
Shawn's own edits and "always allow" clicks are not tool calls and stay
unaffected.

## Item fields

| Field | Meaning |
|---|---|
| `repo` | the item's remit repo path, set by `add-item --repo` |
| `waiting_on.permission` | the proposal the item waits on |
| `permission_block` | `{cause, detail, at, proposals}`, the item's latest explanation |
| `permission_scan` | `{<session id>: byte offset}`, how far each session's transcript has been read |

`cause` is one of `proposal`, `decided`, `not_proposable`, `ineligible`,
`no_repo`, `bad_destination`, `unknown_cause`, `verify_covered`,
`verify_not_covered`, `verify_blocked_elsewhere`, or a settled state.

## Known limits

- Workers run as the same user. A process that writes rows into its own
  transcript can fake a refusal or a run. The pick check has the same
  limit. The Bash part of the settings guard is a text match that such a process
  can get around.
- Claude Code also writes `settings.local.json`, and shares no lock with Auto. The
  merge reads and then replaces the file, so a write between those steps can be
  lost. The second verify detects a lost rule: the proposal stays `open`. It cannot
  detect a lost rule of Claude Code's own.
- If the journal commit fails after the write, the rule is in the file with no
  record. The next allow finds it covered and writes nothing.
- Whether a running session picks up a new rule without a restart was not tested.
  A worker that is still refused settles as `ineffective` or `retry_unobserved`.
- A session started outside herdr has no session registry row, so it has no
  transcript path. Its refusals are never read, and it can never take a retry.
- A refusal in the PM's own session is never read, because the PM's session is
  not on any item.
- The classifier's rejection shape in the transcript was not observed live.
  Programme assumes `reasonType: "classifier"`, the value an observed classifier
  approval carries. If a classifier refusal carries another value, it maps to
  layer `unknown` and gets an explanation, not a proposal.
- Programme does not track whether an applied rule is later removed. A later
  refusal shows as a decision for Shawn and changes nothing else.
