# A test can pass because it cannot fail

Five assertions written during one branch were green, were believed, and could
not have failed. Each was caught by mutating the production line and watching
for red — never by the passing run, which looked identical either way.

## The five shapes

**A non-zero exit is not a refusal.** A test asserted `status -ne 0` against a
function that did not exist yet. `command not found` is 127, which is non-zero,
so the test passed on day zero and would have passed for ever. Assert the
SPECIFIC error value, never merely that something failed.

**`jq -r` prints `null` for a key that was never written.** An assertion
comparing `.detail` to the string `null` could not distinguish "measured as
null" — the thing the code promises — from "this key does not exist". Where the
distinction carries meaning, assert KEY PRESENCE beside the value.

**A mutation that does not mutate proves nothing.** One mutation script had a
syntax error and left the file unchanged; the green run that followed was read
as evidence the code was load-bearing. Verify the file actually changed before
trusting the result, and treat a syntax error in the mutated file as a void run
rather than a red one.

**A fixture that cannot produce the shape cannot test it.** `if model_usage:`
in Python treats an empty object as falsy, so the fixture dropped the key
entirely and the test for "present but empty" silently exercised "absent". The
mutation stayed green. Unset and empty must be separately expressible before a
test can tell them apart.

**`! grep` does not fail a bats test.** POSIX exempts a pipeline beginning with
`!` from `set -e`, so an absence assertion written that way passes whatever it
finds. Route negatives through a helper that fails as a plain command.

## The rule

A green test is evidence about the test only. The question is not "does it
pass" but "what would make it fail, and have I seen that happen". Mutate the
line the assertion claims to pin, watch it go red for the RIGHT reason, restore,
watch it go green. An assertion no mutation reddens is a finding — it means
nothing reaches the case it exists to guard, and the unreached guard is the
defect.

## Why it recurs

Every one of these passed review by a human reader and by other agents. They
read as correct because the intent is legible in the assertion text; what is
illegible is the gap between what the assertion says and what the runtime
actually evaluates. That gap only shows under mutation.

Related: `docs/solutions/workflow-issues/test-count-subtraction-reconciliation-is-weaker-than-passing-parity.md`
