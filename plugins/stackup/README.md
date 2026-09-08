# stackup

Asks whether work should ship as a stack of dependent pull requests, at the two
moments the answer is still cheap to act on.

`gh stack` is newer than the models' training data. Agents carry no precedent
for it, so left alone they default to one branch per workstream forever. This
plugin puts the question in front of them.

## What it does

| Hook | Fires | Asks |
|---|---|---|
| `PostToolUse` on `Write\|Edit\|MultiEdit` | after a plan file lands in a `plans/` directory with two or more implementation units and no recorded strategy | name the layers now, while the dependency graph is fresh |
| `PreToolUse` on `Bash` | before a command that opens a pull request | last catch for work that never went through a plan |

Neither hook forces a stack, and neither ever blocks. They ask for a judgement.
**"One pull request, because this is one logical change" is a correct answer.**
The `stack-layers` skill carries the judgement itself.

Submitting and landing a stack are left to whatever already does that work.

## Design

Both hooks are command hooks. They decide mechanically and emit context only
when the condition holds, so the model does not run on every file write and
every shell command. The pull-request hook does no `git` or `gh` work until a
cheap string match has already passed, because it runs before every shell
command.

The gate is **default-deny on suppression**: anything it cannot classify fires
the ask. The asymmetry is the reason. An ask that fires when it need not costs
one line and announces itself. An ask that fails to fire costs the whole
feature and announces nothing.

## When a repository has stacked pull requests disabled

Record it once and the hook stays quiet there:

```
tools/stackup/capability.sh record-unavailable   # stop asking in this repo
tools/stackup/capability.sh forget               # start asking again
```

The record lives under `${XDG_STATE_HOME:-~/.claude/state}/stackup`, keyed by
the repository's origin URL.

## Requirements

`jq` must be on PATH. Without it neither hook can read its payload, and both go
quiet permanently — silently, like every other failure here. `STACKUP_AUDIT=1`
reports this specific case, so it is the first thing to check.

`git` is needed only for the pull-request hook's size check and the capability
record; without it the hook simply asks.

## When it is not asking and you think it should

Both hooks exit 0 on every path, so silence is indistinguishable from a broken
match. Set `STACKUP_AUDIT=1` and a suppressed decision reports itself along
with the reason it stayed quiet.

## Tests

```
cd tools/stackup && bats tests/stackup.bats
```

Needs bats 1.5 or newer (the suite uses `run --separate-stderr`).

Every assertion is on emitted output, never on exit status — an exit-code
assertion would hold whether or not the ask fired. There is no CI in this
repository, so the suite has to be run locally.
