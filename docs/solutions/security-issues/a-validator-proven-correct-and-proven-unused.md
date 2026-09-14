---
title: A validator can be proven correct and proven unused at the same time
date: 2026-09-14
category: security-issues
module: plugins/work
problem_type: security_issue
component: tooling
symptoms:
  - "A tracker-supplied issue identifier of ../outside made the cache reader return a file outside the cache directory"
  - "The cache refresh script wrote to a filename chosen by the issue identifier the tracker returned"
  - "The identifier validator had passing unit tests, so the gap looked covered"
root_cause: missing_validation
resolution_type: code_fix
severity: high
tags: [path-traversal, validator, caller-coverage, untrusted-input, shell]
---

# A validator can be proven correct and proven unused at the same time

## Problem

`herdr_linear::is_safe_identifier` existed to stop tracker-authored text becoming a
path segment. It had two passing unit tests and exactly one production caller, which
validated a herdr workspace name. No issue identifier ever passed through it. An
identifier is authored by anyone who can edit the Linear workspace, and it reached a
filesystem path in two places.

## Symptoms

- `herdr_linear::cache_read "../outside"` returned the contents of a JSON file one
  directory above the cache. Those contents then replaced the live tracker answer in
  the context a session start hook injects.
- `plugins/work/bin/linear-cache-refresh.sh` redirected into `"$CACHE/$id.json"`, with `$id` taken
  from the tracker's own response. That is an arbitrary file write, and no reviewer
  flagged it.

## What Didn't Work

- **Trusting the unit tests.** They proved the predicate rejects `/` and `..`. They
  could never prove that any caller asked it.
- **Reproducing the traversal by hand.** Two attempts reported "refused" while the code
  was vulnerable: one suppressed a sourcing error, so the function was undefined; the
  other set the cache directory before sourcing the library, which overwrote it. A
  negative result from a harness that cannot fail is not evidence. (auto memory [claude])
- **Fixing only the reader.** The hostile test fixture carried its payload in the issue
  title and kept the identifier well formed, so nothing in the suite made the identifier
  the attack. The write-side twin was found only by asking where else the same value
  became a path.

## Solution

Validate at the boundaries, not only at the one site that leaked:

- at the sink: `cache_read` refuses an unsafe identifier before it builds the path
- at the write-side twin: the refresh script skips an unsafe identifier
- where an identifier enters and leaves the binding store

It was not added at each ingress. The propose verb is the one choke point every caller
passes through, and enumerating ingresses is how the next one gets missed.

Then close the class with a caller-side check in `plugins/work/tests/run-tests.sh`,
`identifier_path_check`. It finds every function that puts a variable segment under a
directory or cache root and requires that function to call the validator, and a second
half requires the validator to be loaded in each file that calls it. It is anchored on
the path construction, not on a function-name prefix. A prefix pattern walked straight
past the bare `write_nodes()` function that held the worst instance.

The fix is in PR #82, pending merge.

## Why This Works

A unit test answers "does this function work". A security control fails on a different
question: "does everything that needs it call it". That is a property of the callers,
so only a check over the callers can hold it. Removing the validator line from
`cache_read` in a copy of the plugin turns the caller-side check red with the file,
line and function named.

## Prevention

- For any validator, sanitiser or authorisation check, count its production callers
  before trusting it. One caller for a general-purpose validator is a finding.
- When a reader is fixed, go and find its writer. The same untrusted value usually
  becomes a path in both directions.
- Make an attack fixture carry the payload in the field under test, not in a
  neighbouring field that is easier to reach.

## Related Issues

- `docs/solutions/logic-errors/a-test-can-pass-because-it-cannot-fail.md`
- PR #82 (feat(work): act from the ticket, ask when the choice is real)
