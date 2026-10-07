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
  an `<auto-rules>` tag as data. `rules --ack` clears the compact flag
  `<home>/.compact-flag` and prints the block again.
- **Status**: `status [<run>|--run <id>] [--json]` prints the working model: what
  the PM is doing now, its queue, what it watches and why, who waits on whom,
  decisions for Shawn, what it just did, the rules in force, and each item with its
  deliverables, evidence, owner pane, session state and marks (new, stopped
  unwatched). It also shows ended apart from done. Any session may run it; it
  writes nothing. Every write through the shared write path then rebuilds the same
  model into `<home>/views/view.json` (mode 0600), which the programme-view mod
  draws. A failed rebuild prints `view refresh failed` on stderr and never fails
  the write. `claim` writes only `claims.jsonl`, so a new claim shows at the next
  write or `status`.
- **Agreement**: `propose-agreement` sets proposed term values before acceptance;
  `accept-agreement` records the acceptance; `amend-term` changes one term. A term
  value must be one of that term's options. Wording that fits no option is an
  instruction.
- **Instructions**: `record-instruction` records the cited words, what they apply
  to (the programme or one item), and until when; `close-instruction` marks one
  fulfilled (needs `--why`) or withdrawn (needs `--prompt`).
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
  evidence wins), and moves queue, watcher, instruction and proposed-rule
  references to the surviving id. `drop-item` needs `--reason`, and a typed
  `--prompt` when the item is issue-backed (its source is not herdr) and has an
  open deliverable. `reopen-item` reopens a dropped item and always needs a
  typed `--prompt`. No verb sets an item to done: done is derived from confirmed
  evidence.
- **Waits and watchers**: `set-waiting` sets who an item waits on, with an
  optional named reporter, a watcher (process or task id), the blocker kind and a
  trace or job id; `--clear` returns the item to open. `watcher-beat` updates a
  watcher's heartbeat, and registers a new watcher when given a process or task
  id. A beat for an unknown watcher without an id is refused. `watcher-beat` is
  not journaled.
- **Handing**: `hand-item` hands an item to Shawn with a question and notifies
  once: the board's needs-you mark for a Linear item, else a herdr notification.
  Its journal entry records both exit statuses (null when not run or not found,
  "skipped" for the board on an item with no Linear issue). `answer-handed`
  needs a typed `--prompt` and `--choice ship|decline`. Ship reopens the item with
  the deliverables its change kinds imply (or the kinds passed with `--kind`);
  decline drops it.
- **Worker inbox**: `claim --run <id> --item <id> --deliverable <name> --ref <ref>`
  appends one structured claim to `<home>/claims.jsonl`. Free text and a
  reference with spaces are refused, and a claim never changes evidence. `mark-read`
  moves the programme's inbox read offset to the claim count, or to `--offset`.
- **Working model and sources**: `set-now` records what the PM is doing now;
  `queue` adds a next action (a worker start is action start_worker with
  `--item`) or removes one; `record-tested-build` stores the tested build's
  shasum on an item for the released check; `set-source` records a source
  (herdr, board or linear) going unavailable or coming back.
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
  that snapshot, and the board snapshot, falling back to Linear read directly.
  It prints panes, issues, proposals and an unavailable flag with a reason for
  each source; a source that could not be read gives no list, never an empty
  one. A pane's owner is the snapshot's reported agent session first, then a
  registry line for the same pane and terminal. Issues are found in the pane's
  branch, title, label, registry name and board bindings. Shells with no agent,
  a driver's pane and the board's pane are skipped, never proposed. `sweep`
  writes nothing unless given `--record-sources`, which records source changes
  through set-source. `start-worker` (item, then spinoff arguments after
  `--`) mints a session id, runs spinoff with `--session-id`, and checks the agent list for
  the new agent, because spinoff can exit 0 with a bare shell. The item records
  every start; a verified start also sets the owner's pane, terminal and
  session. `prompt-item` (item, then text) sends through herdr agent prompt to
  the item's recorded pane only. Right before sending it reads a fresh snapshot
  and refuses a driver's or the board's pane, a pane whose terminal changed, a
  pane with no live agent, and a pane whose reported session is not the item's
  owner. Refusals and sends are journaled; a pane with no reported or
  registered session is sent to and marked session unknown.
- **Lifecycle**: `start` takes the remit lease for the caller's herdr space (or
  each `--space`) before anything else, creates the programme home and journals
  programme_started. It is refused while a space's lease is live, orphaned or
  newer, and the error names the holding run and session. `takeover`, `handover
  <session-id>` and `end` act only on a request that the prompt hook journaled
  from the caller's own session, and each request is used once. `takeover` needs
  an orphaned lease and a typed takeover request made while it was orphaned.
  `handover` runs in the driving session and needs a typed handover request that
  names the new session and cites its prompt. `end` needs a typed end request in
  the driving session, or an orphaned lease. Takeover and handover rewrite every
  lease of the run and the record's `driving_session_id` together (leases lock,
  then run-record lock), stamp the driver beat, and journal both session ids.
  Takeover prints the rules in force and the waits and watchers to re-arm. `end`
  releases the leases, sets the run to done (shown as ended) and prints the cron
  task ids to remove with CronDelete. A `takeover` that finds the lease expired
  ends the programme the same way: it refreshes the view and prints the same
  CronDelete lines before it refuses. Refusals are journaled as request_refused.
- **Driver beat**: `beat` stamps the programme's driver beat; every other
  driving-session write stamps it too, so a working PM keeps its lease live.
- **Journal pruning**: `python3 lib/programme_journal.py prune --run <id>` drops
  captured prompts older than 7 days that no journal line cites. The sweep runs
  it first.
- **Wake watcher** (`lib/programme-watch.sh`, not a verb): remit mode
  `programme-watch.sh [--run <id>] [--linear] [--max-polls <n>]` beats the remit
  watcher each interval and prints one line when the remit changes
  (remit-changed, claim, wait-due, linear-changed or source-available),
  then exits 0; it prints "source-unavailable <name> <reason>" once and keeps
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
   `--run`;
2. refuses while the compact flag exists and prints the rules-in-force block,
   except `rules --ack`, `claim` and `watcher-beat`;
3. revalidates under the run-record lock, then journals after the write commits.

The approval verbs (accepting the agreement, amending a term, recording an
instruction, withdrawing one, adopting a rule, an autonomy level or a check
command, answering a handed item,
reopening a dropped item, and dropping an issue-backed item with an open
deliverable) need `--prompt <id>` naming a
prompt that the prompt hook journaled as typed in the driving session. The verb
copies the quote from the journal, never from its own arguments, and its journal
entry cites the prompt so pruning keeps it.

The cited prompt must also name what it approves. After separators
(`_ - . : /` and spaces) are removed and case is ignored, the redacted prompt text
must contain: for `amend-term`, the term key and the new value; for `adopt-rule`,
the rule id; for `adopt-autonomy`, the action and the level; for `adopt-check`,
the repo and the check key (for example `verified.lookup`); for `answer-handed`,
`drop-item` and `reopen-item`, the item id or its key (for example `AI-753`).
With `--widening`, the text must also contain the word "widen". A prompt that does not
name them is refused, and the refusal lists the missing words.
`accept-agreement`, `record-instruction` and `close-instruction --as withdrawn`
accept any typed prompt, because the quote is what they record.

The action hook guards each driver's pane. In a session that is not the driving
session of a live, orphaned or expired lease, it denies any Bash command whose
text, with quote characters and backslashes removed, names a driver's pane id or
terminal id as a whole token, however herdr is invoked, and journals
`blocked_driver_send`. A herdr send call that the hook can parse is also denied
when its target is a driver's pane, in every session, the driving one included.

The pane guard and the prompt binding stop accidents and casual misuse. A
determined process running as the same user can still append journal rows or
type into the pane by means the hook cannot see, such as a raw shell outside
Claude Code.

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
