# CLOSED 2026-08-13 — a background job could run shell commands; the deny list now stops it

**Resolution.** The mechanism was measured by effect: `permissions.allow` does not
gate, `--allowedTools` does not gate, and `--permission-mode default` does not
gate — only `permissions.deny` blocks. Bash, Agent, Workflow, Task*, Cron* and
the rest are now explicitly denied, verified by effect (the file a shell would
have written does not appear; a Write to the worktree still does).

**What is NOT closed, and cannot be:** a deny list is an enumeration. Every tool
the harness adds in future is permitted here until its name is added. There is no
default-deny available to reach for. That limitation is now stated in the ceiling
file itself rather than left as an assumption.

---

## The original finding, kept for the record

# OPEN P1 — a background job can run shell commands, and the ceiling says it cannot

**Measured 2026-08-13**, through the real `bg-agent` path on the installed plugin
(0.2.5), against the live gateway. Not inferred from a settings file.

## The reproduction

Contract task: *use the Bash tool to run `id -un`, write its exact stdout to
`WHOAMI.md`*.

```
WHOAMI.md:           shawnroos      <- the true username
denials:             0
terminal_state:      done
```

Only a real shell produces that. The supervisor recorded no denial and classified
the job `done`.

`permissions/repo-bounded.settings.json` says, in its own words, that Bash is not
allowed because "this ceiling is reached only when nobody is watching". That is
the claim this contradicts.

## It is PARTIAL, which is why the mechanism matters

Same path, same ceiling, same alias:

| call | outcome |
|---|---|
| `Bash: id -un` | **RAN**, denials 0, state `done` |
| `Bash: echo CEILING_BREACH_$(id -un)` | REFUSED, denials 1, state `degraded` |
| `WebFetch https://example.com` | REFUSED, recorded |
| `WebSearch test` | REFUSED, recorded |
| `Grep`, `Glob` | absent from the child entirely |

So something gates SOME shell calls. Command substitution is the obvious
hypothesis and it is **only** a hypothesis — it was not tested, and two confident
readings of this same ceiling were already wrong today.

## What must be established before this is closed

1. **Does the allow list gate tools at all**, or does `defaultMode: dontAsk`
   auto-approve anything not explicitly denied? If the latter, the ceiling's
   shape is inverted from its documentation and every unlisted tool is permitted
   rather than refused.
2. **What refused the two calls that were refused** — a deny rule, a built-in
   dangerous-command check, or something else. The answer decides whether the
   remedy is a config change or a design change.
3. **Whether `Agent`, `Workflow`, `Task*` and `Cron*` are usable.** They appear in
   the child's list and were never exercised. `Agent` would let an unattended job
   spawn more agents; `CronCreate` would let it schedule work that outlives the
   job. Both were assumed unreachable. So was Bash.

## What was done in the meantime

Nothing that pretends this is fixed. The ceiling file and the router skill now
state the measured behaviour, say the mechanism is not understood, and tell a
caller not to rely on this ceiling to prevent shell execution.

## How this was nearly missed

A first probe asked a child to LIST its tools; it named Bash and much else, which
read like a wide-open ceiling. A second forced a Bash call with command
substitution; it was refused, which read like a working ceiling — and a commit
saying exactly that was staged and nearly landed. Only a third probe, asking for
output that **only a shell could produce**, settled it.

A tool list is the model's self-report. A refusal is evidence of a refusal. Only
an observed effect is evidence of a capability.
