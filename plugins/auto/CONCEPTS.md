# auto — Concepts

The canonical vocabulary for `auto`. Plain names for the machinery — a fresh reader
should get each on sight, no metaphor.

**The code speaks this vocabulary.** These are not display names layered over
different internals: the filenames, symbols, JSON keys, CLI verbs, flags, phase
strings, commands, skills, and contracts all use the terms below. There is one
vocabulary to learn, not two.

---

## The vocabulary

| Concept | Term | One line |
|---|---|---|
| the ordered set of steps a run is built from | **workflow** | The named topology — an ordered graph of steps (`a1`/`plan-build-review`, …). |
| one node of work — the slot + its wiring | **step** | An addressable slot in a workflow (its phase + `depends_on`); runs one preset. |
| what a step runs — operation + tuning | **preset** | The named, reusable config a step runs: one operation (`review`/`do_step`) + its `prompt_template` tuning. Addressable independent of any workflow. |
| a stage of a run | **phase** | plan · handoff · work (and `brainstorm` on the creative spine). |
| the pluggable toolchain | **backend** | Maps auto's operations onto a concrete toolchain — CE (`/ce-*`) or native. |
| fan-out of work to agents | **dispatcher** | Decides batch size and hands steps to agents; never writes the record itself. |
| makes the next steps | **producer** | Materializes the following steps at a phase boundary or on iterate. |
| one advance of the loop | **pulse** | The engine is a *pulsed loop*; each pulse advances the run one beat. |
| the plan→work join | **handoff** | The pause/boundary where plan output becomes work steps (`handoff_paused`). |
| the iterate / advance / exit checkpoint | **gate** | Loop again, move on, or stop — bounded. |
| a step's result | **verdict** | Carries **findings** tagged `blocker` / `major` / `minor`. |
| a step's typed done-conditions | **verification** / **criteria** | programmatic · model-judge · advisor-judge · human. |
| the durable source of truth | **run-record** | Append-through state; the run's memory. Outlives any single agent. (Identifier form: `run_record`.) |
| the objective | **goal** | What a run drives to *done*. |
| the steering session | **driver** | The agent that steers a run — distinct from the *dispatcher*, which fans work out. |
| a PM-managed collection of work | **programme** | A run kind beside task runs: a PM agent managing every **item** within a **remit**. A task run drives steps; a programme drives items. |
| the boundary of a programme | **remit** | What a programme covers — by default one herdr space. One live programme per remit. |
| one piece of work in a programme | **item** | A namespaced entry (`linear:AI-753`) with a state, owner sessions, and **deliverables** backed by PM-checked evidence. |
| a run's settled operating terms | **agreement** | Remit, stop rule, autonomy, cadence and budget — set at start, amended in plain chat, reloaded after compaction. |
| what varies per project in an agreement | **project term** | A free-text entry on the agreement, outside its fixed terms: an area, who decides it or which tool to prefer, and the evidence it came from. Once Shawn moves a tool preference into a **behaviour**, the behaviour holds it and the term no longer does. It can reserve an area for Shawn; it never gives the PM or a worker a protected escalation (production deploys, releases, spend over cap, merge around the gate, refused permissions, risk or cost limits, settled human decisions). |
| which contract an agreement was accepted under | **contract stamp** | `contract_version`, written only when the agreement is accepted. An agreement without it keeps the old rule that every product question goes to Shawn. |
| the PM's authority on a stamped agreement | **operating contract** | What the contract stamp turns on: the PM decides what the project terms cover or leave silent, records why, and brings Shawn only choices that change the outcome or acceptance, reopen a settled human decision, touch a reserved area, exceed a risk or cost limit, or need a refused permission. The rules block shows it as an `operating contract v<n>` line. |
| a scoped ruling workers are assigned under | **decision record** | `record-decision`: numbered revisions of a scope, reason, limits and the items it applies to, kept under the programme's context. A revision binds only once a typed prompt accepts it. |
| the list of calls made while a programme runs | **decision log** | `log-decision`, answered asks and the accepted agreement: who decided, the decision kind, and the project term used or silent. It records calls; it approves nothing and is not a decision record. |
| a handed decision waiting on Shawn | **pending ask** | An open `hand-item` ask, kept in the Programme view with its options, effects, do-nothing outcome, recommendation and the exact reply to type. Chat shows it only when it is new or its facts change. A typed reply approves it when it names exactly one pending ask by id, session name or title. |
| what sort of choice a decision is | **decision kind** | One of a closed list in `lib/programme_decisions.py`: the protocol's autonomy actions plus technical approach, work sequencing, worker coordination, tool choice, optimisation depth, product scope, acceptance and denied operation. `hand-item` and `log-decision` require one; an unknown kind is refused. Not the same as a change kind, which maps an item to its deliverables. |
| Shawn's typed fix to who decides | **correction** | A change to who decides one decision kind, from Shawn's typed reply to an ask or a decision the PM recorded. It applies to this project at once, with a one-line notice, and undo reverts it. While corrections are switched off, the PM records the words as an instruction. |
| which decision kinds a correction may move | **correctable kind** | The default-deny list a correction can reach: technical approach, work sequencing, worker coordination, tool choice and optimisation depth. Product scope, acceptance, reserved areas and the protected escalations are never on it. |
| corrections kept past a programme's end | **carry-over store** | A per-machine JSON file beside the personal protocol. Corrections Shawn keeps at the end are stored under each remit repo's key, or under "all" for all projects, and pre-fill the project terms of the next programme on that repo. Running programmes never read it. |
| why a worker may not do something | **restriction source** | Where a restriction in a worker's brief came from: `human`, `runtime`, `requirement`, `pm_choice` or `worker_assumption`. The PM handles each by its source: it never routes around a runtime refusal, and it may lift its own `pm_choice`. |
| standing rules across runs | **protocol** | Rules mapping a kind of change to its required deliverables, evidence bar and autonomy level; three layers (plugin, personal, project). |
| the PM's live state of mind | **working model** | Now, queue, watching, waits, decisions for the human, just did, rules in force — shown in a PM-only mod. |
| a programme's record of actions | **journal** | An append-only log beside the run-record: Shawn's prompts, items joining, evidence checked, terms amended, rules adopted, ownership changes. |
| a standing order from chat | **instruction** | Something Shawn says that is not a term change or a behaviour ("skip full eval"), recorded with his words, what it applies to, and until when. |
| how the PM and its workers do the work | **behaviour** | Shawn's standing guidance: a situation in plain words with checks the PM or the working agent tests, what to do and not do, which skills, tools and agents to prefer, what shows it was followed, and when to stop. It lives at the programme, repo or personal layer, and the narrower layer wins. It carries no authority and no done bar. Format, layers and load rules: `docs/contracts/programme-behaviours-format.md`. |
| a setup answer chosen in a picker | **picked prompt** | Shawn's answer to the PM's AskUserQuestion, verified from the session transcript. During setup it sets one per-programme setting. After that it approves one command on the pick list when its answer is that command's approval label. It approves the accept only through the accept's terms-bound approval label. It never approves a ruling, an instruction or a remit change. |
| the exact picker option that approves a command | **approval label** | "Approve " plus the command's verb and arguments, printed by `approval-label`. A pick approves only when its answer equals the label of the command being run; any other answer approves nothing. For the accept, `approval-label accept-agreement` prints `Approve accept-agreement --terms <digest>`, where the digest is a short hash of the agreement terms as `status` shows them; the accept refuses a digest that no longer matches, and an accepted suggestion never approves it. |
| a Claude Code suggested prompt Shawn accepted | **suggested prompt** | A prompt whose transcript row says `promptSource: suggestion_accepted`. It resolves to origin `suggested` and approves what a pick may approve, by its wording, never a typed-only verb. |
| the claim on a remit | **lease** | The per-space record that makes a programme the only live one in its remit. A takeover moves it. A typed takeover moves it at once when herdr shows the old PM's pane closed or running another session, after two missed cadences, or when the typed takeover names the old PM with `--replace`. With no typed request, `takeover --prompt <id>` moves it only on Shawn's pick, in that session, of the exact label naming the current PM, whether that PM is live, orphaned or gone. A typed prompt or an accepted suggestion never moves it. |
| a replaced PM going quiet | **stand down** | What a session does when another session took over the programme it drove and that PM has not stopped. `become-pm` prints step `stand-down`; the session finds its programme cron with CronList and deletes it, stops each Monitor task it started, and stops, with no message to Shawn. `become-pm` names one next step for any session Shawn asks to be the PM: start, ask Shawn by picker, already the PM, or stand down. |
| which session runs in which pane | **session registry** | A per-space log the SessionStart hook writes inside herdr: each session's id, pane, terminal and whether it is interactive. The PM reads it to know who owns a pane. |
| a worker's report of finished work | **claim** | A line a worker session adds to the programme's **inbox** (`claims.jsonl`) naming an item, a deliverable and a ref. The PM checks the evidence before it believes it; a claim alone never makes an item done. |
| when the PM may stop | **stop rule** | An agreement term: stop when nothing is left it can act on (the default), only when every item is done, at a set time, or never. Code computes "may stop" from it; the PM does not decide. |
| how far the PM may act alone | **autonomy** | An agreement term. Its one option today, `protocol`, means the protocol rules decide action by action. No code reads it before the PM queues a step. |
| how often the PM sweeps | **cadence** | An agreement term: sweep on change (the default) or on a fixed interval, with a daily eval budget and quiet hours. A lease whose heartbeat misses two cadences counts as orphaned. |
| where the PM looks for state | **tools of record** | An agreement term listing the sources the PM reads each sweep: the tracker, each session's task list, and plan files in the remit's repos. Formerly the `sources` term. |
| one PM pass over the programme | **sweep** | Prune prompts, re-check evidence, read the remit and the inbox, check claims, drive workers, record waits with watchers, update the working model, re-arm the wake-ups, then stop. |
| the PM's own check of a deliverable | **evidence** | A deliverable's result read from the source system by the PM's checker: `confirmed`, `refuted` or `unknown`, with a ref and the check time. A worker's claim is not evidence. |
| what observes a wait | **watcher** | A process or task that watches one wait and beats. It counts as live only while its heartbeat is newer than the cadence. A wait with a named reporter and no watcher still counts as covered. |
| a PM folder recorded by an older auto | **programme worktree** | A detached git worktree at `<main checkout>/worktrees/programme-<run>`, recorded on the programme as `pm_worktree` by auto 0.16.2 and earlier. auto no longer creates one, and the PM works from whatever folder its session runs in. At programme end a recorded one is removed only when nothing in it could be lost, and otherwise stays an owed resource until Shawn clears it. Not the programme's **home**, which is its data directory under the auto data dir. |
| a programme's durable state | **programme store** | `<home>/programme.db`, one SQLite file per programme. Every acknowledged change commits its state, journal row and outcome in one transaction; the JSON files are exports rebuilt from it. Not the memory store in the repo glossary. |
| a replacement PM's briefing | **recovery packet** | A revision-bound view of the agreement, decisions, requirements, actions and results that `recover` prints. It restores context and grants no approval. |
| a sealed programme | **archive** | A read-only programme record whose result and code captures were checked before sealing. Archiving does not mean every requirement passed, and it never deletes anything. |
| the follow-on to an archive | **successor** | A new programme linked to an archived one. It needs its own accepted agreement and never reopens the archive. |
| moving a programme into the store | **promotion** | The one-way move of a programme's home from plain files to the programme store. Afterwards the store is the only source of truth. |
| a change the store did not make | **foreign write** | A change found in a promoted programme's exports, such as a write from old plugin code. Appended rows are kept as a record but never count as approval; rewritten files are set aside. |
| a request to allow a refused read | **permission proposal** | The PM asks Shawn once to apply a narrow native allow rule after a worker's read is refused. It grants nothing itself; Shawn applies the rule. Not a protocol proposal, which changes completion rules. |
| an item's path through its steps | **trajectory** | Steps done, the current step, the planned steps and the finish, as the PM writes them each sweep. It belongs to the item, not the session doing it, and fades once it is older than about two sweeps. |
| the rule a step relies on | **clause** | The term, protocol rule or active instruction a step cites. A step with no clause is shown as such; that is a warning, never a block. |

## The shape in one line

> A **workflow** is an ordered set of **steps**; each step runs a **preset**.

Three levels, no word overloaded, no metaphor.

---

## Reading older code, plans, and run-records

Nine identifiers were retired when the code adopted this vocabulary. They survive in
plan documents written before the rename, in run-records and workflow files on disk,
and in anything you pulled from an older version. This table is how you read them —
it is **historical**, not a live alias list. Nothing in `lib/`, `skills/`,
`commands/`, or `docs/contracts/` spells the left column any more, and
`tests/unit/vocabulary-audit.test.sh` fails the build if it starts to.

| retired identifier | current term | where you still meet it | <!--legacy--> |
|---|---|---|---|
| `recipe` | **workflow** | `recipes/` dirs, `--recipe`, `default_adapter`-era files | <!--legacy--> |
| `unit` (U-IDs) | **step** | the `units` array of an old run-record; `add-unit`-era CLI transcripts | <!--legacy--> |
| `content` | **preset** | pre-rename branches only (never shipped a persisted key) | <!--legacy--> |
| `adapter` | **backend** | the `adapter` / `adapter_op` keys; `--adapter` | <!--legacy--> |
| `orchestrator` | **dispatcher** | `lib/orchestrator.sh` (stub); no persisted key ever existed | <!--legacy--> |
| `emitter` | **producer** | `phase_transitions[].emitter` | <!--legacy--> |
| `tick` | **pulse** | `/auto:auto-tick` in an in-flight rearm prompt; `lib/tick.sh` | <!--legacy--> |
| `seam` | **handoff** | the `"seam"` phase value and `seam_paused` | <!--legacy--> |
| `ledger` | **run-record** | `lib/ledger.py` (shim); the term throughout older plans | <!--legacy--> |

### The read-compat guarantee

**Files you already have keep working, indefinitely.** `lib/format_compat.py` maps the
retired on-disk keys and values to the current ones **in memory on every read** — it is
never version-gated and never skipped:

- **Run-records** (`.claude/auto/<run>.json`) written by pre-rename code load, resume,
  and complete unchanged. They migrate to the current shape lazily, on their first
  write, because every mutation funnels through one atomic-write path. No migration
  command, no bulk rewrite, nothing to run.
- **Workflow files** you authored resolve and validate unchanged — both in
  `.claude/auto/workflows/` and in the pre-rename directories the table above names,
  which stay readable as legacy tiers. auto never rewrites a file you wrote, so this
  acceptance has **no end date**. `python3 lib/workflows.py migrate <path>` modernizes
  one in place if you want it to — entirely optional.

The retired *code* surfaces (the forwarding stubs, the deprecated flag spellings, the
old command alias) are a different, **temporary** thing: they are deprecated and
scheduled for removal. [`docs/deprecations.md`](docs/deprecations.md) is the single
list — every one of them, what removing it would break, and the ones that can never be
removed.

---

## Deliberate carve-outs

Terms the rename left alone, on purpose:

- **`plan_step` / `PLAN_STEPS` / `next_plan_step`** — the plan phase's internal
  sub-state (`plan` → `deepen` → `review_plan`). It collides with the **step** term
  and is *not* a workflow step. Documented rather than renamed away: renaming it would
  invent vocabulary this rename had no mandate for. If the collision proves confusing
  in practice, it gets its own pass and its own entry here first.
- **`emit_*`** (`emit_templates`, `iteration_emit_count`, `expected_emit_outputs`) —
  the *producer* emits; "emit" is the verb, and was never itself a retired term.
- **The `a1` / `a2` / `a4` / `w` stems** and their legible aliases
  (`plan-build-review`, `parallel-theories`, `adversarial-pair`, `work-only`).
- **`.claude/auto/`** — keyed to the plugin name, not to any renamed concept.

## Deferred

A higher-level framing for multi-run structure, and a native **lore** runtime
(compounding best-practice + in-process worker self-heal, not delegated to a 3rd-party
solutions store), are a separate direction — captured for `/spinoff`, not part of this
vocabulary.
