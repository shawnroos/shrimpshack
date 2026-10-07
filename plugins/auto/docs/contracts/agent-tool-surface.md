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
  hash).
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
instruction, withdrawing one, adopting a rule, answering a handed item,
reopening a dropped item, and dropping an issue-backed item with an open
deliverable) need `--prompt <id>` naming a
prompt that the prompt hook journaled as typed in the driving session. The verb
copies the quote from the journal, never from its own arguments, and its journal
entry cites the prompt so pruning keeps it.

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
