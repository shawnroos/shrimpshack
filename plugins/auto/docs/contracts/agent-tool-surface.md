# Agent Tool Surface

The contract a driving agent operates `/auto` through. It exists to kill the
per-session orientation tax (R6/R7): an agent should read this once, or fetch the
machine-readable mirror on demand, instead of re-deriving how to drive auto from
~2000 lines of skill prose every session.

The machine-readable mirror is `python3 lib/run_record.py describe` — one JSON object
carrying the same contract. `tests/unit/run-record.test.sh` asserts set-equality
between the CLI's actual verbs and what `describe` documents, so the two cannot
drift: a verb added without a `describe` entry fails CI.

## The one rule

**Read freely. Write only through a verb that revalidates under the lock and can
reject.**

- Reads are lock-free (atomic-rename snapshot). Read the run-record at
  `<repo>/.claude/auto/<run-id>.json` as often as you like; never re-derive its
  state from anything else.
- Every write commits through a verb that performs precondition-check + mutate +
  predicate-recompute inside a single `_with_locked_run_record` call
  (`lib/run_record_core.py`). The model never holds the lock, and never does a
  read-then-write split across two invocations.

## Why the write rule is not distrust of the agent

It is compare-and-set for slow deciders. An agent decides against a snapshot it
read a minute ago; by the time its write lands, a concurrent sub-agent may have
moved the same step. Both agents reasoned correctly — this is a *timing* problem,
not a judgment one, and no amount of agent intelligence prevents it (two people
editing the same doc offline clobber each other the same way).

The verb closes the window: it re-checks the precondition *inside* the flock and
raises (`InvalidTransition`, `StaleVerdict`, `RunRecordError`) rather than merging a
decision made against stale state. A superseded verdict is rejected, and the
agent re-reads and retries. That is how the runtime absorbs minutes-latency agent
decisions without lost updates. The steering verbs live in `lib/run_record_steering.py`.

The wall is around one unsafe *mechanism* (raw read-modify-write, or holding the
lock across model thinking time), never around the agent's *access*. The rule
exists to protect the agent's own work from being silently lost.

## Verbs

Run `python3 lib/run_record.py describe` for the authoritative list with argument
shapes and per-verb rejection modes. In brief:

- **Read / inspect** (no mutation): `read`, `path`, `is-orphaned`, `describe`.
- **State change**: `transition` (grammar-checked step state change — rejects any
  edge not in `ALLOWED_TRANSITIONS`; will not write findings, use `record-verdict`).
- **Verdict feedback**: `record-verdict` (rejects a stale-attempt verdict),
  `set-gaps-open`, `set-enumerated-steps`, `set-verdict-decision`,
  `record-spawned-agent` (append a spawned agent-id to a step so a died agent is
  auditable against it for reap — U9).
- **Steering** (reshape a live run): `init` (create a run — rejects an existing
  run-id), `add-step` (rejects a duplicate id or an unknown dependency),
  `reshape-deps` (rejects a cycle), `force-skip` (requires a reason — R20; cannot
  bury an existing finding — R16), `register-session` (join the PreToolUse
  ownership set — R21), `set-retry-budget` (per-run retry budget the driver owns —
  `should_escalate` honors it), `set-stall-threshold` (per-step stall threshold the
  stall clock reads).
- **Task-run evidence**: `check-deliverable` (the run's driving session runs the
  checker for one deliverable against one reference and stores confirmed, refuted
  or unknown in the run's opaque task_evidence block; refused for any other session;
  never takes a result as an argument), `evidence-journal` (reads the checks journaled
  under .claude/auto/journal/). The exit predicate never reads this evidence, so a
  task run finishes exactly as it would without it.

This table is fenced by `tests/unit/doc-fence-agent-tool-surface.test.sh`: it
derives the verb set from `describe` (hence from `_VERBS`) and fails if any verb
is not named here. The set-equality test in `tests/unit/run-record.test.sh` binds
`describe` ↔ `_VERBS`; the fence extends that binding to this prose, so a renamed
or added verb cannot silently leave the contract stale.

**Not in this surface:** `lib/workflows.py migrate` (and its revert) are *operator*
utilities for upgrading a workflow file on disk — deliberately kept out of
`_VERBS`/`describe` so the locked, set-equality-enforced agent verb surface stays
the set of verbs an agent actually drives a run with.

## Programme verbs

A programme's agreement, instructions and protocol rules change only through
`python3 lib/programme.py <verb>` (shim: `lib/programme.sh`). Run
`python3 lib/programme.py describe` for argument shapes and rejection modes. The
programme is found by `--run <id>`, or else by the lease that names the caller's
session.

- **Read**: `describe`; `rules` prints the rules in force (agreement terms, adopted
  protocol rules, active instructions), rebuilt from the run record and wrapped in
  an `<auto-rules>` tag as data, followed by the restored context (decisions,
  requirements, binding pauses and denials, pending questions, assignments,
  uncertain actions) from the recovery packet, wrapped in an `<auto-context>` tag
  with its store revision and context digest. SessionStart, the compact refusal and
  `takeover` print the same block. `rules --ack [--context <digest>]` clears the
  compact flag `<home>/.compact-flag` and prints the block again. The flag records
  the context digest when it was set (by PreCompact, or by `handover` for the new
  driver); an ack whose digest is older than the committed context refuses, prints
  the current block and rebinds the flag to it. An ack accepts nothing.
  `inbox` (add `--all` for every claim) prints the unread worker claims from the store with their index,
  for `mark-read --offset <n>`; `claims.jsonl` is only an export.
- **Status**: `status [<run>|--run <id>] [--json]` prints the working model: what
  the PM is doing now, its queue, what it watches and why, who waits on whom,
  decisions for Shawn, what it just did, the rules in force, and each item with its
  deliverables, evidence, owner pane, session state and marks (new, stopped
  unwatched). It also shows ended apart from done, and for an ended programme the
  resources still owed, the dispositions, and whether it is archived or which
  archive checks last failed. For an active programme whose view file is missing,
  `status` rebuilds it; a held authority prints the hold and writes nothing. Any session may run it; it
  writes nothing. Every write through the shared write path then rebuilds the same
  model into `<home>/views/view.json` (mode 0600), which the programme-view mod
  draws. A failed rebuild prints `view refresh failed` on stderr and never fails
  the write. `claim` changes only the claims, so a new claim shows in the view at
  the next write or `status`. With `--terms` (or the bare word terms, as
  `/auto:programme-status terms` sends it) it prints only the terms page: project
  terms, each decision-log entry under the term it used
  (silent ones under "no term"), and the 20 most recent term changes with their
  source and redacted quote; `--json` then emits `{run, generated_at, terms, rows}`.
  Viewing never counts as approval.
- **Storage**: a programme keeps its record, journal and claims in
  `<home>/programme.db`, and each write commits the record change and its journal
  entry together. `<home>/.claude/auto/<run>.json` (tagged `projection_of_revision`),
  `journal.jsonl` and `claims.jsonl` are exports rebuilt after each commit; nothing
  reads them back as state, and a raw write to one is refused or, from an older
  auto, recorded as `foreign_write_absorbed` at the next write. A programme made
  by an auto that predates the database stays on its JSON files until `promote`
  imports it (`--run <id>`); a prompt imported that way approves nothing new.
  `reconcile-leases` rewrites a run's leases from its committed remit and driving
  session. Every write verb except `claim` and the verbs below takes `--op <id>`:
  a retry with the same id replays the committed result instead of writing
  again. `claim`, the lifecycle verbs (`start`, `takeover`, `handover`, `end`,
  `expire`), `promote`, `reconcile-leases`, `reconcile-operations`,
  `release-resources`, `create-successor` and `sweep` keep no operation id and
  refuse `--op`.
- **Agreement**: `propose-agreement` sets proposed term values before acceptance;
  `accept-agreement` records the acceptance; `amend-term` changes one term. A term
  value must be one of that term's options. Wording that fits no option is an
  instruction. The tools_of_record term holds the sweep sources that stay on: a comma
  list of tracker, tasks and plans (default all three), or none. Its amend needs
  a typed prompt that names each source it turns on or off ("no plans" counts).
  A source turned off is never read by the sweep, never watched, and never holds
  the stop. A record from older code reads its old name for this term as
  `tools_of_record`.
- **Term proposals and notes**: `propose-term` stores one proposal on a term
  (with --seconds for a fixed cadence, --add server.workspace for a new remit
  space, or --add with --description for a new tool of record). It needs no prompt
  and never changes the value; a new proposal replaces the old one.
  `clear-proposal` removes it. `note-term` adds a note for Shawn, and its --clear
  removes the notes. These three are allowed while the compact flag is set, never
  count as a beat, and take --origin ui as a display label. `amend-term` and
  `set-remit` settle a pending proposal: accepted when the new value matches it,
  else superseded. The rules in force never carry a proposal.
- **Setup picks**: before acceptance, `pick-term` (`<key> <value> --pick <id>`) sets one
  per-programme agreement term from a picker answer Shawn gave in the driving session.
  It takes `--pick`, not `--prompt`: the cited prompt must resolve to origin picked,
  exactly one of its questions must name the term (and no other term), and that
  answer must name the value (for a list term, exactly the value's options and no
  other). `take-recommendations` (`--pick <id>`) needs a pick whose answer names
  "take all recommendations" without a negation; it sets every per-programme term to its
  pending proposal, else its current value, in one write. Both record `set_by` shawn,
  origin picked, the question and the answer, and cite the pick. One picker answer
  (one transcript and tool use) approves one write, however many prompt rows cite it.
  Both refuse after acceptance, and refuse autonomy, rulings, reserved areas and
  shared settings: those stay typed. A refusal journals `approval_refused`. A typed
  accept must come after the last pick. No typed gate accepts a picked prompt.
- **Setup walkthrough notes**: `setup-step` (`<name>`) records the step the PM asks now,
  `setup-seen` (`--json <file>|-`) records what the source probe saw (tabs, repos and
  tracker lists of strings, and a required items list, empty when there is nothing
  to adopt; the items step stays open until it is recorded), and `setup-keep` (`<step>`) marks a step
  done with its current value (never the accept step). They need no prompt, are allowed
  while the compact flag is set and never count as a beat.
- **Re-read requests**: `request-reread` asks the PM to re-read the rules in force
  at its next sweep. It needs no prompt, leaves the compact flag as it is, never
  counts as a beat, and takes --origin ui as a display label.
- **Project terms**: `propose-agreement --project-term "<area>=<text>"` adds a
  free-text project term, such as a preferred tool, with `--source <evidence>`; a
  term without `--source` is refused, and so is a second term for an area that has
  one. Project terms sit beside the fixed terms, never inside them. Who decides an
  area is a Ruling, not a project term. A term whose area or text names a
  protected escalation (production deploys, releases, spend over cap, merge around
  the gate, refused permissions, risk or cost limits, settled human decisions) is
  refused: no project term gives one of these to the PM or a worker. Before
  acceptance, `edit-project-term <id> <text>` replaces the text (and with
  `--source`, the source) with no history, and journals `project_term_edited`.
  After acceptance it needs a typed `--prompt` that names the area and the new
  text, keeps the previous value in the term's history list, and journals
  `project_term_amended`. A reserved term from an older record reads as a
  kind-less legacy restrict Ruling carrying its area: `edit-project-term` refuses
  it, the gate never reads it, and the rules block asks Shawn to record it again
  as a Ruling with a kind. A project term is text in the run record: it never
  changes a permission setting or a protocol layer file, and a preferred tool it
  names is not a permission.
- **Contract stamp**: `accept-agreement` writes `contract_version` beside the
  acceptance; no other verb writes it, and an agreement without it keeps the old
  rule that every product question goes to Shawn. It refuses a prompt that the
  journal holds before the last `agreement_proposed` or `project_term_edited`
  line, or before the last `remit_set` line that pre-filled a carried-over term,
  so Shawn accepts the terms he last saw.
- **Carry-over store**: one JSON file per machine beside the personal protocol
  (`CLAUDE_AUTO_CARRYOVER_STORE` overrides the path) keeps entries for the next
  programme on a project, under each remit repo's key (its GitHub owner/name, or
  its path when it has none) or under "all". Each entry carries an adoption block
  like the personal protocol's and one `rule_adopted` approval record. When
  `set-remit` stores repos on an agreement that is not yet accepted, it adds a
  project term for each verified entry under each remit repo's key and under
  "all", one per area, with the repo key ahead of "all", each marked with its
  origin key. It drops an entry whose adoption does not verify on this machine
  and prints a notice naming the entry. An accepted programme never reads the
  store.
- **Old instructions**: a programme record written before Rulings keeps its
  instructions, and each reads as a kind-less legacy Ruling with the effect
  decided, under the instruction's id. A Ruling already stored under that id wins.
  The gate never reads a kind-less Ruling, `record-ruling` refuses to revise one,
  and `close-ruling` closes one with a typed prompt naming it.
- **Rules**: `propose-rule` stores a rule in the protocol rule format as a
  proposal; `adopt-rule` writes it to the personal protocol layer atomically, with
  an adoption record (machine, run, prompt id, redacted quote, prompt hash, content
  hash). `adopt-autonomy` sets one autonomy level (a level wider than the plugin
  default needs `--widening`), and `adopt-check` sets one `verified.lookup` or
  `verified.deployed_sha` command for a repo, the same way. Each journals a
  `rule_adopted` approval record naming the entry kind, its target and its hash;
  the protocol loader loads a same-machine entry only when that record exists.
- **Items**: `add-item` adds an item with a `source:key` id, or updates one. It
  stores the protocol match for its change kinds (matched rules, and each required
  deliverable with result unknown) and the owning pane and session. `alias-item`
  gives an item a new id and keeps the old one as an alias; when the new id
  already exists, the two items merge. `merge-item` folds one item into another.
  A merge combines sessions, aliases, linked task runs and evidence (confirmed
  evidence wins), and moves queue, watcher and proposed-rule
  references to the surviving id; a Ruling or old instruction naming the old id
  resolves to the surviving item when it is read. `drop-item` needs `--reason`, and a typed
  `--prompt` when the item is issue-backed (its source is not herdr) and has an
  open deliverable. `reopen-item` reopens a dropped item and always needs a
  typed `--prompt`. No verb sets an item to done: done is derived from confirmed
  evidence.
- **Decisions and acceptance**: decision records written before Rulings stay in
  the same store as kind-less revisions; Shawn's decisions are now decided
  Rulings. `define-requirement` links a requirement to item checks (`<item-id>=<deliverable>`,
  a deliverable the protocol requires of that item). `assign-item` binds an item to
  the decision revision in force, compared by canonical id. `raise-blocker` gates a
  requirement only when it names the requirement, one of its checks, the dependency
  item, evidence and the unblock condition; `clear-blocker` clears it. `context`
  (any session, read-only) prints the decisions, requirements and acceptance, or
  with `--item` the item's packet, with the store revision it read; context is never
  approval. `status` shows each requirement as satisfied, unsatisfied, blocked or
  not accepted, with each check's result (confirmed, refuted, unknown, not_run,
  stale or missing), the follow-ups no requirement gates on, and completed, handed,
  dropped, decided and open items apart. Acceptance never changes the stop rule.
- **Rulings**: `record-ruling` keeps one of Shawn's orders or decisions as
  numbered revisions in the same store, with a decision kind, an effect
  (decided is Shawn's own call, grant hands the kind to the PM for the named
  items, restrict pulls it back to Shawn), limits, an optional `--until` end
  date and Shawn's words. A typed `--prompt` that names the id makes it active;
  without one it waits for `accept-context`. A revision that gives the PM more
  power (a grant that adds items, drops a limit or ends later; a restrict that
  loses items, drops a limit or ends sooner) waits for an `accept-context`
  prompt naming each item it adds, while the prior revision stays in force. A
  grant records the Authority level for its kind when it becomes active, and a
  narrowing revision keeps it. A grant or decided Ruling of a protected kind is
  refused. Changing a decided Ruling needs a typed prompt naming it.
  `--replies-to <ask-or-decision-id>` records a casual correction: the anchor
  gives the item and kind, the typed prompt must come after the anchor, and the
  Ruling applies at once with a one-line notice. A Ruling past its end date
  reads as expired. `close-ruling` closes one: as fulfilled it needs `--why`;
  as withdrawn, or closing a restrict or decided Ruling, needs a typed prompt
  naming it.
- **Safety pauses and denials**: `pause` (`--risk safety|data_loss`) holds named
  items or the whole programme, notifies Shawn, holds the stop, and makes
  `start-worker` and `prompt-item` refuse what it holds; `lift-pause` needs a typed
  prompt naming it. `record-denial` keeps a tool's refusal; the same action on that
  item then refuses, and requirements stay unchanged.
- **Waits and watchers**: `set-waiting` sets who an item waits on, with an
  optional named reporter, a watcher (process or task id), the blocker kind and a
  trace or job id; `--clear` returns the item to open. `--blocker` needs
  `--serves` (the requirement or required check it serves), `--evidence` (of
  the dependency) and `--unblocks-when` (the condition that removes it), and
  the refusal names each missing one. `--safety` marks a safety or data-loss
  pause and drops that need. `--safety` or any of the three without
  `--blocker` is refused. `watcher-beat` updates a
  watcher's heartbeat, and registers a new watcher when given a process or task
  id. A beat for an unknown watcher without an id is refused. `watcher-beat` is
  not journaled. Both take `--kind cron|monitor` to record the watcher kind; a
  task id with no kind counts as cron when a prompt is given and as a Monitor
  otherwise.
- **Handing**: `hand-item` hands an item to Shawn with a question and a required
  `--kind <decision-kind>`. Kind `denied_operation` also needs `--operation <operation>`
  (one word, for example git-push), and `--operation` goes with no other kind. A
  `denied_operation` ask for an operation that already has an open ask on any
  item is refused, so a denial reaches Shawn once. It notifies
  once: the tracker's needs-you mark for an issue item, else a herdr
  notification. The ask gets an id ("a" + 6 hex) and carries the decision kind;
  the `item_handed` entry records the ask id, the kind as `ask_kind`, and the
  operation of a denied-operation ask in its op field. After the hand commits, an
  `effects_recorded` journal entry records both exit statuses as tracker and
  herdr (null when not run or not found, "skipped" for the tracker on an item
  with no issue). `answer-handed`
  needs a typed `--prompt` and `--choice ship|decline`. Ship reopens the item with
  the deliverables its change kinds imply (or the change kinds passed with
  `--kind`); decline drops it. Either way it records a Shawn decision linked to
  the ask id, with the ask's decision kind (unknown for an ask handed before
  kinds existed).
- **Decision log**: `log-decision <item|programme> --kind <decision-kind>
  (--term <id> | --silent) --why <text>` appends a PM decision to the decision
  log (`programme.decisions`), which is separate from the Rulings kept under
  `programme.context`. An entry has an id ("d" + 6
  hex), the decision kind, the term it used or silent when no term covered it,
  and why. It journals `pm_decided`. The decision kinds are a closed list in
  `lib/programme_decisions.py`: the plugin autonomy actions plus
  technical_approach, work_sequencing, worker_coordination, tool_choice,
  optimisation_depth, product_scope, acceptance and denied_operation. Any other
  kind is refused. On an item that matched the product-question rule,
  `log-decision` needs an agreement with the contract stamp; it then closes
  the item as decided, which counts as finished, or re-matches the item's
  other change kinds and leaves it open. Without the stamp it refuses and the
  item still goes to Shawn through `hand-item`. `accept-agreement` also records
  a Shawn decision of kind agreement.
- **Permission proposals**: `propose-permission` takes `--item <id>`,
  repeatable; with none it reads every unfinished item. It reads the item
  sessions' transcripts (paths from the session registry) for refusals ruled
  since each session joined the item, and turns each mode or classifier refusal
  of an eligible read into one shared proposal per destination (the main
  checkout's `.claude/settings.local.json`, from the item's recorded repo) for a
  native allow rule from the read-only catalog. A deny-rule or hook refusal, or
  one whose layer is unknown, gets an explanation instead.
  A new need folds into the open proposal for that destination and notifies
  again only when its operations grew; operations a postponed, rejected or
  decided proposal already holds attach as evidence with no notification. An
  item with no recorded repo, a destination outside the remit, an ineligible
  command, or (when named) no readable refusal gets an explanation instead. `notified_at` is
  stored only after the herdr notifier exits 0, and every call re-sends open
  proposals not yet notified. Programme never writes a settings file.
  `answer-permission` takes
  a proposal id, one of applied, not-now or no, and `--prompt <id>`: a typed
  prompt from the driving session that names the proposal id, says exactly one
  answer (applied or apply; not now, later or postpone; reject or decline), is
  newer than the proposal's last state change, and that no earlier answer
  cited. not-now and no postpone or reject an open, ineffective or
  retry_unobserved proposal; on a postponed or rejected one they record the
  answer and keep the state; while retrying they are recorded and applied after
  the outcome. applied reads three settings files read-only (user
  `~/.claude/settings.json`, the main checkout's `.claude/settings.local.json`,
  and each blocked session's worktree `.claude/settings.json` from the session
  registry's cwd) and keeps only the permission lists and
  `autoMode.classifyAllShell`. Any linked command still blocked by a deny or ask
  rule, or by classifyAllShell, makes the proposal ineffective; any uncovered
  command keeps it open; only when every command is covered does it reserve one
  retry on the oldest linked item whose owner pane has a live agent, and return
  `retry_item` and `retry_text` for `prompt-item`. With no live owner pane it
  becomes retry_unobserved. applied while retrying changes nothing, and applied
  on a resolved proposal is refused. Every result says managed settings and a
  `--settings` flag are not visible.
- **Permission settlement**: `settle-permissions` (driving session) reads the
  reserved session's transcript after the reservation for a Bash call with the
  reserved operation and target (extra pipes or `--json` fields still count).
  The runtime's `permissionDecision` decides: accept resolves the proposal and
  returns its waiting items to open; reject makes it ineffective with the
  diagnosed layer. With no such call, an idle or gone owner pane after the
  retry was sent gives retry_unobserved. An open proposal resolves with
  `confirmed: false`, and shows as a decision for Shawn with its covering rule,
  when an affected session's transcript shows every operation ran after its
  denial. It never retries; only a new typed applied arms one more attempt. A
  later denial on a resolved proposal attaches as evidence and shows as a
  decision for Shawn, with no state change and no notification.
- **Worker inbox**: `claim --run <id> --item <id> --deliverable <name> --ref <ref>`
  commits one structured claim, exported to `<home>/claims.jsonl`. Free text and a
  reference with spaces are refused, and a claim never changes evidence. `mark-read`
  moves the programme's inbox read offset to the claim count, or to `--offset`.
- **Retained results**: `collect-result --item <id> --attempt <token> --source <path>
  --root <dir>` copies one text result into the home's immutable object area and
  commits its digest, so the result stays readable after the worker's source is
  removed. The source must be a regular file inside `--root`, not reached through
  a symlink, at most 8 MB, and pass privacy admission before any byte is written.
  A refusal is recorded with its code and retains nothing. It works after `end`
  and refuses once the home is sealed. A retained result or source copy is never
  approval and never changes evidence.
- **Preserved code**: `preserve-code` (`--source <worktree> [--extra <rev>]...
  [--ignored <path>]...`) keeps a worker worktree recoverable without it: a
  self-contained git bundle of HEAD, its reflogs and the index blobs, the index
  entries (all stages), and the worktree and untracked bytes git does not hold.
  Git runs with no hooks, filters, fsmonitor, user config or network, and the
  source is never written. A fresh repository rebuilt from the retained copy
  alone must match the frozen inventory before the receipt is complete.
  Secret-bearing history or bytes, submodules, LFS payloads, alternates, partial
  clones, shallow history, git lock files or a source that changes during capture
  refuse it. `--check` says whether the receipt still covers the source as it is
  now; it deletes nothing, and a receipt is never deletion approval.
- **External actions and recovery**: `start-worker` and `prompt-item` commit an
  admission (the target, the owner epoch and a digest of the request) before
  spinoff or herdr runs, re-read authority just before the call, and commit the
  receipt after it. An admission whose outcome is unknown stays uncertain: a
  later start or prompt on that item refuses unless it names the attempt with
  `--despite`, and the attempt stays open either way. A launch is never retried
  just because its agent is missing. `reconcile-operations` (the current driving
  session, also after `end`) settles an admitted launch when a live agent reports
  its minted session; a prompt has no delivery receipt, so it stays uncertain.
  A receipt that arrives after end or a handover is kept on the operation and
  changes no ownership. `recover` (any session, read-only) prints the replacement
  PM's packet from one committed revision: pending decisions, decisions with their
  reasons and binding limits, requirements and acceptance, open actions, retained
  results, evidence limits, uncertain actions, and holds. Long text is cut in the
  packet and comes back in full with `recover --get <id>`. A held authority prints
  a hold and exits 1; a missing retained result holds its item and refuses
  dispatch for it. `--rebuild-projections` rewrites only the exports and the
  view. The packet is context, never approval.
- **End, archive and successor**: `end` commits the stop fence together with
  what the programme still owes (its leases, watchers and worker sessions); new
  work, late claims and old watchers' beats refuse from then on. The closure
  verbs run in the driving session or the session that ended it, with `--run`:
  `release-resources` removes leftover lease files, probes watcher process ids
  and worker sessions without stopping anything, and records a receipt for each
  (`--watcher <id> --stopped|--denied` reports a TaskStop or CronDelete); a live
  or unreadable one stays unconfirmed. `dispose-item` records how unfinished work
  stopped (`stopped_unfinished` or `handed_over`) and confirms no requirement.
  `dispose-action --attempt <id>|--resource <id>` records a human's acceptance of
  an uncertainty from a typed prompt that names it (`origin_verified` true only
  when the transcript shows Shawn typed it; any other prompt is refused); the
  action is never recorded as completed. After end the prompt hook still journals
  prompts typed in the closing session into each unsealed programme it closes.
  `check-archive` (read-only) lists the named checks with their remedies, or the
  sealed manifest. `archive` checks one capture revision, publishes a candidate
  manifest, then seals in one commit on that revision while every home writer is
  held out; any failed check leaves the programme ended and unarchived, and a
  write after the capture supersedes the candidate. A retry returns the one seal.
  A sealed home is read-only: every write, export, view refresh, prune and import
  refuses, and reads use a read-only connection; a sealed database with an
  interrupted journal is a hold that is never repaired in place. `create-successor
  <run>` starts a new programme linked to the sealed manifest; its agreement waits
  for acceptance and the archive is never written. Nothing deletes retained data.
- **Working model and sources**: `set-now` records what the PM is doing now;
  `queue` adds a next action (a worker start is action start_worker with
  `--item`) or removes one; `record-tested-build` stores the tested build's
  shasum on an item for the released check; `set-source` records a source
  (herdr, tracker, tasks or plans) going unavailable or coming back, or with
  `--unsupported` as one this machine cannot read, which never holds the stop.
  `--provider <name>` (tracker only) records the provider that answered; a
  tracker that goes down loses its provider. Any other source name is refused.
- **Tracker writes**: the PM writes the tracker itself through the Linear MCP
  tools (skill programme-tracker), and records what it reported.
  `tracker-synced` (`--item <id> --state <label> [--note <text>]`) stores the last
  label the PM reported on the item's issue (`tracker_synced` on the item, a
  `tracker_synced` history entry, journaled). The same label again changes
  nothing and is not journaled; `--check` only prints due, true when the
  label differs from the stored one. `record-issues` reads a JSON list of
  issues on stdin (key, title, state, state_type, state_id, url), keeps the
  ones whose key is an issue key (at most 200, the rest counted as dropped),
  sanitises them (with project and initiatives) into `recorded_issues`, and
  sets the tracker available with provider linear-mcp unless another provider
  has it available. It is the read path when the board and the API key both
  fail; the watcher never reads through the MCP, and a sweep that cannot read
  the tracker leaves a linear-mcp tracker available. The recorded check never
  reads `recorded_issues`.
- **Trajectories**: `record-trajectories` reads a JSON list on stdin, one entry per
  open item: `{item, done, current, planned, finish, location}`, where a step is
  `{title, clause}` and a clause is `term:<key>`, `rule:<id>`, `instruction:<id>`
  or null. It stores each entry on the item as its trajectory and moves
  `trajectory_sweeps` to the previous and latest call times. A clause that is not
  in the rules in force is stored as null with an `unknown_clause` note, never
  refused. An entry for an unknown, done, handed or dropped item is skipped with a
  reason and the rest are stored; input over 1 MB is refused whole, and `[]`
  writes nothing. Only an item whose step path changed under the same driving
  session gets a `trajectory_changed` journal row; moving the current step to
  done is not a change, and neither is a first recording.
- **Evidence**: `check-deliverable` (args: item, deliverable, optional --ref,
  optional --repo <clone> for the verified and released checks; the path is
  stored and reused by `validate`)
  runs that deliverable's checker and stores confirmed, refuted or unknown with
  the parsed fields. No verb takes a result as an argument. The reference is
  --ref, else the newest claim for that deliverable, else the stored one, else the
  issue key in a linear item id. The merged check reads gh pr view and a GraphQL
  read of the review threads and the merged head's checks; the recorded check
  reads the Linear issue (through the board's issue read when that works, else
  GraphQL with LINEAR_API_KEY from the secrets file, filters inside the query). A
  checker that did not run, timed out, was truncated or could not be parsed gives
  unknown, and unknown never becomes confirmed. Each child gets a minimal
  environment and at most one credential, through its environment; kept output is
  scrubbed. Two unknown results in a row set the item waiting on the system, with
  a retry watcher named retry-<item> and a queued arm_retry_watcher action.
  `validate` re-runs checks for confirmed evidence older than one cadence on open
  items and on items done less than 7 days ago; a refutation reopens the item and
  journals evidence_refuted. An unknown re-check keeps the evidence. Flagged
  evidence is frozen once its item is done, and evidence on an item done 7 days or
  more is final.
- **Sweep and workers**: `sweep` reads the remit's workspaces from one bounded
  herdr snapshot (behind a status probe), the session registry checked against
  that snapshot, and three sources. The tracker is the issue tracker, read
  through an ordered provider chain (today the herdr-linear-board snapshot, then
  the Linear API with LINEAR_API_KEY); the first provider that answers wins and
  the output names it as provider, with each provider tried and its reason.
  Tasks are the Claude Code task lists of the remit's sessions (pane owners and
  open items' owners), read from the tasks folder (CLAUDE_AUTO_TASKS_DIR
  overrides it); a missing or emptied list is an empty list, not an outage. Each
  pane carries its owner's counts by status and the in-progress task as now.
  Plans are the plan docs changed in the last 7 days in each pane's repo
  (docs/plans, or the plans folder under a docs_root set in
  .compound-engineering/config.yaml inside the repo), with path, title and the
  issue ids they name; file count and bytes per plan are capped. It prints
  panes, issues, tasks, plans, proposals and a state with a reason for each
  source; a source that could not be read gives no list, never an empty one,
  and a source the tools_of_record term turns off reports state off and is not read. A
  pane's owner is the snapshot's reported agent session first, then a registry
  line for the same pane and terminal. Issues are found in the tracker's pane
  bindings and the pane's branch, title, label and registry name, and last in
  the pane's repo plans when they name exactly one issue the tracker knows (or
  one issue at all when no tracker answered). Shells with no agent, a driver's
  pane and a tracker pane are skipped, never proposed. `sweep` writes nothing
  unless given `--record-sources`, which records through set-source each source
  whose state or tracker provider changed, and each source seen for the first
  time; the start flow runs it once so the first sweep starts from the probed
  states. `start-worker` (item, then spinoff arguments after
  `--`) mints a session id, runs spinoff with `--session-id`, and checks the agent list for
  the new agent, because spinoff can exit 0 with a bare shell. The item records
  every start; a verified start also sets the owner's pane, terminal and
  session. `prompt-item` (item, then text) sends through herdr agent prompt to
  the item's recorded pane only. Right before sending it reads a fresh snapshot
  and refuses a driver's pane or a tracker pane, a pane whose terminal changed, a
  pane with no live agent, and a pane whose reported session is not the item's
  owner. Refusals and sends are journaled; a pane with no reported or
  registered session is sent to and marked session unknown.
- **Decision links and restrictions**: `start-worker` and `prompt-item` take
  `--decision <id>` (repeatable) and `--restriction <text> --source
  <human|runtime|requirement|pm_choice|worker_assumption>` (repeatable). Each
  decision id must name a decision-log entry or a decision record with an
  accepted revision; the verb appends the log entry's text, or the record's
  `decision:<id>@<rev>` with its scope, reason and limits, and the
  clause "Proceed under this decision. Do not reopen it: if you find new
  evidence that it cannot hold, stop and state that evidence in your pane."
  `start-worker` with a decision or restriction needs `--handoff <file>` among
  the spinoff arguments, appends to a copy under `<programme home>/briefs/` and
  passes the copy; the original is unchanged. `prompt-item` refuses when its
  text plus the appended block exceeds 4000 characters. Unknown ids, bad
  sources and the cap refuse before anything is sent. A successful start or
  send records the restrictions on the item.
- **Remit**: `set-remit` stores the remit the PM worked out (skill
  programme-remit): spaces, repos (absolute path and GitHub owner/name) and
  the tracker scope (team keys, projects, initiatives, each with name and id).
  It reads JSON on stdin, refuses a bad shape or a list over its cap, keeps a
  part it was not given, and journals remit_set. Before the agreement is
  accepted it needs no prompt; after, it needs a typed prompt that names each
  space, repo, team, project or initiative added or removed. Adding a space
  takes its lease under the leases lock; removing one releases it; a space
  another programme holds is refused. Code never discovers or resolves remit
  names. An empty part sets no limit. The sweep skips a worker pane whose repo
  is outside the repos (repo_out_of_remit) or whose issues are all outside the
  team, project or initiative scope (issue_out_of_remit, or project_unknown
  when no source gave the project), and lists in-scope issues from the board
  and recorded issues that no pane names and no item holds as unstaffed (at
  most 20, never adopted). Plans are read in every remit repo. The merged check
  is unknown for a PR whose repo is not a remit repo's GitHub name.
- **Lifecycle**: `start` takes the remit lease for the caller's herdr space (or
  each `--space`) before anything else, creates the programme home and journals
  programme_started. It is refused while a space's lease is live, orphaned or
  newer, and the error names the holding run and session. `takeover`, `handover
  <session-id>` and `end` act only on a request that the prompt hook journaled
  from the caller's own session, and each request is used once. `takeover`
  needs a live or orphaned lease and a typed takeover request journaled since the
  last start, takeover or handover, and one of: the
  lease is orphaned and the request was typed while it was; herdr proves the
  driving session gone (the newest registry pane it ran in, found by terminal and
  then by pane id, is missing from a readable
  snapshot, or now reports another session or terminal, and no pane reports the
  driving session); or the typed request text says `--replace <name>` where the
  name is the driver's pane label, pane id or session id. herdr unreadable, no
  registry pane, a headless driver, another herdr server, or an open pane that
  reports no session is not proof. A refusal on a live driver names its pane and
  tab and gives the `--replace` line to type. `--replace` on the verb itself
  authorizes nothing.
  `handover` runs in the driving session and needs a typed handover request that
  names the new session and cites its prompt. `end` needs a typed end request in
  the driving session, or an orphaned lease. Takeover and handover rewrite every
  lease of the run and the record's `driving_session_id` together (leases lock,
  then run-record lock), stamp the driver beat, and journal both session ids.
  Takeover prints the rules in force and the waits and watchers to re-arm. `end`
  releases the leases, sets the run to done (shown as ended) and prints the cron
  task ids to remove with CronDelete and the Monitor task ids to stop with
  TaskStop; programme_ended carries both lists. A `takeover` that finds the lease expired
  ends the programme the same way: it refreshes the view and prints the same
  CronDelete lines before it refuses. Refusals are journaled as request_refused.
- **Driver beat**: `beat` stamps the programme's driver beat; every other
  driving-session write stamps it too, so a working PM keeps its lease live.
- **Journal pruning**: `python3 lib/programme_journal.py prune --run <id>` drops
  captured prompts older than 7 days that no journal line cites. The sweep runs
  it first.
- **Wake watcher** (`lib/programme-watch.sh`, not a verb): remit mode
  `programme-watch.sh [--run <id>] [--tracker] [--max-polls <n>]` beats the remit
  watcher each interval and prints one line when the remit changes
  (remit-changed, claim, wait-due, tracker-changed, tasks-changed,
  plans-changed or source-available), naming the source. Tasks (a status or
  count change in a remit session's list) and plans (a new or edited plan file
  in a remit repo) are local reads and always watched; --tracker polls the
  tracker providers that need no token. A source the tools_of_record term turns off is
  never polled. It exits 0 after printing; it prints "source-unavailable <name> <reason>" once and keeps
  polling. Item mode `programme-watch.sh [--run <id>] --item <id> -- <argv>`
  beats that item's watcher while the command runs, then prints
  "item-exited <id> exit=N". Exit codes: 0 change or quiet exit, 1 runtime error
  or 3 refused beats, 2 usage. Settings: `CLAUDE_AUTO_WATCH_INTERVAL_SECONDS`
  (default 30), `CLAUDE_AUTO_PROGRAMME_CLI`.
  `expire` ends a programme whose agreement stayed unaccepted past one cadence,
  with reason agreement_unaccepted, and otherwise does nothing. `beat` stamps the
  driver beat that keeps the lease live; the sweep runs it each time, because a
  beat older than two cadence periods reads as orphaned.

Text from outside the PM (titles, reasons, questions, references) passes through
the sanitizer in lib/programme_sanitize.py: control and escape sequences are
stripped and the length is capped. Item ids are checked as `source:key` with no
`..`, spaces or control text, and are never used as a path.

Every write verb:

1. runs only in the driving session: `CLAUDE_CODE_SESSION_ID` must equal the
   record's `driving_session_id`; `agent_session_ids` never count. `claim` is
   the exception: any session may call it, and it names the programme with
   `--run`; `collect-result` is open to any session in the same way;
   `recover --rebuild-projections` rewrites only exports and the view, from any
   session; the closure verbs (`release-resources`, `dispose-item`,
   `dispose-action`, `archive`) also accept the session that ended the programme,
   and `create-successor` runs from the session that will drive the successor;
2. refuses while the compact flag exists and prints the rules-in-force block,
   except `rules --ack`, `claim`, `collect-result`, `watcher-beat`, `beat`,
   `tracker-synced --check`, `reconcile-operations` (which settles admitted
   actions and starts none) and the closure verbs, which never start work;
3. revalidates under the run-record lock, then journals after the write commits.

The approval verbs (accepting the agreement, amending a term, amending a project
term after acceptance, recording an
instruction, withdrawing one, adopting a rule, an autonomy level or a check
command, answering a handed item,
reopening a dropped item, and dropping an issue-backed item with an open
deliverable) need `--prompt <id>` naming a
prompt that the prompt hook journaled as typed in the driving session. The verb
copies the quote from the journal, never from its own arguments, and its journal
entry cites the prompt so pruning keeps it.

The cited prompt must also name what it approves. Each name must appear in the
redacted prompt text as whole words, case ignored, and not right after "not",
"never", "no" or a "n't" word; "merge pr" names merge_pr, but "AI-801" does not
name AI-80 and "act and tell" does not name the level act (programme-protocol-format.md
gives the full rule). The text must contain: for `amend-term`, the term key and the new value; for `adopt-rule`,
the rule id; for `adopt-autonomy`, the action and the level; for `adopt-check`,
the repo and the check key (for example `verified.lookup`); for `answer-handed`,
`drop-item` and `reopen-item`, the item id or its key (for example `AI-753`).
With `--widening`, the text must also contain "widen", "widening" or "widened". A prompt that does not
name them is refused, and the refusal lists the missing words.
For `edit-project-term` after acceptance, the text must contain the term's area and
its new text. `accept-agreement` accepts any typed prompt, because the quote is what it records; `accept-agreement`
also needs the prompt to come after the last proposal or project-term edit.

The action hook guards each driver's pane. In a session that is not the driving
session of a live, orphaned or expired lease, it denies any Bash command whose
text names a driver's pane id or terminal id as a whole token, after `$'..'`
segments are decoded as bash does (`\xHH`, octal, `\uHHHH`), a `$` before a double
quote is dropped, and quote characters and backslashes are removed, however herdr is invoked, and journals
`blocked_driver_send`. A herdr send call that the hook can parse is also denied
when its target is a driver's pane, in every session, the driving one included.

The same hook guards the tracker against proof written by the PM. On a Linear
MCP tool call (a tool whose server name contains "linear") from the driving
session of a live, orphaned or expired lease of a programme that has not ended,
it denies the call, with a one-line reason, and journals `blocked_tracker_write`
when the input:

- sets a done state: a state, stateId, status, stateType or type
  value named Done, Completed, Complete, Canceled, Cancelled, Duplicate or
  Closed (any case), or naming the type completed or canceled;
- names a state that `recorded_issues` shows with a completed or canceled type;
- names a state id (a UUID) that `recorded_issues` does not show as an open
  state, or gives state or stateId as something other than a string;
- sets duplicateOf;
- has a body or comment that matches the recorded check's root-cause pattern,
  or one that is not a string.

It also denies a write outside the remit's tracker scope: when the remit names
teams, an issueId or issue (or an id on save_issue) whose key prefix is not a
remit team, an issue given by UUID, and a new issue whose team is not a remit
team by key, name or id; when the remit names projects or initiatives, an issue
whose recorded project is outside them.

Other sessions, sessions that drive no programme, and every other field
(an issue description included) are not checked.

The same hook guards the files permission proposals target. For the driving
session and for sessions on unfinished items, it denies a Write, Edit, MultiEdit
or Bash call that names the `.claude/settings.local.json` of any proposal's
destination, and journals `blocked_settings_write`. The Bash check is a text
match. Other settings files are not checked (programme-permission-proposals.md).

The pane guard and the prompt binding stop accidents and casual misuse. A
determined process running as the same user can still append journal rows or
type into the pane by means the hook cannot see. The text check does not see:
a pane id built at run time (a shell variable such as `${P}p1` or `$HERDR_PANE_ID`,
command substitution such as `$(cat file)`, brace expansion, or an id read from a
file or the environment); the short pane id behind an indirect herdr call
(`h=herdr; $h pane send-text p1`); a script file or another language that builds
the command; an agent addressed by its name; and a raw shell outside Claude Code.

This section is fenced by the same test as the run-record verbs: it derives the
set from `lib/programme.py describe` and fails if any verb is missing here, or if
this section names a verb that does not dispatch.

## Phase model

`describe` publishes the loop's phase model so an agent orients to phases without
the skill corpus. Phases run in the workflow's `phase_order`; the default order is
`plan` → `handoff` → `work`, with `work` the terminal phase. The **current** phase
is the run-record's `loop_phase` — never `phase_order[0]`, which is only the start
phase. When a phase's predicate is met and it is not the terminal phase, the engine
advances to the next phase; at the terminal phase the run can exit. For a live run,
`describe <run>` overlays THIS run's `phase_order` and current-phase next-action
onto the static surface above.

## What stays deterministic

The agent supplies judgment; the correctness spine stays mechanism. The run-record's
single-lock read-modify-write-recompute (I-1), its state grammar (I-2), attempt
identity, the exit predicate, and the Stop-hook block decision are not agent-
operable and never become so. The agent decides *what* to do; the verbs guarantee
the decision is recorded legally and losslessly.
