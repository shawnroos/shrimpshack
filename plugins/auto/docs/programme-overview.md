---
authors: Claude
type: overview
project: auto
topics:
  - programme
  - agents
  - evidence
  - approval
---

# Programme: features and operating model

Programme directs work across coding agents in a Herdr space. One Claude Code session acts as the product manager, or PM.

The PM maintains the work list, directs workers, examines evidence, and requests human decisions. Workers perform the individual tasks.

Programme directs several pieces of work across spaces and repositories. An Auto task run directs the steps of one plan.

This document describes the repository on 18 October 2026, plus the approval fix merged on 19 October 2026 in PR #110. Later changes are not described here: crash-safe storage and archive (PR #113), the PM operating contract (PR #111), permission proposals (PR #114), and the interactive view (PR #112).

## The operating model

```text
Human
  │ approves the agreement and reserved decisions
  ▼
PM session
  ├── reads the work sources
  ├── directs worker sessions
  ├── runs checks against worker claims
  └── maintains the programme record
          │
          ├── next action → continue the work
          ├── external wait → record a watcher or reporter
          ├── human decision → request an answer
          └── stop conditions satisfied → permit the PM to stop
```

The programme record exists outside the conversation. The PM reads this record after a restart or context compaction.

### Main terms

| Term | Meaning |
|---|---|
| Programme | The record for work under one agreement. |
| Remit | The spaces, repositories, and tracker scope that the PM directs. |
| Agreement | The approved terms for the programme. |
| Item | One piece of work in the programme. |
| Deliverable | One required result for an item. |
| Claim | A worker report that a deliverable is complete. |
| Evidence | The result from a check against a claim. |
| Lease | The record that identifies the PM session for a space. |
| Watcher | A process or scheduled prompt that reports a change or requests another sweep. |
| Sweep | One pass through the programme rules and work sources. |

## 1. An approved agreement defines the work

Programme starts with proposed terms and a remit. The human approves these before the PM accepts the agreement.

The remit separates three types of scope:

| Scope | What it names |
|---|---|
| Spaces | The Herdr spaces under the programme. |
| Repositories | The repositories inside the remit. |
| Tracker | The teams, projects, and initiatives inside the remit. |

The sweep uses these limits when it proposes work. An empty scope section means no limit for that section.

Tracker guards enforce team limits and restrict writes that establish completion. They do not independently enforce every project or initiative limit.

The agreement also defines the work sources, cadence, and other terms. The human changes these through typed instructions.

After acceptance, a change to the remit requires approval that names the affected scope.

## 2. One PM directs the workers

The lease identifies the driving session. Programme commands reject changes from a session without the required authority.

| Actor | Responsibility |
|---|---|
| Human | Approves the agreement and decisions that require human authority. |
| PM | Selects the next action, directs workers, records waits, and requests checks. |
| Worker | Performs assigned work and submits claims. |
| Checker | Examines a deliverable and records evidence. |

The checker is verification code that the PM runs against a source system. Its caller does not supply the verdict.

The claims interface accepts a claim from any session. A claim alone does not establish completion.

Programme records the pane and session for an item. Worker prompts use that recorded address instead of the focused terminal.

Lifecycle commands support handover, takeover, and an explicit end:

| Command | Required authority |
|---|---|
| Handover | The driving session supplies a human request that names the next session. |
| Takeover | A new session supplies a human request for an orphaned lease. |
| End | The driving session supplies a human request. Another session supplies one when the lease is orphaned. An expired lease needs no request. |

A missing heartbeat or an old heartbeat makes a lease orphaned. This state does not prove that the old process stopped.

An unaccepted agreement expires after one cadence. The expiry path ends that programme without approval.

An explicit end releases leases without completing the remaining work. The next PM session re-arms watchers after handover or takeover.

## 3. The PM reads work from several sources

A sweep reads the active sources and compares their records with the remit.

| Source | Information |
|---|---|
| Herdr | Panes, sessions, repositories, and visible issue references. |
| Tracker | Issues and their recorded state. |
| Tasks | Task lists from sessions inside the remit. |
| Plans | Recent plan documents in repositories inside the remit. |

The PM examines proposals before adoption. An open tracker issue alone does not require the PM to start another worker.

Programme distinguishes an unavailable source from an unsupported source. A source outside the agreement remains off.

This distinction prevents an unsupported source from keeping the programme active without a possible next action.

## 4. Claims require evidence

```text
Worker submits a claim
          │
          ▼
Checker examines the deliverable
          │
          ├── confirmed → record completion
          ├── unknown → keep the deliverable open
          └── refuted → keep or reopen the deliverable
```

Checks examine the result required by the deliverable:

| Deliverable | What the checker examines |
|---|---|
| `merged` | GitHub merge state, commit references, checks, and review threads. |
| `flagged` | LaunchDarkly values: false in production; true in stage and development. |
| `verified` | Approved commands, a runtime lookup, and the deployed build that contains the merged commit. |
| `released` | The npm package against the recorded tested build, plus a Braintrust experiment or an active waiver. |
| `recorded` | A completed Linear issue with a root-cause comment from a person. |

Default rules select deliverables by change kind. A shared package requires release evidence; a code fix requires verification evidence.

These checks have defined limits. A nonempty runtime lookup does not prove every user-visible behavior. An experiment record does not prove evaluation quality.

Programme records evidence against the relevant item. Later validation examines evidence that became stale.

A refuted validation reopens the item. An unknown validation records uncertainty without removing the earlier confirmation.

The worker claim remains separate from evidence, even when the worker reports a successful command.

## 5. Completion and permission to stop are separate

Programme exposes two different results: `done` and `may_stop`.

| Result | Question |
|---|---|
| `done` | Does every item have a finished state: evidence-confirmed, handed to the human, or dropped? |
| `may_stop` | Does the configured stop rule permit the PM to stop this turn? |

A handed question counts toward `done` before the human answers. An empty programme also reports `done`.

Thus, `done` does not prove that every change shipped or every question received an answer.

| Stop rule | Behavior |
|---|---|
| `nothing_it_can_act_on` | The default rule examines open work, actions, claims, waits, rules, blockers, and source availability. |
| `only_when_done` | The rule uses `done` directly. |
| `never_stop` | The rule refuses permission to stop. |
| `until_time` | The rule refuses before its deadline, then applies the default checklist. |

Under the default rule, a recorded watcher or reporter gives an external wait a return path.

The Stop hook holds the PM when the selected rule refuses permission. An explicit end permits stopping without completing the remaining items.

## 6. Watchers return external changes to the PM

Programme supports several return paths:

| Return path | Purpose |
|---|---|
| Monitor | Reports changes from a process, check, or watcher. |
| Cron prompt | Requests a sweep at the agreed cadence. |
| Named reporter | Identifies the person who reports the result of a wait. |
| Retry watcher | Repeats a recorded check for an item. |

A watcher result requests attention. It does not approve an action.

The PM records watcher identifiers with waits. The remit watcher detects duplicate remit watchers, reports a change, and exits.

The PM re-arms the remit watcher after a sweep. A cron prompt provides a separate scheduled return path.

Two consecutive unknown checks create a wait and queue a retry watcher. The PM arms that watcher; the queue entry alone starts no process.

## 7. Rules control actions and human decisions

Programme stores rules and instructions with the work record. The PM reads the applicable rules before further action after context compaction.

Autonomy levels distinguish forbidden actions, proposals, actions with a report, and actions without a separate approval request.

The human approves changes to these levels. Wider authority requires explicit approval for the wider level.

| Mechanism | Responsibility |
|---|---|
| Code checks | Enforce approval source, adoption, session ownership, evidence, compaction acknowledgement, and selected tracker writes. |
| PM instructions | Direct priorities, dependencies, and several merge checks. |
| Human decisions | Set scope and authority; answer reserved product questions. |

Autonomy settings do not provide a general sandbox around every command. The PM still follows the applicable instructions.

Priority instructions put consent and safety first. They then address blockers on the human review, shared worker blockers, test failures, and polish.

The PM records dependencies through queued actions and watched waits. Programme has no built-in dependency graph or automatic upstream gate.

When an item needs a human decision, the PM records a question against that item. The answer cites a typed prompt.

Approval checks also require the relevant target. A valid human prompt does not approve every later action.

### Approval source

PR #110, merged on 19 October 2026, makes Programme verify the source of each approving prompt.

| Input | Approval behavior |
|---|---|
| Supported human input with matching source evidence | Proceeds to the existing checks for the action. |
| Registered cron prompt | Refuses approval. |
| Background notification or worker message without human evidence | Refuses approval. |
| Missing, changed, or unsupported source evidence | Refuses approval. |
| Older `typed` record without source evidence | Refuses approval. |

The hook records the transcript position and hashes for each prompt occurrence. Later approval reads the matching source after that position.

This prevents an automated event from borrowing an older human prompt with the same identifier or text.

The fix uses local transcript evidence. It does not protect against an actor who rewrites all trusted local records.

Synthetic approval tests pass. In live checks, a typed approval succeeded, and SDK prompts and background notifications were refused. An accepted prompt suggestion does not count as typed input.

An installed copy of the plugin includes the fix only after it updates to a release that contains PR #110.

## 8. Persistent records support return and inspection

Programme keeps the working model, journal, claims, evidence, and lease records outside the current conversation.

The working model records the current action, queued actions, waits, worker ownership, and decisions that need human input.

The journal connects approvals and lifecycle actions to their source prompts. Rules require acknowledgement after context compaction when the session loses the applicable context.

Two views support inspection:

| View | Purpose |
|---|---|
| `/programme-view` | Displays the live working model. |
| `/auto:programme-status` | Displays a snapshot of the programme. |

## Example: a worker reports a merge

1. The worker submits a claim for the merge deliverable.
2. The PM requests the deliverable check.
3. The checker reads the external result.
4. Programme records confirmed, unknown, or refuted evidence.
5. The PM continues with the remaining deliverables or records an external wait.

A confirmed merge does not prove a deployed build or a release. Each required deliverable keeps its own evidence.

## Scope and limits

- Programme directs sessions through Herdr and the available integrations.
- Programme depends on access to the sources and commands required for each check.
- A recorded result proves only the condition that its check examines.
- Local records and transcript files form part of the trust boundary.
- The PM still makes decisions about priorities, dependencies, and ambiguous work inside the approved remit.
- Approval relies on Claude Code transcript fields that are not a documented API. If they change, approvals are refused, not granted.

## Sources

- [Programme setup](../commands/programme.md)
- [Programme sweep](../skills/programme-sweep/SKILL.md)
- [Work sequence and decisions](../skills/programme-sweep/references/sequencing.md)
- [Remit rules](../skills/programme-remit/SKILL.md)
- [Waits and watchers](../skills/programme-sweep/references/waits-and-watchers.md)
- [Default rules and deliverables](../protocol/defaults.json)
- [Deliverable checks](../lib/programme_evidence.py)
- [Completion and stop rules](../lib/programme_predicate.py)
- [Local approval-source contract](contracts/programme-prompt-source.md)

**Writing standard:** ASD-STE100. Technical terms include Programme, Herdr, Claude Code, remit, lease, claim, evidence, watcher, hook, transcript, and autonomy.
