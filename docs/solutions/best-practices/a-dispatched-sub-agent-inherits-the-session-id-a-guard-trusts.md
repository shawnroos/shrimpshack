---
title: "A dispatched sub-agent inherits the session id a guard trusts"
date: 2026-10-22
category: best-practices
module: plugins/auto
problem_type: best_practice
component: tooling
severity: high
applies_when:
  - "a guard decides who may run a command by comparing CLAUDE_CODE_SESSION_ID to an owner session"
  - "an agent that owns a resource dispatches sub-agents with the Agent tool and gives them Bash"
  - "writing a hook or guard that must tell a sub-agent's tool call from the main session's"
  - "a command filter lists the forbidden forms of a call and allows everything else"
symptoms:
  - "a skill says a sub-agent's write is refused, and the write succeeds"
  - "a deny filter passes once the command is wrapped in python3 -c, bash -c, eval or a reordered flag"
root_cause: "the session id is shared with every sub-agent, so it identifies the session, not the actor"
resolution_type: code_fix
related_components:
  - testing_framework
tags: [sub-agent, agent-id, session-id, pretooluse-hook, default-deny, unattended-agent, enumeration, identity]
---
# A dispatched sub-agent inherits the session id a guard trusts

## Context

The auto programme lets only its driving session run write verbs. `_guard` in
`plugins/auto/lib/programme.py:232-235` reads `driver_session.driving_session_id()`
(`plugins/auto/lib/driver_session.py:44`), which is `CLAUDE_CODE_SESSION_ID`, and refuses
any other session. The sweep skill told the PM that a dispatched Agent "has its own session
id, and every write verb refuses it".

That was false. A sub-agent dispatched with the Agent tool inherits the parent's
`CLAUDE_CODE_SESSION_ID`. This repo had already recorded it from a live check on
2026-09-11 (`docs/plans/2026-09-11-1404-feat-data-presentation-report-templates-plan.md:145`),
and a review sub-agent confirmed it again on 2026-10-20 by reading its own environment. So
every programme write verb accepted a sub-agent. The gap became real when the quiet-PM work
(`docs/plans/2026-10-20-1250-fix-programme-quiet-pm-plan.md`, KTD10) pinned cheaper agents
for sweep reads and gave them Bash.

## Guidance

**1. Do not identify an actor by a value it inherits.** `CLAUDE_CODE_SESSION_ID` says which
session a call belongs to, not whether the main agent or a sub-agent made it.
`CLAUDE_CODE_CHILD_SESSION` cannot tell them apart either; it is `1` in the main session's
Bash calls too. This is the same family as
[a switch that restrains an agent cannot be read from the agent's environment](a-switch-that-restrains-an-agent-cannot-read-the-agents-environment.md):
the restrained actor controls or shares the value the guard reads.

**2. Use the field Claude Code sets per call.** Claude Code adds `agent_id` and `agent_type`
to PreToolUse hook input when a sub-agent makes the tool call (the Claude Code sub-agents
docs, "Hook locations"). The auto guard is a PreToolUse hook on Bash,
`plugins/auto/lib/on-pretooluse-subagent.py`, that acts only when `agent_id` is present.
`plugins/auto/lib/on-pre-compact.py:32` already read the same field for a different event.

**3. Scope it to the sessions that need it.** The hook acts only when the parent session
drives a programme (`_drives_programme`, `on-pretooluse-subagent.py:119`). Without that
gate it would also block every other session's sub-agents from running auto's own tests,
whose file names contain "programme".

**4. Default-deny, never list the bad forms.** The first version denied a call when a token
ended in `programme.sh` or `programme.py` and the verb was not a read. Review found three
bypasses in that version:

- an inline `python3 -c` that imports `programme` and calls `programme._cli([...])`, which
  never names the script;
- `gh --repo o/r pr merge 5`, because the merge check was a literal `gh pr merge` regex;
- `gh api -X PUT repos/o/r/pulls/5/merge`.

The fix inverts the rule (`_segment_refusal`, `on-pretooluse-subagent.py:77`). A command
that mentions programme code passes only as a direct `programme.sh` call whose first
argument is a read verb (`READ_VERBS`, line 17), or as a read-only viewer (`VIEWERS`,
line 18, plus read-only git subcommands). Everything else that reaches programme code is
refused, including `bash -c`, `eval`, heredoc Python and a verb placed after a flag. gh is
parsed per segment: `gh pr` subcommands other than reads are refused, and `gh api` is
allowed only as a GET. This matches
[default-deny for an unattended agent](default-deny-for-an-unattended-agent.md).

**5. Test the routes, then prove the tests can fail.** `plugins/auto/tests/unit/pretooluse-subagent.test.sh`
pins every bypass found, the allowed reads, the gate (lines 106-108 run an inline write
from a session that drives no programme and expect it allowed), and parse failure. Each
branch was mutation-checked. Removing the gate, widening the viewer list, allowing gh pr
writes or dropping the eval branch each turns at least one case red. The eval check first
survived its mutation, because another path also denied a programme write behind eval; a
gh write behind eval (line 70) is the case only that branch catches.

## Why This Matters

A guard built on an inherited identity looks like it holds: the main session's tests pass
and the skill text says sub-agents are refused. Nothing fails until a sub-agent, steered by
a worker's message or its own drift, runs a write. Here that write could mark an ask as
shown so the PM never posts it, or record an approval on Shawn's behalf.

## When to Apply

- Any guard that keys on `CLAUDE_CODE_SESSION_ID` and runs where sub-agents exist.
- Any hook meant to restrain dispatched agents: key it on `agent_id`.
- Any command filter written as a list of forbidden forms. Invert it before it ships.

## Examples

```text
# Denied for a programme PM's sub-agent (agent_id present):
python3 -c 'import programme; programme._cli(["ask-shown", "i"])'
bash -c 'bash .../programme.sh drop-item x --reason y'
gh --repo o/r pr merge 5
gh api -X PUT repos/o/r/pulls/5/merge

# Allowed:
bash .../programme.sh status --json --run prog-1
cat lib/programme.py; git diff -- lib/programme.py
gh pr view 12 --json state
```

The hook does not stop an agent with a Write tool from editing programme home files
directly. The pinned auto agents get no Write tool, and
`plugins/auto/tests/smoke/agents.test.sh` checks that each agent file declares an
explicit tool list.

The sweep packager is the one agent that writes, and it writes with the Write tool, not
through Bash. The hook checks `Write`, `Edit`, `MultiEdit` and `NotebookEdit` by path: inside
a programme home only `<home>/sweep-digest.md` is allowed, with symlinks and `..` resolved
first. From Bash, a command naming programme code may not redirect output except to
`/dev/null`, a newline starts a new command, `--pre`, `--output` and `-O` are denied, and
shell expansion (`$(...)`, backticks, `<(...)`, `${...}` other than `${CLAUDE_PLUGIN_ROOT}`)
and environment prefixes are denied.

The first design let the packager write its digest with `cat > <home>/sweep-digest.md <<'EOF'`
and stripped heredoc bodies before tokenising. Two review rounds found a way around it each
time: a heredoc opener inside quoted text hid the next line, a newline never split commands,
`f>path` skipped a token-anchored redirect check. A write that has to pass through shell
parsing is a list of forms to enumerate. Give the agent a tool whose target the hook reads as
a path, and the shell never sees the digest at all.

## Known limits (open)

The Bash side of the hook is a best-effort filter, not a sandbox. It judges one command at a
time and engages only when a token contains the substring `programme`. An adversarial review
(2026-10-28) showed these still pass, and they predate the packager:

- A pipe into a shell or interpreter whose own segment names no programme code, such as
  `cat <home>/sweep-digest.md | sh` or `... | xargs rm`. A sub-agent that can write the digest
  can therefore run the digest.
- `gh api` method spellings the check does not read (`-XPUT`, `--method=PUT`), `git push`,
  `gh issue close` and `gh alias set` followed by the alias.

Closing this needs a different shape, not another regex: either a per-agent tool allowlist so the
packager has no Bash at all (reads would go through a read-only verb that returns the digest
inputs), or an allowlist of whole commands. Until then, treat a sub-agent that reads untrusted
programme text as able to run any command.
