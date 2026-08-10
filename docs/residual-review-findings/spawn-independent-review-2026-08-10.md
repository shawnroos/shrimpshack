# spawn — independent zero-context review, 2026-08-10

Three reviewers were dispatched into FRESH contexts with no project knowledge:
one on structure/quality, two on correctness (the second because the first went
quiet for a long stretch; both eventually reported, and their reports are
independent). A fourth ran a focused pass on `lens.sh`.

**They overlapped on exactly one finding** — `stop` reporting success without
verifying the process died. Everything else each found alone. That is the
argument for more than one lens, made empirically rather than asserted.

## Verdict at dispatch

The quality reviewer returned **DOES NOT CLEAR THE BAR**, failing criterion 4
(canonical-helper duplication) and narrowly criterion 5 (missed decomposition).
Both correctness reviewers returned **no P0 and no P1**.

Every P0/P1/P2 is now fixed. What follows is the record of the P3s, so none of
them is silently open.

## Fixed (all P0/P1/P2, plus the P3s worth doing)

| From | What | Guard |
|---|---|---|
| quality F-A3 | `launch.sh`'s jq and no-jq encoder tiers disagreed on their field set — a jq-less box answered with three fewer fields than `--describe` publishes. The new parity test then found a SECOND stale list the review had not cited. | `envelope.bats` compares KEY SETS between tiers; seen red against the real defect twice |
| quality F-A1 | `resolve_token_from_fallback` byte-identical in two files that both already source its home. The credential path, with the xtrace guard duplicated. | now `spawn::resolve_token` |
| quality F-A2 | `emit_error` (~40 lines) duplicated on the two axes `spawn::preflight_jq` already parametrizes. | now `spawn::emit_error`, taking ONE null-field list and deriving both spellings |
| quality F-A4 | 34 sites reported `error:"usage"` for ENCODER failures, handing back a remedy every clause of which is false for an internal fault. | now `internal`; does not touch the frozen exit-code enum |
| quality F-A5 | Five byte-identical `say()` definitions existing only to satisfy a lint that grepped for the text. | the LINT was fixed; a planted undefended file still fails all three checks |
| quality F-A6 | `setup.sh` restated five frozen-enum constants under a comment admitting nothing enforced it. | `surfaces.bats` pins the two sets equal, mutation-verified |
| quality F-B1 | `launch.sh` ran the identical `ensure` call with the opposite trap discipline to `lens.sh`. The ensure child holds the control lock and was never killed on TERM. | mutation-verified; the mutant does not even die on TERM |
| quality F-B2 | Half an extraction — the grammar jq defs were shared, the surrounding read-guard-fallback bash was not. | now `spawn::models_grammar`; `--describe` byte-identical |
| quality F-C3 | The worktree warning built JSON by hand; a quote or backslash in the path took the whole emit down. | jq `--arg`; proven with a path carrying both |
| quality F-D1/D2 | Two stale comments, one an orphan and one a load-bearing count that said 18 where the truth is 41. | replaced with a claim that cannot go stale |
| both correctness | `stop` reported `result:"stopped"` after SIGKILL without checking the process died, deleting the ownership record and making the gateway unstoppable. | mutation-verified on the pidfile-survival assertion |
| correctness #1 | `acquire_lock` livelock — the stale-break `continue` skipped both the sleep and the counter, making `LOCK_TIMEOUT` unreachable. | mutation-verified: with the `continue` restored the test HANGS |
| correctness #3 | `--rotate-openrouter-key` could report success over a gateway still holding the old key. | gated on `adoption_in_effect` |
| correctness #4 | Eight values baked as `'$var'` into a file launchd EXECUTES at login, plus three into a shell rc. An apostrophe made a syntax error that STILL PASSED `write_launcher`'s own grep and replaced the working file; `gwbin` comes from an operator-owned plist. | `jq @sh`; mutation-verified |
| correctness2 F2 | The same class in the `gw` wrapper. | escaped so an ordinary path stays byte-identical (no consent churn); hostile path proven inert |
| correctness2 F4 | `SPAWN_START_TIMEOUT` / `SPAWN_LOCK_TIMEOUT` reached bash arithmetic unvalidated, where `a[$(cmd)]` executes. | refused before arithmetic |
| correctness2 F3 | `detail` hardcoded null on the no-jq tier — inside the function whose header claims one-list derivation makes drift unrepresentable. | threaded through |
| correctness2 F5 | `spawn::resolve_token` always returned 0. | explicit return |
| correctness #5 | `cat > "$PROMPT_PATH"` unchecked: ENOSPC gives a PARTIAL prompt that passes the non-empty test, so a truncated diff is answered confidently and returned `ok:true`. | checked |
| correctness #6 | `gw claude` set `ANTHROPIC_AUTH_TOKEN` but not `ANTHROPIC_API_KEY`, so an operator's real Anthropic key was inherited and could reach the proxy. | both set |
| correctness #7 | `stop` opened with `resolve_install_dir hard`, so a renamed install made stop AND restart die exit 3 without signalling — a live gateway nobody can stop. | soft; mutation-verified |
| correctness #8 | One failing `jq` reset the whole R18 accumulator to `[]` and the run continued green, reporting `steps:[]` / `changed:[]`. | prior value preserved |
| correctness #11 | `--max-tokens 0` accepted by a check whose message says "positive integer". | refused, exit 2 |

## STILL OPEN — P3, recorded deliberately

- **`lens.sh` cleanup signals its child but never reaps it**, while the header
  claims "No orphan". `launch.sh` does it properly. curl dies on TERM promptly,
  so this is mostly a documentation overclaim — but the child on the preflight
  path is `spawnctl ensure`, whose own TERM trap is deferred while it sits in a
  foreground curl probe, so it can outlive `lens.sh` by seconds still holding
  the start lock. **Fix is the `reap_child` shape `launch.sh` already has.**
- **The launcher can delete a pidfile it no longer owns.** `claimed` is decided
  at start and acted on possibly days later; if the supervised gateway crashes
  and a `spawnctl start` claims the pidfile in the window before the exiting
  launcher reaches its cleanup, the launcher deletes the new gateway's record.
  The start-side mirror guard closes the other direction, not this one.
- **`setup-lib.sh` reads the caller's `$1` at source time** (`VERB="${1:-}"`).
  It works because all six entry points source before any `shift`, but nothing
  enforces it and the "SOURCED, never exec'd" header does not mention it.
- **The `gw` marker/hash scheme cannot tell "the operator edited this" from "an
  older setup wrote this".** Any change to the wrapper body makes every `gw` on
  disk classify as `modified` and demand consent for an upgrade. This already
  shaped a decision today: the F2 escaping was written to keep an ordinary path
  byte-identical specifically to avoid triggering it.
  **NOTE: the `gw claude` fix above DOES change the body**, so the next setup
  run on a machine with an existing generated `gw` will require
  `--consent-overwrite-gw`. That is the flaw showing its cost, not a new bug.
- **`write_launcher` greps its own generated output**, and `launcher_body`
  reimplements the control layer a third time. Owned by the audit's F1.
- **`remedy_for` in `spawnctl.sh` is a pure passthrough**; **`secrets.sh` has
  two dead duplicate `local -; set +x` pairs**; **`do_supervisor` assigns four
  variables as globals** in an otherwise fully-localized function. Cosmetic.

## Suspected but NOT confirmed — deliberately not acted on

The correctness reviewer listed these and declined to file them, which is the
right call and worth preserving:

- `SETUP_WIRED_JSON` has no empty guard where its sibling does — but no
  reachable trigger could be constructed.
- `run_bounded_out` evaluates an env value as bash arithmetic — but the same env
  already supplies the curl and cargo binaries, so no trust boundary is crossed.
- The gateway token in the seed child's exec environment LOOKS like it
  contradicts the argv ban, but KD3 explicitly sanctions env delivery for THIS
  token and reserves the prohibition for the OpenRouter key, which genuinely
  never travels that way. The reviewer flagged it, then withdrew it.
- SIGKILL leaves the mode-0600 `.env.local` behind. Unavoidable without a
  reaper; the next `deliver_secrets` removes it.

## What the reviewers independently confirmed as strong

Recorded because a verdict with no calibration is a mood, not a judgement: the
lock-break race handling (with the original 8-worker reproduction), pid identity
anchored to argv position with `--config` required, the whole of `secrets.sh`
(the read-back byte compare, `-g` forbidden, the bounded delete loop), the
mode-0600 `curl --config` credential delivery on all three paths, `emit()`'s
empty-payload refusal, identifiers closed by construction before use, and the
trap shape in all five executables.

The quality reviewer also **independently verified the `spawnctl.sh` size
justification** — "the yardstick was committed to before the answer was known" —
and **overruled one**: the `say()` lint rationale, which it called circular. It
was right, and the lint was changed.
