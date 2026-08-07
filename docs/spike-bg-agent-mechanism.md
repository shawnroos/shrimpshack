# Spike: can we actually build `bg-agent`?

Date: 2026-08-07. Run on macOS (darwin 25.3), login bash 5.3, `/bin/bash` 3.2.
Purpose: prove or kill the two mechanisms the plan leans on before writing
implementation units — detached supervision (OQ4) and a per-child permission
ceiling (R25).

**Verdict: both mechanisms work. One needs a dependency decision; one is
stronger than the plan claimed.**

## R25 — a child really can run narrower than its launcher

Tested with the real `claude` CLI, three arms, asserted **by file side-effect**
rather than by reading the model's prose.

| arm | settings | side effect | what the model said |
|---|---|---|---|
| control | `permissions.allow: ["Bash"]` | **file created** | "Done — created `sentinel_allow.txt`." |
| deny | `permissions.deny: ["Bash"]` | none | "this session has no Bash/shell tool available" |
| bare | no `--settings`, `--setting-sources project` | none | "The Bash call was denied — Claude Code is in don't-ask mode" |

Three findings:

1. **`--setting-sources project` strips the operator's own ceiling.** The bare arm
   was launched from a session whose user settings broadly allow Bash, and the
   child still could not run a shell command. Excluding `user` from the sources is
   the lever that makes a child narrower than its launcher — this is what R8's
   entry-point split should actually key on.
2. **`permissions.deny` and "not allowed" are different mechanisms.** A denied
   tool is *removed* — the model reports having no such tool and never attempts
   it. An unallowed tool under `--permission-mode dontAsk` is *present but
   refused* — the model tries and is turned down. Only the second produces a
   denial event a supervisor could observe. R9's degraded detection should key on
   the second; under the first there is nothing to detect because nothing is
   attempted.
3. **The first version of this test passed in both arms and proved nothing.** It
   asserted on the model's text, which quotes the command back, so the marker
   string appeared even in the refusal. Only a file side-effect distinguishes
   "ran" from "talked about running". Recorded because the same trap applies to
   the plan's own acceptance examples.

### The hollow success is real, not hypothetical

Every denied arm returned **`is_error: false`, exit 0, 2 turns**. A job whose
tool calls are entirely denied is indistinguishable from a job that did the work,
looking only at the exit status. R9 is not a speculative failure mode — it is the
default outcome of a misconfigured ceiling, and it is why the supervisor (R21)
cannot take the child's exit code as evidence of anything.

## OQ4 — detachment works, but `nohup` alone is not enough

| approach | survives launcher exit | own process group | verdict |
|---|---|---|---|
| `nohup … & disown` | yes (`PPID 1`) | **no — inherits launcher's** | fragile |
| double-fork + `os.setsid` | yes (`PPID 1`) | yes | correct |

**`nohup … & disown` is not sufficient.** The job was reparented to init but kept
the launcher's process group, and a group-directed `TERM` killed it. That is what
a terminal sends on close, and what a harness plausibly sends when a tool call's
process group is torn down. A job that dies when the session that started it
closes is not a background job.

`setsid(1)` **does not exist on macOS**. A true new session needs a double-fork
plus `setsid()` from an interpreter — `python3` or `perl` (base-macOS
`/usr/bin/perl` has `POSIX::setsid`).

**This is a dependency decision, not a detail.** `lib/*.sh` today needs bash, jq,
curl, awk and sed at runtime — verified: no `python` reference anywhere in
`lib/`. `python3` is declared only as a *test* dependency, for the gateway
fixture. Adding a runtime interpreter is the same class of objection the project
already rejected once for Node (`tests/run-tests.sh:14-18`, and
`docs/plans/2026-08-06-001-feat-gateway-plugin-plan.md:282`). `perl` is the
cheaper door if one must be opened, being present on a stock macOS.

Note the existing precedent carries the same weakness: `spawnctl.sh:694` starts
the gateway with `nohup … &`, so the gateway is also in the process group of
whatever started it.

### Supervision primitives that do work

- **Identity survives pid recycling.** `ps -o command= -p <pid>` matched the
  expected argv, which is the check `spawnctl.sh` already uses for the gateway
  (`pid_is_gateway`). Reusable as-is.
- **Reap escalation works.** `TERM` → poll at 0.1s → `KILL` reaped the job on the
  first tick. Same shape as `launch.sh`'s `reap_child` and `spawnctl.sh`'s
  gateway stop.
- **`wait -n` is unavailable** — `/bin/bash` is 3.2 and rejects it. The plugin has
  no bash-4 idioms today and a supervisor must not introduce one.

### The status file lies

After the job was killed, `status.json` still read `{"state":"running"}` — nothing
updated it, because the thing that would have updated it was the thing that died.
So R21's trusted fields cannot be *read from the file*: liveness has to be probed
(`kill -0` plus the argv check) and the file treated as a claim to verify. This is
the same conclusion `spawnctl.sh` already reached for the gateway, where liveness
is by probing the model-list endpoint rather than trusting the pidfile.

## What this settles in the plan

- **R25 is evidenced, and its mechanism is named:** `--settings` for the ceiling,
  `--setting-sources` excluding `user` for the strip, `--permission-mode` for the
  no-prompt guarantee.
- **R9's stall half is closed by construction** — a denied tool is removed or
  refused, never queued behind a prompt, so an unattended job cannot park. The
  degraded half is confirmed necessary: denial returns clean success.
- **OQ4's process-ownership half is answerable** — double-fork plus `setsid()`,
  pending the runtime-interpreter decision.
- **OQ4's concurrency half is untouched by this spike** and still open.
