---
title: "Read a session's permission refusals from the transcript, not from hooks"
date: 2026-10-19
module: plugins/auto
problem_type: architecture_pattern
component: tooling
severity: medium
category: architecture-patterns
applies_when:
  - "code must know that a Claude Code session was refused a tool call and which layer refused it"
  - "a design relies on PermissionDenied, PostToolUse or PostToolUseFailure hooks to observe refusals"
  - "a hook runs on every Bash call only to feed a downstream check"
symptoms:
  - "deny-rule and dontAsk refusals fire no hook at all, so a hook-based capture misses them"
  - "each hook row had to be confirmed against the transcript, adding a confirm step and a report verb"
root_cause: wrong_api
resolution_type: code_fix
related_components:
  - development_workflow
  - testing_framework
tags:
  - permissions
  - transcript
  - hooks
  - permission-decision
  - reason-type
  - programme
  - dont-ask
  - deny-rule
retire_when: "Claude Code stops writing permissionDecision on Bash tool_result rows, or a hook starts firing for deny-rule and dontAsk refusals; re-run the spike in plugins/auto/tests/fixtures/permission_observed.md to check"
---

# Read a session's permission refusals from the transcript, not from hooks


## Context

Programme (`plugins/auto`) must know when a worker Claude Code session was refused a Bash command, and which layer refused it. Programme proposes an allow rule only for refusals that a settings-file allow rule can lift.

The first build used plugin hooks. `PermissionDenied` journaled auto-mode denials. `PostToolUse` and `PostToolUseFailure` on Bash journaled `gh` runs. Because workers run as the same user and could forge journal rows, every hook row was re-confirmed against the session transcript.

A live spike on Claude Code 2.1.303 (recorded in `plugins/auto/tests/fixtures/permission_observed.md`) showed the hook layer was both incomplete and redundant:

- A deny-rule refusal and a `dontAsk` refusal fire no `PermissionDenied`, no `PostToolUse` and no `PostToolUseFailure` (fixture row 7, line 13).
- The transcript already holds the runtime's own ruling for every case. The user row after a `tool_use` carries `permissionDecision {decision, source, reasonType}` and `toolDenialKind` (fixture lines 24-32).

Of the four denying layers (mode, classifier, deny rule, PreToolUse hook), the hooks were documented to report only the classifier, and the spike never saw even that one fire. The confirm step re-read the transcript anyway.

## Guidance

Read the ruling from the transcript. Do not infer it from hooks, refusal text or `is_error`.

1. Get the path from the session registry, never from a caller. `path_for` (`plugins/auto/lib/permission_transcript.py:37-41`) returns the registered `transcript_path` only if its basename equals `<session id>.jsonl`. A forged path could name a transcript its author wrote.
2. Pair each Bash `tool_use` with its result row. `tool_uses` (`plugins/auto/lib/permission_transcript.py:103-127`) keys uses by `tool_use` id, then fills the ruling from the following user row's `tool_result` through `runtime_ruling`. A use with no result row stays `answered: False`.
3. Take the decision first. `runtime_ruling` (`plugins/auto/lib/permission_transcript.py:90-96`) accepts only `accept` or `reject` as the ruling; anything else is `None`. A result row with no `permissionDecision` is unconfirmed, not denied.
4. Route by `reasonType` using `LAYERS` (`plugins/auto/lib/permission_transcript.py:25`):

| reasonType on a reject | Layer | Proposable? |
|---|---|---|
| `mode` | mode | yes |
| `classifier` | classifier | yes |
| `subcommandResults` | deny rule | no |
| `hook` | hook | no |
| anything else | unknown | no, explain only |

`PROPOSABLE = ("mode", "classifier")` (line 27) holds the layers an allow rule can lift. An allow rule does not override a deny rule or a PreToolUse hook (`NEXT_ACTION`, lines 28-34).

5. For an unknown layer, say so and propose nothing. `_propose_one` (`plugins/auto/lib/programme_permission.py:138-146`) records a note (`unknown_cause` or `not_proposable`) and returns no proposal when the layer is not proposable. It never guesses a rule.

The first build's hook that fired on every Bash call, its confirm step and a worker report verb were removed before merge. Evidence now comes from one source.

## Why This Matters

- Completeness: the transcript covers all four layers. Hooks could report at most the classifier, and silently missed deny-rule and `dontAsk` refusals. A hook-only reader would settle those cases as "retry unobserved".
- Trust: the transcript is the runtime's own record. A hook journal needs a second check against it; the transcript needs none.
- Cost: removing a per-Bash-call hook removes runtime overhead and one more forgeable store.

## When to Apply

- Any tool that must know why Claude Code refused a command, not only that a command ran.
- Any case where hook events and the transcript could disagree. Prefer the transcript when it carries the runtime's ruling.
- Not for events that the transcript does not record. Hooks remain the right layer for those.

## Examples

Gotchas, each found in the spike or the code:

1. `subcommandResults` appears on both an allow-rule accept and a deny-rule reject (fixture lines 28 and 31). Read `decision` first. `LAYERS` maps it to "deny rule" only on a reject row, and `_refusals` keeps only `ruling == "reject"` uses (`plugins/auto/lib/programme_permission.py:62`).
2. `is_error` is `true` for both a refusal and a red-CI run (fixture line 34). A `gh` run that exits 8 is `accept` with `is_error: true`. Never use `is_error` to detect a refusal.
3. The classifier reject shape (`reasonType: "classifier"`, `decision: "reject"`) was never observed live. In auto mode the classifier allowed `gh pr merge 7 --squash` against the stub, so no honest run produced a denial (fixture lines 10 and 41). The code treats any `reject` as a denial and maps an unrecognized `reasonType` to `unknown`. Treat the classifier path as unverified live.
4. `PostToolUseFailure` still fires for a command that ran and exited non-zero (fixture line 9). It reports a failed run, not a refusal.
5. Scan only new history. `_refusals` (`plugins/auto/lib/programme_permission.py:45-62`) keeps a per-session byte cursor in `permission_scan`. It counts only uses ruled after the session joined the item, and re-reads any use still waiting for its result row (line 61). `rows` returns `None` over the 64 MiB cap (`TRANSCRIPT_CAP`) so an oversized file is never read as "no refusals".

Row shapes (from fixture lines 26-32):

| Case | permissionDecision | toolDenialKind |
|---|---|---|
| Ran, exit 8 | accept / config / subcommandResults | null |
| Ran, approved by classifier | accept / config / classifier | null |
| Refused by `dontAsk` | reject / config / mode | permission-rule |
| Refused by deny rule | reject / config / subcommandResults | permission-rule |
| Refused by PreToolUse hook | reject / hook / hook | permission-rule |

## Related

- `docs/solutions/best-practices/default-deny-for-an-unattended-agent.md`: what an unattended session refuses and how to bound it. Its note that a deny path rule leaves no `permission_denials[]` entry is true of that list only; the transcript row still records the refusal and its layer.
- The change lives on branch `feature/programme-permission-proposals` (unmerged as of this writing).
