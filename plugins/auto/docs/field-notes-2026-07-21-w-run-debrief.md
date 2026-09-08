# Field notes — driving a `w` run by hand (2026-07-21)

**Engine version:** auto 0.14.0
**Run shape:** `w` (work-only), backend `ce`, 7 dependency-ordered implementation units
**How it was driven:** largely **by hand** — firing `lib/pulse.sh` and calling
`dispatcher.dispatch_batch` directly from the boss session, rather than through the
intended `ScheduleWakeup`-armed pulse chain. Some friction below is "manual-driving
tax," but the load-bearing bugs would bite the intended flow too. Each item is
tagged **[engine]** (real bug regardless of drive path) or **[manual-tax]** (friction
from bypassing the armed chain).

The run completed: all 7 units implemented, verified, committed; exit predicate met
(`blockers==0 && majors==0`, 7 minors tolerated).

---

## What worked well

- **Verdict durability.** Sub-agents self-writing verdicts to the run-record — readable
  off disk independent of the dispatching turn — is genuinely robust. It's what let the
  boss recover two agents that died mid-run without losing their work.
- **Dependency-gated dispatch.** Encoding `U5 depends_on=[U3,U4]` correctly serialized a
  known file-collision (two units editing the same template) — `ready_steps` never
  surfaced a colliding unit. The `depends_on` sanitizer preserving forward-refs to sibling
  enumerated steps worked exactly as its docstring promises.
- **Phase-scoped exit predicate.** `met: true` with `blockers==0 && majors==0` while
  tolerating minors is the right P3 bar.

---

## Bugs (would bite the intended flow too)

### 1. Emitted guidance says `bash run_record.py` — which mis-executes **[engine]**

`lib/run_record.py` has a `python3` shebang; running it via `bash` interprets Python as
shell (an agent hit "ImageMagick / `from: command not found`" noise before self-correcting
to `python3`). The `operator_guidance` string and the persist examples both say `bash`.
This silently corrupts the **verdict write**, which is the loop's spine.
**Fix:** emit `python3 "$ROOT/lib/run_record.py" …`, or make `run_record.sh` the documented
entry and have it `exec` the python.

### 2. Agents die mid-verification without recording a verdict **[engine]**

Two of seven agents ran the (slow, >120s) Karma suite, which the harness backgrounds; the
agent yielded to "wait for the monitor," received the completion notification instead, and
ended at `dispatched` with **no verdict**. Unattended, the death-path would wastefully
re-run a ~350k-token unit.
**Fix:** the `do_step` agent contract should mandate "record your verdict **before** any
long-running background wait," baked into the dispatch prompt template. (Adding that line by
hand to later units fixed it — the ones told to record-before-yield recorded cleanly.)
Better: split "implement" from "verify" so a flaky verifier can't strand the implementation
verdict.

### 3. `ready_steps` returns the `plan` step during the `work` phase **[engine]**

After `plan→work`, `dispatcher.ready_steps` returned `['plan', 'U1']`. A naive driver
dispatches `/ce-work plan`.
**Fix:** filter steps whose `phase != current_phase`, or terminalize the plan step at the
phase flip.

### 4. `all_steps_terminal: false` next to `met: true` in the exit report **[engine]**

Because the plan step never terminalizes, the final `exit_predicate_result` reads
`all_steps_terminal: false` alongside `met: true` — which looks like a contradiction /
livelock at a glance, and required reading the phase-scoping to trust.
**Fix:** terminalize the plan step, or report `all_steps_terminal` scoped to the eval phase
so the summary isn't self-contradictory.

---

## Missing primitives / discoverability

### 5. No clean way to fire the pulse **[engine]**

`arm-pulse` returns `prompt: "/auto:auto-pulse <run>"`, but that command isn't in the skill
list, and re-invoking `auto:auto` just re-loads the command body pointing back at `auto.sh`
(circular). The runnable (`lib/pulse.sh`) had to be reverse-engineered from the command
markdown.
**Fix:** the `arm-pulse` result should name the exact runnable
(`bash lib/pulse.sh "<run> --auto"`) in a field, not only a slash-command prompt the model
may be unable to invoke.

### 6. `dispatch_batch`'s `launch_fn` is a no-op — the boss hand-builds the whole ce-work↔verdict wiring **[engine]**

The docs read as "launch_fn maps `do_step` → `/ce-work <step-id>`," but the real launcher is
a no-op recorder; the boss must construct each Agent's prompt, the `record-verdict` call, and
the attempt tag by hand. There is **no wrapper** that turns "dispatch unit U3" into "spawn a
ce-work agent scoped to U3's packet that self-writes its verdict." Standard `/ce-work` has no
run-record awareness, so the gap between the documented mapping and reality is wide — this was
the crux that nearly triggered an abort.
**Fix:** ship a canonical dispatch-prompt template (unit packet + verdict-write contract +
attempt) as a library asset the driver fills in, so every driver wires it identically instead
of reinventing it.

### 7. `dispatcher.sh digest <run>` — the documented bounded status read — errors **[engine]**

Returned `bad arguments: list index out of range`. The whole "flat-context via digest" design
(driver-reference §"thin pacing shell") depends on it; fell back to reading full run-record
JSON each beat.
**Fix:** the digest CLI is broken for at least the `w`/work-phase shape — worth a regression
test.

---

## Ergonomics

### 8. Zombie sub-agents re-notify and are invisible to the run-record **[manual-tax, but real]**

A died agent kept re-firing `task-notification`s; it had to be `TaskStop`-ed by hand. The
loop has no awareness of the boss's Agent spawns (they live outside the run-record).
**Fix:** document the reap sequence (TaskStop → SIGTERM) in the skill's death-path, and
consider recording spawned agent-ids on the run-record so cleanup is auditable.

### 9. The Stop hook can't distinguish "correctly yielding for in-flight work" from "wrongly stopping" **[engine]**

It fired an identical blocking message on every turn-end — even when the boss was correctly
yielding for a live Agent. ~10 identical blocking re-prompts across the run.
**Fix:** when the run-record shows an in-flight `dispatched` step with a live watchdog, the
hook could downgrade to a silent pass instead of a blocking re-prompt.

### 10. Driving required reverse-engineering ~12 internal files **[manual-tax]**

`commands/auto.md`, three skills, `SKILL.md` §2/§4, `driver-reference.md` §7/§17,
`run_record` handlers + mutators, `dispatcher.py`, `pulse.sh`, `backend-ce.sh`,
`workflows.py`. The "prepare/execute" split puts a lot of orchestration on the model. Most is
hidden by the intended armed-chain flow — but items 1–7 remain regardless.

---

## Environmental (not the engine's fault, but it compounded)

- **Local Karma is flaky in this repo** (see the web-app's own `no_local_karma_use_ready_pr_for_ci`
  note) — flaky disconnects fed directly into the mid-verification agent deaths (#2). An engine
  notion of "verification deferred to CI" would help.
- **The target worktree's `typecheck` was baseline-RED** (a generated env file the setup never
  produced) — every unit's "typecheck passes" gate was meaningless until the boss fixed it. The
  engine has no baseline-health precheck before starting a run; one would have caught it before
  U1 instead of surfacing in the first unit's verdict.

---

## Top three by impact

1. **#1** — `bash` vs `python3` corrupts the verdict write (the loop's spine).
2. **#2** — mid-verification death strands verdicts and invites wasteful full re-runs.
3. **#6** — no canonical "dispatch unit as a verdict-writing ce-work agent" primitive.

Fix those and an unattended `w` run gets substantially more reliable.
