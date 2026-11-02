# Programme behaviours format

A behaviour is Shawn's standing guidance on how the PM and its workers do the work: when a situation holds, what to do and not do, which skills, tools and agents to prefer, what shows it was followed, and when to stop. It carries no authority and no done bar. Who decides stays with the agreement's terms, corrections and the protocol's autonomy levels; acceptance stays with the protocol's deliverables and evidence bar. `lib/programme_behaviours.py` checks, stores and resolves behaviours. This document is the format it enforces. The verbs that write behaviours are in agent-tool-surface.md ("Behaviours").

## 1. Layers

| Layer | Where it lives | Reach |
| --- | --- | --- |
| programme | the programme block's `behaviours` list (run-record-schema.md §10.5) | one programme |
| repo | the behaviours store, under `repos.<repo key>` | every programme whose remit holds that repo |
| personal | the behaviours store, under `personal` | every programme |

- The repo key is the repo's GitHub `owner/name`, else its normalised path, the same key the carry-over store uses.
- The behaviours store is one JSON file per machine, `behaviours.json` in the folder of the personal protocol file. The env var `CLAUDE_AUTO_BEHAVIOURS_STORE` replaces the path (tests use it). It syncs between Shawn's machines with the personal protocol. It is not in any repo, so other people on a repo do not see its repo layer.
- When two behaviours in force disagree, the narrower layer wins: programme over repo over personal (section 6).
- A programme record without `behaviours` reads as an empty list.

## 2. Store file

```json
{
  "format": 1,
  "personal": [ /* behaviour entries, section 3, each with adoption */ ],
  "repos": { "<repo key>": [ /* behaviour entries with layer repo and that repo_key */ ] }
}
```

- A missing file reads as empty. This is not an error.
- A file that cannot be read, is not JSON, or has a `personal` that is not a list or a `repos` that is not an object of lists is refused. Readers report it as a notice and load no stored behaviours; writers refuse and leave the file as it is.
- A `format` above 1 refuses every write.
- Writes hold the lock `.behaviours.lock` in the programmes folder, read the file inside the lock, and replace it in one atomic rename. A new entry replaces any entry with the same id on either stored layer.

## 3. Entry

| Field | Type | Check |
| --- | --- | --- |
| `id` | string | Required. `^[a-z][a-z0-9-]*$`; the verbs mint `b` plus 6 hex digits. |
| `layer` | string | Required. `programme`, `repo` or `personal`. |
| `when` | object | Required. `{text, checks?, trigger?}`. `text` is Shawn's plain-words situation, not empty. `trigger` is `claim`, `merge`, `block` or `start`: the item change after which the behaviour applies. A missing trigger reads as `claim` for the due list, except that a behaviour that applies to the PM only and has no trigger is never listed as due; any other value is rejected as `bad_value when.trigger`. Each check is `{text, by}`, with `by` either `pm` (the PM tests it from what the sweep sees) or `agent` (the agent doing the work judges it). |
| `applies_to` | string | Required. `pm`, `workers` or `both`. |
| `do`, `dont`, `skills`, `tools`, `agents`, `formats`, `comms` | list of strings | Each line not empty. At least one `do` or `dont` line is required. |
| `evidence` | string | What shows the behaviour was followed. Never a condition of acceptance. |
| `stop` | string | When the agent gives up on the situation's work and reports to Shawn. |
| `why` | string | Not empty when present. |
| `examples` | object | `{good?, bad?}`, each a non-empty string. |
| `source` | object | `{prompt_id?, quote?}`: Shawn's typed prompt and its redacted text. |
| `state` | string | `active` (the default when absent), `proposed` or `retired`. |
| `overrides` | list of ids | Behaviours this one beats (section 6). |
| `relates_to` | list of refs | Behaviours and contract parts Shawn or the PM linked at record time (section 10). A ref is a behaviour id, or `term:<key>`, `tool:<id>`, `ruling:<id>`, `authority:<action>` or `done:<deliverable>`. |
| `unrelated` | list of `{id, reason}` | Listed items marked as not applying, each with a non-empty reason. |
| `repo_key` | string | Required on the repo layer; refused on any other layer. |
| `moved_to`, `moved_repo_key` | string | Programme layer only (section 7). `moved_to` is `repo` or `personal`; `moved_repo_key` is required exactly when `moved_to` is `repo`. |
| `history` | list | Events, each `{event, at, prompt_id?, ...}`: `recorded`, `proposed`, `moved`, `kept`, `retired`, `undone`. |
| `at` | string | ISO time the entry was drafted. |
| `adoption` | object | Repo and personal layers only (section 5). Refused on a programme entry. |

Any other key rejects the entry (`unknown_key`). A field of the wrong type gives `bad_value`; a missing required field gives `missing_field`.

A behaviour has no decision kind, no item list and no autonomy level, so nothing in it can widen what the PM or a worker may decide.

## 4. Protected escalations

A `do`, `skills`, `tools` or `agents` line that names a protected escalation rejects the entry (`protected_escalation`, with the escalation kind as detail): production deploys, releases, spend over cap, merging around the gate, refused permissions. The words come from `PROTECTED_STEMS` and `PROTECTED_WORDS` in `lib/programme_terms.py`. A stem counts only where a word starts, so "reproduction" does not match "production" while "deployed" matches "deploy". The risk-or-cost-limit and settled-human-choice kinds are not checked, because limits are enforced in code and a behaviour carries no authority.

`when`, `dont`, `stop`, `evidence`, `why` and `examples` are not scanned: stop conditions and "don't" lines need words such as "cost", "limit" and "publish".

## 5. Adoption and load

Every repo or personal entry carries an adoption block in the protocol's format (programme-protocol-format.md §4): `machine`, `run_id`, `prompt_id`, `quote`, `prompt_hash` and `hash`. Its target is `behaviour:personal:<id>` or `behaviour:repo:<repo key>:<id>`. Each write to the store journals one `rule_adopted` row with that target and the entry's hash, after the programme record commits.

When the store loads, each entry is checked in this order. The first failure rejects that entry only, with the reason:

1. The entry passes section 3 and section 4.
2. Its `layer` matches the list it sits in (`wrong_layer`), and a repo entry's `repo_key` matches its key (`wrong_key`).
3. Its adoption verifies like a personal protocol entry: on this machine, the cited prompt is typed, its hash matches and the journal holds the approval (`adoption_unverified`, `adoption_malformed`, `not_adopted`). An entry adopted on another of Shawn's machines loads on its own hash, because a behaviour carries no authority and the file syncs between his machines.

A rejected entry is reported, never delivered. A programme entry that fails section 3 or 4, or whose layer is not `programme`, is rejected the same way.

## 6. Resolution

For one item, the behaviours in force are built in this order:

1. Programme entries, less any copy that has moved to a stored layer whose verified copy serves this item (section 7).
2. Repo entries under the item's repo key.
3. Personal entries.

Then entries that are not `active` drop out, every entry named in another candidate's `overrides` drops out, and an audience filter keeps the entries whose `applies_to` is the audience or `both`.

`overrides` is set when the PM names a conflict (`record-behaviour --conflicts-with <id>`): the new programme entry overrides the other one, because the narrower layer wins. Shawn's typed reply can undo the new entry instead. A move or keep keeps only links to a strictly broader layer (a repo entry may override a personal one; a personal entry overrides nothing) and reports the dropped links as `dropped_overrides`, so the PM can raise the conflict again.

## 7. Moves

- A move out of the programme marks the programme entry `moved_to: repo|personal` (with `moved_repo_key` for repo) instead of deleting it. The store write runs after the programme record commits.
- The programme copy stays in force until the store holds a verified entry with the same id under that layer, so a failed store write never loses a behaviour.
- A copy moved to one repo hides only for items in that repo. Items in the programme's other repos, and items with no repo, keep the programme copy.
- A move reads the store before it commits, so an unreadable store refuses the move and changes nothing.
- A move back to the programme writes the programme copy first and removes the stored copy after the commit, so a failed removal leaves both copies.
- At programme end, `keep-behaviours` copies named programme entries to the repo or personal layer the same way.

## 8. Delivery

- A worker's brief carries a "Behaviours this work follows:" block: one line per worker behaviour in force for the item (id, when, do, don't, evidence and the checks the worker judges). A behaviour with no checks or with an agent check joins by itself. One gated only by PM checks joins only when the PM names it with `start-worker --behaviour <id>`, because code cannot test a PM check.
- `remind-behaviour` sends one behaviour to an item's worker later, with reason `relevant` or `sent_back`.
- Each delivery is recorded on the item in `behaviour_deliveries` (run-record-schema.md §10.5). A `brief` delivery does not stop a later reminder; the PM skips a behaviour on an item only when that item already has a `relevant` or `sent_back` delivery for it. `P status --json` shows each behaviour's PM checks, agent checks, evidence, stop and per-item deliveries under `contract.behaviours`.
- A send-back needs the behaviour to have started before the item passed its trigger (the first claim, the first confirmed merge, or the first wait or hand). A behaviour's start is its last `recorded`, `moved` or `kept` history event, else `at`, because a move or keep is when it began reaching other items. A behaviour that started at or after the trigger, or at an unknown time, reaches the work as a reminder only.

## 9. Rejection reasons

`unknown_key`, `missing_field`, `bad_value`, `protected_escalation`, `wrong_layer`, `wrong_key`, and the adoption reasons of programme-protocol-format.md §4 (`not_adopted`, `adoption_malformed`, `adoption_unverified`).

## 10. The record-time check

`record-behaviour` and the read-only `check-behaviour` compare a new behaviour with the behaviours in force and with the programme contract. The check informs. It never refuses to record, changes no Ruling or Authority level, and gives the behaviour no authority.

**Behaviours.** A behaviour is compared only when both can apply to one item: their audiences intersect, and they are not in different repos. A listed behaviour carries the reasons that listed it, from this closed set:

| Reason | Fires when |
| --- | --- |
| `same_trigger` | both set the same `when.trigger` |
| `shared_when` | the two `when` texts share two or more content words |
| `instruction_touches_situation` | one `when` text and the other's `do` and `dont` lines share two or more content words |
| `shared_tool` | both name the same tool, skill or agent |
| `equal_do_dont` | a `do` line of one equals a `dont` line of the other, ignoring case and punctuation |
| `tool_forbidden_in_dont` | one names a tool that a `dont` line of the other forbids |

One shared word is not a reason: on the stored behaviours it was noise in 43 of 48 listed pairs. `equal_do_dont` and `tool_forbidden_in_dont` also set `flag: may_contradict` on the row. `check-behaviour` also takes `--from-proposal <id>` and `--conflicts-with`, so the PM can check a proposal before applying it, and adds each listed behaviour's `do`, `dont` and `stop` lines as `lines`, so the PM can judge what code cannot. `record-behaviour` leaves `lines` out because it journals what it returns.

**Contract.** The check reads the `rules_in_force` snapshot and lists the parts the behaviour touches:

| Ref | Part | Listed when | `may_contradict` when |
| --- | --- | --- | --- |
| `term:cadence`, `term:remit` | agreement terms | a word starts with sweep, cadence or wake (cadence), or with remit (remit) | never |
| `term:stop_rule` | agreement term | the behaviour sets `stop` | `stop` shares two or more content words with the stop rule |
| `term:tools_of_record` | agreement term | the behaviour names a tool of record | never |
| `tool:<id>` | preferred tool | the behaviour names a tool in the preferred-tool text | a negation word (not, never, avoid, dont, no) comes before the tool name in the same clause |
| `ruling:<id>` | Ruling | a `do` line names the Ruling's decision kind | the Ruling's effect is `restrict` |
| `authority:<action>` | Authority level | a `do` line names the action and its level is stricter than `act` | always, once listed |
| `done:<deliverable>` | Done standards | a `do` or `dont` line names the deliverable; one row lists every standard that requires it | a `do` clause skips it (skip, without, ignore, omit); a `dont` line never flags |

The operating contract line applies to every behaviour, so it is read but never listed. A protected escalation in a `do`, skill, tool or agent line is still refused (section 4).

**Answers.** `--relates-to <ref>` and `--unrelated <ref>=<reason>` store `relates_to` and `unrelated` on the entry. A ref must be a behaviour in force or a part of the contract. Each listed row carries `answered`, and the output counts the unanswered ones as `unanswered`. It also names the reasons it checked and says that opposite meaning is not detected, because a short list is not a pass.
