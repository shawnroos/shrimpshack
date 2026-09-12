---
title: "A harness check that reads only its scanner's output calls a crash clean"
date: 2026-09-12
module: plugins/data-presentation
problem_type: logic_error
component: testing_framework
severity: high
category: logic-errors
symptoms:
  - "the fixture-leak check printed `ok - no fixture holds a real path, id or session (clean)` while its scanner had died on a non-UTF-8 byte and printed nothing"
  - "deleting the whole plugin `commands/` directory left the harness at `37 passed, 0 failed`, including the check whose label claims both listings are populated"
  - "both checks were mutation-proven against their real subjects and went red correctly, so the gap was invisible to the mutation sweep"
root_cause: logic_error
resolution_type: test_fix
tags:
  - false-green
  - harness
  - default-deny
---

# A harness check that reads only its scanner's output calls a crash clean

`plugins/data-presentation/tests/harness.sh` grew two checks that run a Python scanner in a
command substitution and judge the result by whether the output is empty:

```bash
leaks="$(python3 - "$TESTS/fixtures" <<'PY'
...
print("; ".join(hits))
PY
)"
check "no fixture holds a real path, id or session (${leaks:-clean})" "[ -z '$leaks' ]"
```

An empty `$leaks` is supposed to mean "the scanner looked and found nothing". It also means
"the scanner died before printing". Two ways to hit it, both observed:

- A fixture with a non-UTF-8 byte raised `UnicodeDecodeError`. The scanner exited 1 with no
  stdout, and the check printed `clean` — while a `/Users/` path sat in a later fixture it
  never reached.
- Moving `plugins/data-presentation/commands/` aside made `os.listdir` raise `FileNotFoundError`. Same empty output,
  same pass, on the check that exists to prove a command never shadows a skill.

The mutation sweep could not see either. Both checks were proven by breaking their real
subject — planting a leak, renaming a command to collide — and both went red. A mutation
tests the predicate; it says nothing about whether the input reached the predicate.

## The fix

Read the exit status, and let a crash fail the check:

```bash
leaks="$(python3 - "$TESTS/fixtures" <<'PY'
...
PY
)"; rc=$?
[ "$rc" -eq 0 ] || leaks="scanner exited $rc"
check "no fixture holds a real path, id or session (${leaks:-clean})" "[ -z '$leaks' ]"
```

The scanner also reads files with `errors="replace"`, so a binary fixture is scanned rather
than fatal — the crash that started this is now a finding instead of an exception.

Both fixes were proven the way the gap was found: plant a non-UTF-8 byte in a temp fixture
and confirm the harness exits non-zero, then move `plugins/data-presentation/commands/` aside and confirm the collision
check fails. See PR #81 for the change.

## Prevention

A check whose verdict is a scanner's *output* needs the scanner's *exit status* too, or the
two indistinguishable states — "looked, found nothing" and "never looked" — collapse into a
pass. This is the same shape as
[a tally keyed on exit status](a-tally-keyed-on-exit-status-reports-work-that-never-happened.md)
read in the other direction: there, a status was trusted where an effect was needed; here, an
effect is trusted where a status was also needed. When a check delegates to a subprocess,
assert both, and prefer a scanner that reports "I could not read this" as a finding over one
that dies.
