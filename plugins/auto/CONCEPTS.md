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
| the boundary of a programme | **remit** | What a programme covers — by default one space, in one terminal host. One live programme per remit. |
| one piece of work in a programme | **item** | A namespaced entry (`linear:AI-753`) with a state, owner sessions, and **deliverables** backed by PM-checked evidence. |
| a programme's own settings | **agreement** | Two sections, Scope and Rulings, specific to one programme: set at start and reloaded after compaction. Scope changes by Shawn's typed messages or his picks of an approval label; Rulings change only by his typed messages. Authority and Done standards are not in it; every programme reads them live from the protocol. |
| what a programme covers | **Scope** | The agreement section holding the remit, the stop rule, cadence and budget, the sources watched (tools of record), the focus budget and the preferred tools. |
| a tool to prefer for a kind of job | **preferred tool** | A free-text Scope entry naming an existing skill or tool for a kind of job (ideation, options, requirements, implementation, optimisation, acceptance), with the evidence it came from. A preference, not a permission: it grants no access and never says who decides. Stored as `project_terms` until `propose-behaviour --from-term` moves it into a programme-layer **behaviour**, which then holds it. |
| Shawn's standing order or decision | **Ruling** | One of Shawn's dated, scoped orders or decisions, kept as numbered revisions under the programme's context: his words, a decision kind, an effect (decided is his own call, grant hands the kind to the PM for the named items, restrict pulls it back to him), the items, limits, an end date. It binds only when a prompt he typed accepts it, and a revision that gives the PM more needs a new typed prompt naming what it adds. A casual typed correction ("that didn't need me") is a Ruling that applies at once. |
| who decides each kind of choice | **Authority** | The protocol table that says, for each decision kind, whether the PM may act, act and tell, propose, or never, across the plugin, personal and project layers. It is the standing answer; a Ruling may widen or narrow it for named items until its end date. On disk it is still the protocol's `autonomy` section. |
| choices no setting can hand to the PM | **protected kind** | `prod_deploy`, `full_release`, `spend_over_cap`, `merge_around_gate` and `denied_operation`, a closed tuple in `lib/programme_decisions.py`. They always stay with Shawn; no Authority level and no Ruling moves them. |
| what done means for a kind of change | **Done standards** | The protocol rules that map a kind of change to its required deliverables and evidence bar. They carry no level: who decides is Authority's job. |
| whether Shawn has accepted the agreement | **accepted marker** | `contract_version`, written only when the agreement is accepted. Until it is written, `product_call` and `product_scope` stay with Shawn; it gates nothing else. |
| the decision rules an accepted agreement prints | **operating contract** | The lines the rules block adds once the accepted marker is written (`operating contract v<n>`): the PM decides what Authority and the Rulings leave to it, records why, and brings Shawn only choices that change the outcome or acceptance, reopen a settled human decision, touch a reserved area (one an active restrict Ruling covers), exceed a risk or cost limit, or need a refused permission. |
| the list of calls made while a programme runs | **decision log** | `log-decision`, answered asks and the accepted agreement: who decided, the decision kind, and the Ruling or preferred tool cited, or silent. It records calls; it approves nothing and is not a Ruling. |
| a handed decision waiting on Shawn | **pending ask** | An open `hand-item` ask, kept in the Programme view with its options, effects, do-nothing outcome, recommendation and the exact reply to type. Chat shows it only when it is new or its facts change. A typed reply approves it when it names exactly one pending ask by id, session name or title. |
| what sort of choice a decision is | **decision kind** | One of a closed list in `lib/programme_decisions.py`: the Authority kinds plus technical approach, work sequencing, worker coordination, tool choice, optimisation depth, product scope, acceptance and denied operation. `hand-item`, `log-decision` and `record-ruling` require one; an unknown kind is refused. Not the same as a change kind, which maps an item to its deliverables. |
| Rulings kept past a programme's end | **carry-over store** | A per-machine JSON file beside the personal protocol. Rulings Shawn picks at the end (`carry-rulings`) are stored under each remit repo's key, and arrive in the next programme on that repo pending, with no items, until his typed prompt names the items. It is a cache of the `rulings_carried` approval rows: setting a remit before the agreement is accepted refills any verified entry it lost. |
| why a worker may not do something | **restriction source** | Where a restriction in a worker's brief came from: `human`, `runtime`, `requirement`, `pm_choice` or `worker_assumption`. The PM handles each by its source: it never routes around a runtime refusal, and it may lift its own `pm_choice`. |
| standing settings across programmes | **protocol** | Authority and Done standards, in three layers (plugin, personal, project). Every programme reads them live; `ack-protocol` records what a programme last acknowledged, so the PM can report each change once. |
| the PM's live state of mind | **working model** | Now, queue, watching, waits, decisions for the human, just did, rules in force — shown in a PM-only mod. |
| a programme's record of actions | **journal** | An append-only log beside the run-record: Shawn's prompts, items joining, evidence checked, terms amended, rules adopted, ownership changes. |
| how the PM and its workers do the work | **behaviour** | Shawn's standing guidance: a situation in plain words with checks the PM or the working agent tests, what to do and not do, which skills, tools and agents to prefer, what shows it was followed, and when to stop. It lives at the programme, repo or personal layer, and the narrower layer wins. It carries no authority and no done bar. Format, layers and load rules: `docs/contracts/programme-behaviours-format.md`. |
| a setup answer chosen in a picker | **picked prompt** | Shawn's answer to the PM's AskUserQuestion, verified from the session transcript. During setup it sets one per-programme setting. After that it approves one command on the pick list when its answer is that command's approval label. It approves the accept only through the accept's terms-bound approval label. It never approves a Ruling or a remit change. |
| the exact picker option that approves a command | **approval label** | "Approve " plus the command's verb and arguments, printed by `approval-label`. A pick approves only when its answer equals the label of the command being run; any other answer approves nothing. For the accept, `approval-label accept-agreement` prints `Approve accept-agreement --terms <digest>`, where the digest is a short hash of the agreement terms as `status` shows them; the accept refuses a digest that no longer matches, and an accepted suggestion never approves it. |
| a Claude Code suggested prompt Shawn accepted | **suggested prompt** | A prompt whose transcript row says `promptSource: suggestion_accepted`. It resolves to origin `suggested` and approves what a pick may approve, by its wording, never a typed-only verb. |
| where programme sessions run | **terminal host** | The terminal app a programme's panes live in: herdr, Rex or Ghostty. Auto reaches it through one host module that says what each host can do, and refuses with a fix when a host cannot. A **space** is a host's group of panes: a herdr workspace, a Rex session or a Ghostty window. Written `server.workspace` on herdr and `host--server--workspace` elsewhere. |
| the claim on a remit | **lease** | The per-space record, keyed by host and space, that makes a programme the only live one in its remit. Two hosts can hold a space of the same name without clashing. A takeover moves it. A typed takeover moves it at once when the terminal host shows the old PM's pane closed or running another session, after two missed cadences, or when the typed takeover names the old PM with `--replace`. With no typed request, `takeover --prompt <id>` moves it only on Shawn's pick, in that session, of the exact label naming the current PM, whether that PM is live, orphaned or gone. A typed prompt or an accepted suggestion never moves it. |
| a replaced PM going quiet | **stand down** | What a session does when another session took over the programme it drove and that PM has not stopped. `become-pm` prints step `stand-down`; the session finds its programme cron with CronList and deletes it, stops each Monitor task it started, and stops, with no message to Shawn. `become-pm` names one next step for any session Shawn asks to be the PM: start, ask Shawn by picker, already the PM, or stand down. |
| which session runs in which pane | **session registry** | A per-space log the SessionStart hook writes inside a terminal host (herdr, Rex or Ghostty): each session's host, id, pane, terminal and whether it is interactive. Rows with no host read as herdr. The PM reads it to know who owns a pane. |
| a worker's report of finished work | **claim** | A line a worker session adds to the programme's **inbox** (`claims.jsonl`) naming an item, a deliverable and a ref. The PM checks the evidence before it believes it; a claim alone never makes an item done. |
| when the PM may stop | **stop rule** | An agreement term: stop when nothing is left it can act on (the default), only when every item is done, at a set time, or never. Code computes "may stop" from it; the PM does not decide. |
| how often the PM sweeps | **cadence** | An agreement term: sweep on change (the default) or on a fixed interval, with a daily eval budget and quiet hours. A lease whose heartbeat misses two cadences counts as orphaned. |
| how much runs at once | **focus budget** | An agreement term with a points limit for tasks, an agents limit for worker panes, and a size scale (small=1, medium=3, large=5). No limit until Shawn sets one. `start-worker` holds work that would go over; `--despite focus` overrides only after Shawn picks `override-focus` for that item, and is journaled. Subagent fan-out is advice only. |
| work waiting for room | **held item** | An item the focus budget refused to start. It shows in the status view's "Waiting for a slot" list in the order it was held, until `focus-recheck` finds room. |
| a held item that was running | **parked item** | An item `swap-item` held to make room for a newcomer, after Shawn picked the swap. Its old worker is told to stop, and it cannot start again while that worker is live. |
| where the PM looks for state | **tools of record** | An agreement term listing the sources the PM reads each sweep: the tracker, each session's task list, and plan files in the remit's repos. Formerly the `sources` term. |
| one PM pass over the programme | **sweep** | Prune prompts, re-check evidence, read the remit and the inbox, check claims, drive workers, record waits with watchers, update the working model, re-arm the wake-ups, then stop. |
| the PM's own check of a deliverable | **evidence** | A deliverable's result read from the source system by the PM's checker: `confirmed`, `refuted` or `unknown`, with a ref and the check time. A worker's claim is not evidence. |
| what observes a wait | **watcher** | A process or task that watches one wait and beats. It counts as live only while its heartbeat is newer than the cadence. A wait with a named reporter and no watcher still counts as covered. |
| a PM folder recorded by an older auto | **programme worktree** | A detached git worktree at `<main checkout>/worktrees/programme-<run>`, recorded on the programme as `pm_worktree` by auto 0.16.2 and earlier. auto no longer creates one, and the PM works from whatever folder its session runs in. At programme end a recorded one is removed only when nothing in it could be lost, and otherwise stays an owed resource until Shawn clears it. Not the programme's **home**, which is its data directory under the auto data dir. |
| a programme's durable state | **programme store** | `<home>/programme.db`, one SQLite file per programme. Every acknowledged change commits its state, journal row and outcome in one transaction; the JSON files are exports rebuilt from it. Not the memory store in the repo glossary. |
| a replacement PM's briefing | **recovery packet** | A revision-bound view of the agreement, decisions, requirements, actions and results that `recover` prints. It restores context and grants no approval. |
| a sealed programme | **archive** | A read-only programme record whose result and code captures were checked before sealing. Archiving does not mean every requirement passed, and it never deletes anything. |
| the follow-on to an archive | **successor** | A new programme linked to an archived one. It needs its own accepted agreement and never reopens the archive. |
| moving a programme into the store | **promotion** | The one-way move of a programme's home from plain files to the programme store. Afterwards the store is the only source of truth. A Ruling change on a home still on plain files runs it once the change passes its checks, and refuses if it cannot run. |
| a change the store did not make | **foreign write** | A change found in a promoted programme's exports, such as a write from old plugin code. Appended rows are kept as a record but never count as approval; rewritten files are set aside. |
| a request to allow a refused read | **permission proposal** | The PM asks Shawn once to apply a narrow native allow rule after a worker's read is refused. It grants nothing itself; Shawn applies the rule. Not a protocol proposal, which changes completion rules. |
| an item's path through its steps | **trajectory** | Steps done, the current step, the planned steps and the finish, as the PM writes them each sweep. It belongs to the item, not the session doing it, and fades once it is older than about two sweeps. |
| the rule a step relies on | **clause** | The Scope term, Done standard or active Ruling a step cites (`term:`, `rule:`, `ruling:`). A step with no clause is shown as such; that is a warning, never a block. |

## The shape in one line

> A **workflow** is an ordered set of **steps**; each step runs a **preset**.

Three levels, no word overloaded, no metaphor.

---

## Reading older code, plans, and run-records

Nine identifiers were retired when the code adopted this vocabulary. They survive in
plan documents written before the rename, in run-records and workflow files on disk,
and in anything you pulled from an older version. This table is how you read them —
it is **historical**, not a live alias list. Nothing in `lib/`, `skills/`,
`commands/`, or `docs/contracts/` spells those nine any more, and
`tests/unit/vocabulary-audit.test.sh` fails the build if it starts to.

The rows from `instructions` down are the Programme concepts retired when the
agreement was cut down to Scope and Rulings. Their persisted keys still read (see the
read-compat guarantee below), so `lib/programme_home.py` still spells them in its read
fallback; the verbs are gone, with no alias.

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
| `instructions` | **Ruling** (kind-less, effect decided) | `programme.instructions[]` in older records; `instruction:<id>` step clauses | <!--legacy--> |
| `record-instruction` / `close-instruction` | `record-ruling` / `close-ruling` | old transcripts and plans | <!--legacy--> |
| `record-decision` (decision record) | `record-ruling` (**Ruling**) | kind-less revisions under `context.decisions` | <!--legacy--> |
| correction (`correct-term`, `undo-correction`) | `record-ruling --replies-to` / `close-ruling` | old plans; corrections were never switched on | <!--legacy--> |
| `keep-corrections` / `promote-correction` | `carry-rulings` | old plans and `/auto:programme-end` text | <!--legacy--> |
| `autonomy` (agreement term) | none: **Authority** answers who decides | `agreement.terms.autonomy` in older records, dropped on read | <!--legacy--> |
| `autonomy` (rule field) | none: **Done standards** carry no level | a protocol rule's optional legacy key, still validated and hashed | <!--legacy--> |
| reserved project term (`--reserved-term`) | restrict **Ruling** (kind-less) | `agreement.project_terms[]` entries with `reserved: true` | <!--legacy--> |
| project term (who decides an area) | **Ruling** with a decision kind | older agreements; preferred-tool text stays as a project term | <!--legacy--> |
| contract stamp | **accepted marker** | the same `contract_version` key | <!--legacy--> |
| `status --terms` | `status --agreement` | `/auto:programme-status terms` in older notes | <!--legacy--> |

### The read-compat guarantee

**Files you already have keep working, indefinitely.** `lib/format_compat.py` maps the
retired on-disk keys and values to the current ones **in memory on every read** — it is
never version-gated and never skipped:

- **Run-records** (`.claude/auto/<run>.json`) written by pre-rename code load, resume,
  and complete unchanged. They migrate to the current shape lazily, on their first
  write, because every mutation funnels through one atomic-write path. No migration
  command, no bulk rewrite, nothing to run.
- **Programme records and protocol files** written before Rulings keep reading
  correctly, with no bulk rewrite. Programme records read through
  `normalize_programme` in `lib/programme_home.py`, not `lib/format_compat.py`, which
  passes programme blocks through untouched: old instructions and reserved project
  terms read as kind-less legacy Rulings under their own ids, the agreement's
  autonomy term is dropped, and when a retired key and its replacement both exist the
  new one wins. Protocol files keep loading: a rule's `autonomy` field is accepted as
  a legacy key, and each adoption hash still covers the entry as written, so old
  adoptions verify.
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
