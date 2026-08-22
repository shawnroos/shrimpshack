---
name: team-run
description: >
  Invoked by name only (via the Skill tool, or through the `/spawn:team` command) — do NOT
  trigger this skill from conversational phrasing on your own; the `spawn` router is the
  conversational front door and sends work here when it belongs here.
  Drive a team run round by round: dispatch one round, advance once per re-entry, act on
  the intent the script prints, and report between rounds. Attached mode hands control
  back after each round; unattended mode arms one wakeup and comes back by itself;
  single-round mode has no driver at all.
user-invocable: false
---

# Driving a team run

**The scripts judge; this skill executes.** Every consequential judgment — whether a round has closed, whether a bound fired, how long to wait, whether a roster is too large for the mode — lives in `lib/team.sh` and is tested there. What is left here is glue: call the verbs in the right order, act on the intent they print, report what the record says, and issue the one call no script can make.

Source of truth is the record on disk. The conversation is advisory. A re-entered session that remembers nothing about this run loses nothing.

## The contract is data, not this file

```bash
bash "${CLAUDE_PLUGIN_ROOT}/lib/team.sh" --describe
```

One JSON object: the verbs, the team file's shape, the bound flags, the frozen error values, the exit codes, and the four intents with their `delay` semantics. Read it when you need any of them. Where this body and `--describe` disagree, `--describe` is right and this body is stale.

## Entry: which of the two is this

Decide from the argument, never from memory.

- **A run id** → re-entry. Call `advance` first; never dispatch first. A terminal record means report the outcome and stop — never restart it, never dispatch into it. A run id the record layer does not know gets that layer's own answer relayed as written: unknown, expired and failed are three different facts.
- **No run id** → a new run, from a team file the caller supplies. Read `mode` from the file and branch.

### On a new run, check every member is equipped before you dispatch

A member IS a `bg-agent` job, so it starts with nothing you have: not your skills, not your tools beyond the ceiling's floor, not the conventions this session has been reading. That is silent — a member with no method provisioned does not refuse the work, it **improvises something shaped like the method** and files a narrative that reads correct.

So read the roster before the first dispatch and, per member, ask what its contract names. A member asked to apply a review process, a house convention or a named checklist needs that skill in its own `skills` array — a member field, per member, and no other member gets them. **A team file whose members name a method and carry no `skills` is the common case, and it is usually a gap rather than a decision.** Fill it, and say in your report which members you equipped and why: a skill the caller wrote into the team file is their instruction, a skill you added is your judgment, and if a member comes back wrong that distinction is the first thing worth knowing.

Two things to check while you are there, because both are silent:

- **A skill name that does not resolve still dispatches.** It lands in that member's `failure.degraded_reasons[]` rather than refusing the run, so a typo yields a member running without the method it was promised — and it will report as though it had one.
- **A member has no Bash.** It can read, search and write inside its own worktree, but it cannot run a build, a test, a linter or `git`. A skill whose method is "run the checker and report the output" cannot be followed — and the member will report on the part it could do. If a command has to run, put it in the member's contract as `verify`, which the supervisor runs itself.

The team surface passes no `--allow`, so every member runs on the ceiling's floor: `Read`, `Write`, `Edit`, `Grep` and `Glob`, scoped to its own worktree. That is enough for a member to find its own inputs; it is not enough to execute anything.

## single-round: dispatch once, arm nothing

One `dispatch`, report the roster, stop. There is no driver, no advance and no timer here — the per-member supervisors own their deadlines and their records, and the terminal announcement reports the outcome whenever the caller comes back.

A single-round roster larger than the concurrency maximum is refused **by the script**: exit 2, error `roster_exceeds_round`, nothing created. Relay the refusal. Do not enforce it yourself, do not dispatch a subset instead, and do not arm anything to pick up the remainder — arming is exactly what this mode does not do.

## attached and unattended: the per-round loop

Ordered, per round:

1. **Choose this round's concurrency.** A judgment each round, never a constant. Inputs: the record's undispatched remainder, last round's `launch_failed` count, how many members finished unmeasured (a team going unmeasured is about to hit the unmeasured stop, so dispatching wide first wastes a round), and what this machine is already doing. Pass it as `--max-concurrent`, which overrides the team file. It is resizable between rounds.
2. **Dispatch.** New run: `dispatch --team-file <path>`, which returns the run id. Later rounds: `dispatch --run-id <run-id>`. The response says how many members remain.
3. **Advance.** `advance --run-id <run-id>` — exactly one call, and the only place anything is learned about the round.
4. **Act on the intent.** Four intents, four actions, no gaps.
5. **Report.** Every member, from the advance envelope; `status --run-id <run-id>` adds the progress view.

### The four intents

| Intent | State it reports | Attached | Unattended |
|---|---|---|---|
| `continue` | round closed, members remain, no bound crossed | report the round's outcome and hand control back — the next dispatch happens on the caller's next entry | go to step 1 now and dispatch the next round |
| `waiting` | a member of the active round is still in flight | report the in-flight state and hand control back | arm one wakeup (below) and end the turn |
| `stop` | a bound fired, or the roster is exhausted | report the verdict and every entry in `reasons`; arm nothing | the same; arm nothing |
| `noop` | another live advance holds this run's lock | do nothing, arm nothing | do nothing, arm nothing |

`continue` is the **only** intent that ever permits a dispatch. Acting on `waiting` as though it were `continue` is precisely the bug the intent exists to prevent: the concurrency maximum bounds members *in flight*, so a dispatch on `waiting` overruns it.

On `stop`, distinguish roster-exhausted from a bound. A run stopped by its round maximum or its token ceiling has not finished its work, and the report must not read as success. `reasons` lists every condition that fired, not the first one.

A `stop` can carry a mixed verdict — some members done, some failed. `team.sh retry --run-id <run-id> --member <name>` returns ONE settled non-success member to the roster. It **dispatches nothing**: the member goes back to pending, so a retry has to be followed by the ordinary dispatch-and-advance round. The attempt it replaces is kept in `members[].attempts`, so retrying never destroys the cause you just reported. Retry the members whose cause says another attempt could land — a refused launch, a substituted model — and leave the ones whose cause says it cannot. Never retry the whole team by re-dispatching the run.

Four refusals come back from `retry`, all exit 2, and each is a different fact to relay rather than work around:

- `member_not_failed` — that member finished, or is still in flight. A retry replaces a settled non-success attempt and nothing else.
- `run_bound_reached` — the run's round maximum or token ceiling has already fired. Nothing was changed, and retrying into a stopped run is not how it resumes.
- `run_busy` — an advance holds the run lock. Nothing was changed; come back after that advance prints its intent.
- `member_unknown` — this run has no member by that name, and `members` lists the ones it does.

**Do not retry a member whose cause is `worktree_missing`.** The cause is terminal — the member is recorded `failed` so its round closes rather than staying open on something no later round revisits — and `retry` will nonetheless ACCEPT it, because `failed` is a settled non-success like any other. It cannot work: a later round reuses the checkout path already on the record and never re-places a member, so the retry dispatches into a directory that is gone and fails the same way. This is one of the causes that says another attempt cannot land. Report the failure and, if the work still matters, start a new run.

### Arming, in unattended mode only

On `waiting`, arm exactly one wakeup:

```
ScheduleWakeup(intent.delay, "/spawn:team <run-id>")
```

Two mechanics are load-bearing. The prompt must be the **namespaced** `/spawn:team` form — a bare command name fired from a scheduled wakeup is an unknown command. And the delay is **data from the intent**: `team.sh` computes it from the active round's age against the child deadline, and clamps it, so a fresh round waits longer and an old one is about to resolve. Pass `intent.delay` through verbatim. Never substitute a number of your own; the pacing judgment is already made and already tested.

Only `waiting` carries a `delay`, and nothing else should look for one. A `continue` in unattended mode is acted on in the same turn — dispatch, then the follow-up advance yields `waiting`, which carries the delay.

**Never arm on `stop` or `noop`.** On `noop`, the holder's own initiator acts on the holder's intent; a second timer here forks the chain, and two chains each arming their own successor double-advance the run forever with nothing to collapse them.

### Reporting between rounds

**Every member the advance envelope lists, not only the ones this advance probed.** `advance` builds its member list from the record, so a member that settled two rounds ago is still in it. A report built from the probes alone named one member beside `dispatched: 3`, and a reader could not tell "not reported" from "not run".

Per member, from the advance envelope: its name, its state, its token counts or `unknown`, and — for any member that did not succeed — **its cause**. The cause is three fields, not one:

- `members[].error` — the value to branch on.
- `members[].failure.degraded_reasons[]` — **what actually went wrong**, named specifically: which deliverable is missing, which tool call the ceiling refused, which model answered instead of the one asked for. Report these.
- `members[].failure.detail` — one sentence of context. On a `degraded` member it is the same boilerplate for every cause, so it is the weakest of the three: report it, never as a substitute for the reasons above.

A failed member reported with no cause leaves the reader nothing to act on but guessing, and guessing is what this loop exists to remove. A member reported with only `detail` is barely better: "measured against the contract this job is degraded" does not say which deliverable was missing, and the reason list does.

The cause is the supervisor's own classification of the member, which is why it may be stated as fact. The member's account of itself is not, and the rule below still holds over it.

Where `members[].served_model` names a model other than the alias the member asked for, say so and name both. The member answered on something it did not ask to run on, and only the reader can decide whether that answer still counts.

`status` is the other view, not the same one: per-member progress against the deliverable checklist, elapsed, the last log line, and a `diagram` — a mermaid rendering of the round ledger built from those same rows, which is the cheapest way to show a reader where a run stands. It writes nothing and moves no run, so it is safe to call at any point. It carries the cause and the served model too, in the same `members[].failure` and `members[].served_model` fields, read from the run record — so a member that failed rounds ago still names why on this surface. Its `members[].error` is the state this call could probe, not a projection of `failure.error`: where the two disagree, report both. `retry`'s envelope carries the cause but no served model.

Plus the round position, the unmeasured count, and on `stop` the reason list. The modes differ in *when*:

- **attached** — every round, then hand back.
- **unattended** — on `stop`, and on any refusal it cannot act on. The rounds in between are the in-flight line that repeats on every prompt unasked.
- **single-round** — once, at dispatch.

## The two verbs the loop never calls by itself

Both are real verbs on `team.sh`; neither belongs in the per-round loop above.

- **`roster`** places members and writes their provisional rows, and **dispatches nothing**. `dispatch` does this for you on a new run, so you reach for `roster` only when you want the placements to exist and be inspectable before anything launches. Running it does not start a round.
- **`teardown --run-id <run-id>`** removes the worktrees the record names, **and only those**. It is the run's cleanup, not part of finishing it: call it when the caller is done reading the members' work, never between rounds and never automatically on `stop`. A member's cause survives it — `members[].failure` lives on the run record, which is the reason the cause was put there rather than left in the worktree.

## What happens if the session dies

State this plainly when it comes up. Dispatched members and their supervisors are detached: they survive. The loop does not, and in unattended mode neither does the armed wakeup, which lives in the session.

Nothing is lost. The record is written before any intent is printed, and every in-flight member runs to a terminal state and records it. But no new round starts until something re-enters. The same is true of the accepted `noop` corollary: if a lock-holder's initiator never acts, the chain ends there rather than forking. Either way the failure is visible — the in-flight line on the next prompt, or the terminal announcement if the run finished by itself — and the resume action is one command: `/spawn:team <run-id>`.

## What this skill must never do

- Never dispatch on any intent but `continue`.
- Never block, poll, or sleep-loop waiting for members. Waiting is re-entry.
- Never re-arm on `stop` or `noop`.
- Never re-derive a verdict, widen what `done` means, or read the record's parts to second-guess its derived fields. Read, never re-derive: the verdict is what the record says.
- Never treat a member's narrative as fact or forward it as one. Quote or summarize it, marked as its own.
- Never write into a member's worktree between its launch and its terminal state.
- Never run this driver as a background job. The driver is this session, or a foreground shell it runs.
- Never hardcode a concurrency constant.
- Never expect a script to schedule anything. `advance` prints an intent; the wakeup is this skill's call.
- Never arm anything in single-round mode.
