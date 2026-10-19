---
title: "A switch that restrains an agent cannot be read from an environment the agent can set"
date: 2026-10-19
category: best-practices
module: plugins/auto
problem_type: best_practice
component: tooling
severity: high
applies_when:
  - "adding an off switch, feature gate or test override whose job is to stop an agent doing something"
  - "the restrained agent can run shell commands, so it can export variables before calling the guarded command"
  - "reusing an existing env-gated test-hatch pattern for a new gate"
  - "a guard inspects free text that arrives in more than one field"
resolution_type: code_fix
related_components:
  - testing_framework
tags: [default-deny, test-hatch, environment-variables, self-restraint, safety-switch, unattended-agent, enumeration]
---
# A switch that restrains an agent cannot be read from an environment the agent can set

## Context

The PM operating contract adds correction verbs (`correct-term`, `undo-correction`,
`keep-corrections`, `promote-correction`) to the auto programme. They must stay off
until a later release lands the approval-origin fix, because nothing yet proves a
correction came from Shawn rather than from the PM (plan
`docs/plans/2026-10-19-0854-feat-pm-operating-contract-plan.md`, KTD5 "Corrections
ship switched off", line 213).

The tests still need to turn the verbs on. The repo already has a pattern for test
overrides: `_test_hatch_enabled` in `plugins/auto/lib/run_record_core.py:159-163`
returns true when `CLAUDE_AUTO_TEST_HARNESS=1` and a named hatch variable is `1`.
`run_record_mutators.py:156-157`, `run_record_predicate.py:86`,
`programme_predicate.py:33` and `run_record_core.py:331,407` all use it. Reusing it
for the corrections switch is the obvious move, and it is wrong.

The PM is the agent the switch restrains, and the PM runs shell commands. The guarded
verbs are reached through `plugins/auto/lib/programme.sh`, which the PM calls from that
same shell. So the PM can run
`CLAUDE_AUTO_TEST_HARNESS=1 CLAUDE_AUTO_TEST_CORRECTIONS=1 programme.sh correct-term ...`
and the gate opens. An env-gated hatch is fine for skipping a lock or a recompute in a
test. It is not a bound on an actor who controls the environment.

## Guidance

**1. A switch that holds an agent back reads nothing the agent can write.** Make it a
module constant with no environment, file or argument override. A release flips it.

```python
# plugins/auto/lib/programme_terms.py:228-229
# No environment override: the PM can set environment variables from its own shell.
CORRECTIONS_ON = False
```

Every guarded entry point checks it (`_check_switch`, `programme_terms.py:269-271`).
That includes `keep-corrections` (`programme_terms.py:402-403`), `promote-correction`
(`programme_terms.py:444-445`) and the end-of-programme summary (`end_lines`,
`programme_terms.py:399`).

**2. Tests turn it on inside the test process.** They do not use the environment.

```python
# plugins/auto/tests/unit/programme-corrections.test.sh:110-111 (inside prog_on)
pt = load_lib_module("programme_terms")
pt.CORRECTIONS_ON = True
```

The patch exists only in the Python process that the test starts. A shell that calls
`programme.sh` gets a fresh import with the shipped value.

**3. Prove the agent's route stays shut.** Two tests pin the property, not the
implementation:

- "the shipped switch is off" (`programme-corrections.test.sh:196-199`) reads the
  constant from a fresh import.
- "the test harness and hatch variables do not turn corrections on"
  (`programme-corrections.test.sh:213-218`) exports `CLAUDE_AUTO_TEST_HARNESS=1`,
  `CLAUDE_AUTO_TEST_CORRECTIONS=1`, `CLAUDE_AUTO_CORRECTIONS=1` and
  `CLAUDE_AUTO_TEST_NO_PULSE_LOCK=1`, calls `programme.sh correct-term` the way the PM
  would, and requires exit 1, "corrections are not on yet" and an unchanged state hash.
  If someone later "tidies" the switch onto `_test_hatch_enabled`, this test goes red.

**4. Check every field the restrained text can arrive in.** The same review found
the second form of this gap. `_check_area` refused a project term whose *area* named a
protected escalation (a production deploy, a release), but did not read the term's
*text*. So `testing=the PM deploys to production` passed: the area "testing" is
harmless, and the protected wording sat in the other field. The review fix on the PM operating contract branch checks both fields (`programme_terms.py:70-78`):

```python
for what, words in (("area", area), ("text", text)):
    kind = protected_kind(host, words)
```

`programme-terms.test.sh:187-195` proves the text form refuses, writes nothing, and is
accepted when the term is reserved for Shawn.

## Why This Matters

Both gaps share one shape. The guard trusts an input the restrained party controls:
the environment in the first case, the unchecked field in the second. Neither gap
produces a signal. The hatch version passes every test, because the tests set the
same variables the PM could set. The area-only version passes every area test. The
first sign would be a PM that applied a correction or took a protected decision
without Shawn's approval.

This is the same rule as `default-deny-for-an-unattended-agent.md` ("The job must not
be able to write the file that defines its own bound"), applied to environment
variables. A bound that the bounded actor can write is not a bound.

## When to Apply

- You add an off switch, kill switch, feature gate or approval gate whose purpose is
  to stop an agent doing something.
- The agent can run a shell, so it can set variables, write files in its writable
  tree, or pass arguments to the guarded command.
- You reach for an existing test-hatch helper to make the gate testable. Ask: "who
  is this gate for?" If the answer is the caller, the hatch is not safe for it.
- A guard inspects free text that comes in more than one field (key and value, title
  and body, area and text). Check every field, or the class stays open through
  whichever field you skipped.

It does not apply to test hatches that only skip work for speed or isolation (a lock,
a recompute, a pulse). Opening those gives the agent nothing it could not already do.

## Examples

Wrong: the gate reuses the test hatch.

```python
def _check_switch():
    if not (CORRECTIONS_ON or run_record_core._test_hatch_enabled("CLAUDE_AUTO_TEST_CORRECTIONS")):
        raise TermsError(CORRECTIONS_OFF)
```

The PM opens it with one prefix on its own command line.

Right: the gate is a constant, tests patch it in-process, and one test runs the PM's
route with every hatch variable set and requires a refusal
(`programme-corrections.test.sh:213-218`).

Wrong: the guard reads one field.

```python
kind = protected_kind(host, area)   # "testing=the PM deploys to production" passes
```

Right: the guard reads both fields (`programme_terms.py:73-74`), and a test puts the
protected wording in the field that was not checked before.
