---
title: "Exporting an empty credential is worse than exporting none — and a header comment is not the enforcement"
date: 2026-08-13
module: plugins/spawn
problem_type: logic_error
component: tooling
severity: critical
category: logic-errors
symptoms:
  - "every `/spawn:bg-agent` job died within seconds with `401 authentication failed`"
  - "the failure carried an EMPTY `permission_denials` array — the 401 lands before any tool call, so there is nothing to attribute it to"
  - "sibling surfaces (`lens.sh`, `launch.sh`) worked fine against the same gateway, which read as \"the gateway is up, so it must be the job\""
  - "the bug only appears when `server.token` is ABSENT from gateway.yaml — a config with the key present hides it completely"
root_cause: logic_error
resolution_type: code_fix
related_components:
  - development_workflow
  - testing_framework
tags:
  - credentials
  - empty-string
  - shared-helper
  - default-deny
  - gate-not-a-comment
  - spawn
---

# Exporting an empty credential is worse than exporting none — and a header comment is not the enforcement

## Problem

Every background job launched through `/spawn:bg-agent` died within seconds with a
401. `bg-agent.sh` and `ceilings.sh` read the gateway token **only** from
`server.token` in `gateway.yaml`. When that key is absent the variable is the empty
string — and both surfaces exported `ANTHROPIC_AUTH_TOKEN=""` to the child anyway.
The CLI **uses** an empty explicit token rather than treating it as unset and falling
back to its own credentials, so it authenticates as nobody and 401s before running a
single tool.

## Symptoms

- `401 authentication failed`, immediately, on every job.
- `permission_denials: []` — empty, because the failure precedes any tool call. The
  usual "what did it try to do" diagnostic has nothing in it.
- `lens.sh` and `launch.sh`, hitting the same gateway with the same config, worked.
  They call the shared `spawn::resolve_token` (`plugins/spawn/lib/secrets.sh`), which
  walks env → Keychain when the config yields nothing.
- **Three real jobs died this way in three separate worktrees and nobody was told** —
  one of them an adversarial code review that the PR then merged without.

## What Didn't Work

- **Reading the surfaces side by side.** All four look correct in isolation; the two
  broken ones simply stop one step earlier than the two working ones. Nothing in
  `bg-agent.sh` looks like a missing step until you know the chain has four links.
- **Testing with a populated config.** The defect is a property of the *absent* key.
  Any fixture that sets `server.token` passes against the buggy code.
- **`secrets.sh`'s own header comment.** It already documented this exact bug, noted
  it had shipped **once before**, and concluded *"One chain, one place, is the
  enforcement."* It was not enforcement. Two surfaces written afterwards read the
  token directly and reproduced it verbatim.

## Solution

Route both surfaces through the shared chain — source `secrets.sh` and call
`spawn::resolve_token` **after** the config read, so a config-derived token still
wins and the env/Keychain fallback only fills a gap:

```sh
# plugins/spawn/lib/bg-agent.sh
[ -n "$TOKEN" ] || spawn::resolve_token "$KEYCHAIN_SERVICE" "$KEYCHAIN_ACCOUNT_TOKEN"
```

Then add the gate the header comment had only asked for — a bats test that walks
`lib/*.sh`, finds every file that hands `ANTHROPIC_AUTH_TOKEN` to a child, and fails
unless that file also names the shared helper
(`plugins/spawn/tests/unit/surfaces.bats`).

Two things about that gate are load-bearing and were both got wrong first:

1. **Discovery must be wider than one spelling.** `export VAR=`, `declare -x`, and a
   bare `VAR=` prefix all hand a credential to a child. Matching only `export` lets
   the next surface evade the gate by writing it differently — the same
   narrower-than-the-invariant failure the gate exists to close.
2. **Strip comments once, then run BOTH tests on the stripped text.** The first
   version greped the raw file, so an *inline comment* naming the helper satisfied it
   — the gate certified prose. The obvious fix, `sed 's/#.*$//'`, is a regex and not a
   shell lexer: it turns `[ "$#" -gt 0 ] && export TOKEN=...` into `[ "$`, destroying
   a real exporter and **recreating the exact false-pass class the fix was for**. Drop
   whole-line comments, then cut only at whitespace-hash, which leaves `$#` and
   `${v##*/}` intact.

The gate also asserts it found at least one real exporter, so it cannot pass
vacuously if the glob ever matches nothing.

Landed in #44 (spawn: bg-agent 401'd on every job because two surfaces skipped the
shared token chain). Shipping it took a version bump too — see Prevention.

## Why This Works

Three distinct properties, and the fix needed all three:

- **An empty credential is not a missing credential.** Downstream tools distinguish
  "unset" from "set to empty"; only the first triggers their own fallback. So the
  guard is `[ -n "$TOKEN" ] || …` at the *export* boundary — never export a variable
  you resolved to nothing. Silence beats a wrong answer.
- **The last mile has to be shared, not just the chain.** `lens.sh` and `launch.sh`
  had already duplicated `resolve_token_from_fallback` byte-for-byte, in two files
  that both source `secrets.sh`. Sharing the *helper file* is not sharing the
  *behavior*.
- **A comment naming a rule is a note; a test is a mechanism.** The rule was written
  down, and written down is exactly how far it got.

## Prevention

- **Never export a resolved-empty credential.** Guard at the export, not at the read.
  Treat `VAR=""` handed to a child as a defect on sight.
- **When a header comment states an invariant, write the gate in the same commit** —
  or change the comment to say the invariant is unenforced. This bug shipped twice
  under a comment claiming otherwise.
- **Test the ABSENT-key case.** A fixture that always populates the config cannot see
  a bug whose trigger is the key not being there. Same shape as
  `docs/solutions/logic-errors/default-allow-regex-projection-gate-silently-drops-nudges.md`
  — the surface is everything nobody thought of.
- **Measure which tests are load-bearing; do not count them.** Four behavioral tests
  were written for this fix. Reverting the fix in a copy of the plugin and re-running
  showed **one** went red — one was short-circuited by a preflight, one never hit the
  absent-key path, one was a control. Copy the tree, revert the fix, count the reds.
  That number is the coverage claim.
- **Merging a plugin fix does not ship it.** `/plugin update` compares only the
  version string, so merged code at an unchanged version leaves every install
  reporting "up to date". This incident needed 0.2.0 → 0.2.1 to reach a machine, and
  the two follow-on fixes needed 0.2.2 and 0.2.3.
- **Known holes in the gate, deliberately not papered over** (documented in the test
  itself): dead code passes, call ordering is unchecked, indirection is blind, and a
  call inside an uninvoked function still counts. Closing those wants a behavioral
  test — run each surface against a fake `claude`, a fake config, and a fake Keychain
  and assert on the child's environment. Widening the lexical alternation a fourth
  time would not close it.

## Related Issues

- `docs/solutions/logic-errors/default-allow-regex-projection-gate-silently-drops-nudges.md`
  — same class: enumerating permitted forms is default-allow.
- `docs/solutions/workflow-issues/test-count-subtraction-reconciliation-is-weaker-than-passing-parity.md`
  — test counts as a weak proxy for what is actually verified.
- PR #44 (spawn: bg-agent 401'd on every job because two surfaces skipped the shared
  token chain); follow-ons #46 (size-ceiling 502 gets its own error class) and #47
  (tell the user when a background job finished).
