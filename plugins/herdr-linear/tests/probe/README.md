# U1 — grounding channel probe

Run by hand. Produces evidence, not a feature. It exists because nothing in this
repo had ever exercised `SessionStart` context injection, and `plugins/reflect`
records that raw stdout injects for `UserPromptSubmit` only.

## Verdict: the channel is REAL

`hookSpecificOutput.additionalContext` on `SessionStart` reaches the model on this
build. Phase B is unblocked and the `UserPromptSubmit` fallback is not needed.

Run on 2026-09-04 against Claude Code with `--model haiku`, in an
isolated `--settings` file so no global configuration was touched.

## How it discriminates

Both tokens are emitted in **one JSON object on stdout**: one under
`hookSpecificOutput.additionalContext`, one under a sibling key
(`herdrLinearDecoy`) that no hook contract names.

| Observation | Meaning |
|---|---|
| only the live token returns | the channel is real — **this is what happened** |
| both tokens return | the harness is dumping raw stdout; the channel is NOT proven |
| neither, control works | `SessionStart` cannot inject |
| neither, control fails | inconclusive — blocks Phase B |

A single token could not tell the first case from the second, because raw stdout
and `additionalContext` both put text in front of the model.

Observed: the model returned `PROBE-LIVE-<token>` and did **not** return
`PROBE-DECOY-<token>`. The `PostToolUse` control was therefore not needed; it is
only decisive when `SessionStart` fails.

## What the SessionStart payload carries

```
cwd              /Users/.../herdr-linear-plugin
hook_event_name  SessionStart
session_id       <uuid>
source           startup
transcript_path  /Users/.../<session>.jsonl
```

Two consequences for the plan:

- **`cwd` is present.** U6 resolves the worktree from the payload rather than
  `$PWD`. The plan recorded this as unknown.
- **Nothing distinguishes an interactive session from a headless one.** This run
  was `claude -p` — fully headless — and reported `source: startup`, the same
  value a normal interactive start reports. R6's fail-closed default is not a
  precaution; it is the only available position, and no field can be read as a
  positive interactivity signal.

## Re-running it

```bash
plugins/herdr-linear/tests/probe/session-start-probe.sh   # not run directly; see the settings shape below
```

Register it on `SessionStart` in a scratch settings file with
`HERDR_LINEAR_PROBE_DIR` set, then ask a throwaway session to echo any string
beginning with `PROBE-`. Compare against the `.tokens` file the hook writes.

Note: `timeout` does not exist on this machine and returns success without
running the command. Do not wrap the probe in it.
