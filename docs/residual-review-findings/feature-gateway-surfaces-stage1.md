# Residual Review Findings — spawn Stage 1

Branch `feature/gateway-surfaces`, base `feature/gateway-plugin`. Recorded
2026-08-07. Everything P0–P2 was applied; this is what was deliberately left.

## Coverage, and what was not run

Four review passes ran: a simplify pass (reuse + efficiency in one context,
quality in another), a correctness pass, an agent-native pass, and a Fable pass
covering testing, maintainability and adversarial.

**Not run, and the reason:** the full `ce-code-review` roster would have been
five reviewers. The account had hit a monthly spend ceiling, and three earlier
agents had already died mid-unit on spend limits, so the roster was cut to two
(correctness, agent-native) and the three skipped lenses were handed to a single
Fable agent instead. `project-standards` was a legitimate skip — the only
`CLAUDE.md` in the repo sits under `plugins/clawcrush/` and governs nothing here.

**Independence caveat:** reuse and efficiency ran in one context, so their
agreement is not independent corroboration. Correctness, agent-native and Fable
each ran in their own.

## Applied, for the record

- **P1 — `stop` reported success while a gateway was serving.** Both the
  empty-pidfile and dead-pid branches keyed on the probe returning `EX_OK`, so a
  401 read as "nothing running". The dead-pid branch then deleted the pidfile
  while a gateway served. Now keys on `PROBE_LISTENING`; two tests, proven red.
- **P1/P2 — the families grammar had no consumer.** Declared in `models.json`,
  read by nothing. `--describe` now carries it.
- **P2 — `remedy` was dropped on two of three encoder tiers.**
- **P2 — `restart` printed `.error` where it meant the reason.**
- **P2 — the shim's not-installed response escaped the envelope.**
- **Pre-existing, fixed anyway — seven `emit` sites could exit silently.**

## Deferred — accepted for now

### Hardening, not holes

- **`esc()` does not escape newline** (`plugins/spawn/lib/common.sh`). A newline
  reaching the token through a `${VAR}` env expansion would break out of a
  quoted curl-config value. Only user-controlled env or config can carry one;
  the awk token readers are single-line.
- **The sanitizer deliberately keeps `\n`**, so multi-line upstream prose quoted
  into a stderr diagnostic can mimic the plugin's own `▸`/`✗` lines. No escapes
  are possible — this is spoofed *text*, and it is accepted residue per
  `sanitize.sh`'s own scope note. Prefixing continuation lines at the `die`/`say`
  chokepoint would close it.

### Divergence between siblings

- **The three scripts disagree on the no-jq enum for the identical condition:**
  `spawnctl`'s `need_jq` emits `error:"internal"`, lens and launch emit
  `"usage"`. Each script's `--describe` declares its own value, so it is
  documented rather than silent — but a fan-out caller wanting "install jq" has
  to branch on two enums. Changing an enum value is a contract change and was
  not worth doing unreviewed at this stage.
- **Two implementations of one env-expansion contract.** The attach command
  (`launch.sh`) expands only a whole-value `${VAR}`, while `expand_env_refs`
  (`common.sh`) expands embedded references anywhere in the string. A token
  written `prefix${VAR}` works in the probe, the lens and the seed, and 401s on
  attach. Already divergent; the test covers whole-value only.
- **`lens` backgrounds its `ensure` so traps stay live through lock-wait; `launch`
  runs the same call in a foreground command substitution.** No token or temp
  file is at stake in launch's case — only deferred cancellation — but it is a
  pattern the lens's own comment calls load-bearing, applied to one of two
  siblings.
- **Six bats suites carry near-identical private copies of `make_config` /
  `start_fixture` / the `refute_*` helpers, and the drift is already real:**
  `regressions.bats`'s `make_config` takes `(path, port, token)` where every
  other suite takes `(path, token, specs…)`. Each is correct in its own file; a
  copy-pasted call site across files is the trap. A shared `tests/helpers.bash`
  would close it.

### Test gaps

- **`lens`'s `emit_describe` under a poisoned env default** — the `num_or_null`
  guard exists for a named failure (`SPAWN_LENS_TIMEOUT=soon`) and has never
  fired in a test.
- **`--timeout abc`** on the lens (non-numeric, non-zero) is untested; `0` and
  `0.0` are covered, and launch covers `"ten"` for its env knob.
- **Nothing checks the lenses' `--describe` `response_fields` against a real
  success emit.** The agreement test covers exit codes and backticked names in
  both directions; the field lists are prose.

### Assumptions worth naming

- **`spawn::envelope_bash` scrubs the error enum with `${2//[^a-z_]/}`, which
  strips digits.** No current enum value contains one; a future one would
  silently degrade to an empty string on the no-jq tier.
- **The drift classifier rests on model-string identity being a valid proxy for
  "same model".** Verified true for all nine live twins at the time of writing —
  zero mismatches — but it is an assumption, not a proof, and nothing pins it
  against a case where it is false.

## Comment left stale on purpose

`launch.sh` hands the seed prompt to the child as argv, and its comment argues
secrecy. KTD8's actual rationale was quoting and length limits — a seed over
`ARG_MAX` dies as an exec failure and surfaces as `seed_failed`, exit 5. It fails
loudly enough to accept, but the comment answers an objection nobody raised.
