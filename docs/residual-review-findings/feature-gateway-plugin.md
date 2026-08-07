# Residual review findings — feature/gateway-plugin

Six reviewers ran over this branch (correctness, security, reliability, testing,
agent-native, adversarial). Seven P1s were fixed in `3fc410c` with 11
mutation-verified regression guards. What follows is everything that was **not**
fixed, so it is durable rather than buried in a session transcript.

## Reviewer independence — read this before weighing agreement

The cross-model adversarial peer **could not start**: no sanctioned peer CLI is
installed on this machine. The local `adversarial-reviewer` ran as the fallback
and was told it was not an independent-provider check.

So every reviewer here is a same-model sibling. Where several converged on one
finding, that is corroboration of *reading*, not independent confirmation. The
findings that should carry weight are the ones reproduced by execution — exit
codes, byte counts, an 8-worker race run five times — and those are marked below.

This is worth noticing on its own terms: the gap is exactly the one this plugin
exists to close, and this run is a live demonstration of the cost.

Two other reviewers were skipped with disclosure: `project-standards` (no
CLAUDE.md/AGENTS.md anywhere in the repo) and `maintainability` (`ce-simplify-code`
had just run reuse/quality/efficiency reviewers over exactly this code).

## Open — worth doing

| # | Where | What | Severity |
|---|-------|------|----------|
| R1 | `lens.sh:223` | `--timeout 0` passes validation and `curl --max-time 0` **disables** the deadline. Measured: 29s hang then rc=56, classified exit 3, not exit 6 — so the value a caller reads as "no artificial limit" is an unbounded hang in unattended fan-out. `GATEWAY_CONNECT_TIMEOUT` is unvalidated entirely. | P2 |
| R2 | `launch.sh:340` | The seed run has no deadline and does not retain the child pid, so a caller-imposed timeout orphans `claude` — reparented to init, still holding the token in its environment. The in-file rationale against a watchdog applies to a *detached* one; a parent that waits and reaps has no such window, and `stop` already implements that TERM/poll/KILL pattern. | P2 |
| R3 | `lens.sh:265`, `launch.sh:245` | Exit 7 reaches consumers in two incompatible shapes depending on whether it came from preflight or the messages call — preflight forwards gatewayctl's `{verb, error:<prose>}` object, which has no `text`/`usage`/`detail` and puts prose where the enum value belongs. Breaks `.error` branching exactly when all N fan-out callers fail at once. | P2 |
| R4 | `gatewayctl.sh:507` | `pid_is_gateway` is an unanchored **substring** match on the resolved binary path. Fails open (a `tail`/`less`/editor whose argv merely mentions the path is "ours" and gets SIGTERM then SIGKILL) and fails closed after an upgrade (`resolve_install_dir` always picks the newest `~/gateway-*`, so a running older gateway stops being recognized — permanently). Suggested: record the binary path beside the pidfile at start and verify argv[0] against *that*. | P2 |
| R5 | `gatewayctl.sh:432` | The probe reads any non-200 from a **live** gateway as down, so a 503 during startup or a 404 from a moved route triggers a second start against a held port. curl already returns rc=0 with a real status, which proves something is listening — that information is discarded. | P2 |
| R6 | `escapes.bats:603` | The terminal-sink lint is line-scoped: a block redirect (`{ printf ...; } >&2`) and `> /dev/stderr` both pass. Verified on planted files. The self-test plants only the shape the lint already catches, so it proves the detector fires, not that its scope covers the class it is named for. | P2 |
| R7 | `launch.bats:528` | The R12 no-write lint matches redirection syntax only — `cp`, `tee`, `sed -i`, `yq -i` against `$CONFIG_PATH` all pass. No self-test. | P2 |
| R8 | `launch.sh:377` | The `is_error=true` branch (CLI exits 0 but reports a failed turn) has no test **and no fixture mode that can reach it** — `fake-claude.sh` hardcodes `is_error: False`. Deleting the branch leaves the suite green while launch hands back handles to failed sessions. | P2 |
| R9 | `README.md:26`, `:126` | Every documented invocation uses `${CLAUDE_PLUGIN_ROOT}`, which resolves to the *calling* plugin's root — so the documented form does not work from the foreign-plugin consumers the plugin says it is built for. The allowlist paragraph asserts it matches that invocation form; it does not. A mismatched rule shows up as a silently hanging fan-out, not an error. | P2 |
| R10 | `skills/launch/SKILL.md:65` | The "what a gateway-pointed session does not have" list omits the one difference that changes the trust posture: unlike the lens, launch runs a **full agent loop** under the user's normal permissions, in the pinned project dir, driven by a third-party model. Documentation only — the behaviour is the feature. | P3 |

## Open — accepted or judgement calls

- **Spill files are never reaped.** `gwlens-response.*` is deliberately outside
  `TMPWORK` because it is the return value; nothing deletes it afterwards. Mode
  0600, same user. Fine as designed; needs a reaping story if this ever runs on
  a shared box.
- **The seed prompt goes through argv** (`launch.sh:340`). KTD8's own argv-length
  reasoning applies, and it routinely carries repo content. Fails loudly on
  E2BIG rather than truncating, and the scope of the argv ban is recorded in the
  code as token-only.
- **`classify_overflow` matches five phrasings** of one provider's wording. A
  provider that words it differently collapses into the generic upstream class —
  the precise misclassification the branch exists to prevent. Not resolvable
  without the real error envelope.
- **`self_check` proves bats can fail, not that `run_suite` propagates it.** The
  swallowing would happen in `run_suite`'s if/else, which `self_check` bypasses.
  Verified honest by hand; the check simply does not assert it.
- **`secret_scan`'s exact-token layer is inert on any box with no gateway
  installed.** Loud skip, correct for R11, but with no CI the layer only runs if
  whoever merges happens to have a gateway.
- **A `RETURN` trap survives in `self_check`** (`run-tests.sh:98`) — the sibling
  function documents this hazard and avoids it. Harmless only because `main`
  ends in `exit`.

## Known: a credential in the working tree

`docs/handoff.md` contains the live gateway token, twice. It is **not** in HEAD,
not in `origin/main`, and `git log -S` finds it in no commit on any branch — so
nothing is published. It was found by widening the secret scan to the repo, and
the previous plugin-scoped scan could not have seen it. No prefix heuristic would
either: the token is 15 characters and word-shaped.

Deferred by explicit decision. Every commit on this branch was scoped by path;
`git add -A` was never used. The scan now warns on this state and fails only when
such a file is staged or committed.

**Next action if picked up:** scrub the token from `docs/handoff.md`, and rotate
it in `~/gateway-0.1.1/gateway.yaml` if that file has ever been shared or synced.

## Testing gaps worth closing

- No test drives two concurrent `ensure` calls against a down gateway and asserts
  exactly one gateway resulted — the single most load-bearing claim for the
  fan-out workload, currently asserted only in a comment. The new lock fix is
  guarded by reasoning and a reproduction, **not** by a test.
- No test kills a script mid-flight with TERM/INT and asserts the credential dir
  is gone. The fix was verified by hand (leftover dirs 1 → 0); nothing guards it.
- No test passes `--timeout 0`.
- No test exercises the `--flag=value` half of any argument parser — roughly half
  the parse surface across all three scripts.
- The fixture's Bearer-token path is never exercised; every test authenticates
  with `x-api-key` while the plugin sends both headers, so neither header is
  individually load-bearing in any assertion.
