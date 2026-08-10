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

## Resolved since this document was written

All ten numbered findings are now fixed. R1 and R4 landed in `2b4ab3b`; the
rest landed in the residual-fix round of 2026-08-07. Every behavioural fix has
a regression guard that was mutation-verified (fix reverted → test red → fix
restored → green); the two lint findings are guarded by plant-based self-tests
instead — the same evidence in lint form. R9/R10 are documentation and were
verified by reading, with the one unverified point named in the table.

| # | Where | What was fixed | How it is guarded |
|---|-------|----------------|-------------------|
| R1 | `lens.sh` | `--timeout 0` and a non-positive `GATEWAY_CONNECT_TIMEOUT` are refused with exit 2 instead of disabling curl's deadline (`2b4ab3b`). | validation guards in `lens.sh`; launch's sibling knob got the same treatment under R2 |
| R2 | `launch.sh` | The seed run now runs in the background with a parent-owned deadline (`GATEWAY_LAUNCH_TIMEOUT`, default 600s, validated positive). On expiry or cancellation the child is TERMed → polled → KILLed → **reaped**; a TERM to launch.sh no longer orphans `claude` on init holding the token in its env. The old "no deadline" header rationale argued against a *detached* watchdog and is rewritten in-file. | `launch.bats`: deadline test (exit 6, `deadline_exceeded`, child dead), TERM-mid-seed test (exit 143, child dead, scratch dir gone), timeout-0 refusal. Mutation-verified |
| R3 | `lens.sh`, `launch.sh` | Preflight failures are rewrapped onto each script's own vocabulary — enum in `error` (derived from the exit code, never re-parsed from prose), prose in `detail`, ensure's full object under a new `preflight` key. Still exactly one object on stdout on every path. | shape assertions in `lens.bats` / `launch.bats` on the exit-4 and exit-7 paths; mutation-verified by reverting to verbatim forwarding |
| R4 | `gatewayctl.sh` | `pid_is_gateway` matches whole argv elements at position 0/1 (with `--config` required for the interpreter-launched shape) against the binary **recorded beside the pidfile at start**, falling back to today's resolution and the versioned install root (`2b4ab3b`). | guards added in `2b4ab3b` |
| R5 | `gatewayctl.sh` | The probe now records whether *anything* answered — any HTTP status means the port is held — and `do_start_locked` refuses to spawn over a held port instead of racing an AddrInUse corpse whose pid clobbers the pidfile. | `gatewayctl.bats`: live 404 listener → exit 3, refusal named, zero spawns. Mutation-verified |
| R6 | `escapes.bats` | The terminal-sink lint is no longer line-scoped: an awk pass also flags undefended interpolated prints inside `{ ... }` groups whose closing line redirects to a terminal, and `> /dev/stderr` joins `>&2` / `/dev/tty` as a sink. | self-test plants both previously-missed shapes (multi-line block redirect, `/dev/stderr`) plus a negative plant (a block redirected to a plain file must NOT fire) |
| R7 | `launch.bats` | The R12 no-write lint is a named function that also flags `cp`/`mv`/`tee`/`dd`/`truncate`/`sponge` and `sed -i`/`perl -i`/`yq -i` co-occurring with `$CONFIG_PATH`/`$GATEWAY_CONFIG`, applied to all three lib scripts. Reads stay legal — resolving the token IS a read. | self-test in escapes.bats' plant shape: baseline clean, seven planted write shapes, each asserted red |
| R8 | `launch.sh` | The `is_error=true` branch is now reachable: `fake-claude.sh` grew an `error` mode (exit 0, `is_error: true`) and a `hang` mode (records its pid, sleeps — R2's instrument), both pinned by fixture tests. | `launch.bats`: exit 5, `.error == "seed_failed"`, no handle. Mutation-verified by deleting the branch |
| R9 | `README.md` | The `${CLAUDE_PLUGIN_ROOT}` invocation form is scoped to this plugin's own skills; a glob-based resolution recipe covers foreign-plugin consumers; the allowlist paragraph now states the real mechanism — the rule matches literal command text, so rule and invocation must be spelled identically — instead of asserting a match that was not there. | documentation. **Not verified:** the allowlist matcher's expansion semantics (e.g. how `~` in a rule compares against an absolute path) were not empirically tested; the doc deliberately pins "spell them identically" rather than any expansion behaviour |
| R10 | `skills/launch/SKILL.md`, `README.md` | The handover section now leads with the trust-posture difference: unlike the lens, launch runs a **full agent loop** under the user's normal permissions in the pinned cwd, driven by a third-party model. No permission restriction was added — that stays a product decision. | documentation |

## FOUND BY INVOKING THE SURFACES (2026-08-07) — the skills are unreachable

The plugin was installed and all six surfaces driven for the first time. One
defect, and it is structural rather than cosmetic.

**`Skill(gateway:<name>)` resolves to the COMMAND, not the skill.** Commands and
skills share all three names (`lens`, `launch`, `status`), and the command wins.

Proof, not inference: the text returned for `gateway:lens` and `gateway:launch`
had my invocation arguments appended at the bottom — that is `$ARGUMENTS`
expansion, which is a command-only feature. The bodies also matched
`commands/*.md` verbatim.

Two consequences:

1. **The SKILL.md files never load.** They are 51, 76 and 68 lines against
   commands of 10, 13 and 10 — so the exit-code table, the untrusted-output
   rules, the spill handling and the workflow are all bypassed. The plugin pays
   ~140 tokens/session per skill to advertise guidance that cannot be reached
   this way.
2. **The command bodies are self-referential.** Each says "Use the Skill tool to
   invoke: `gateway:<name>`" — which resolves back to the command. An agent
   following that literally loops.

It *appears* to work only because each command also names the script path, which
is enough to complete the task. The failure is silent: richer guidance is
skipped with no error.

It bit concretely during the sweep. `commands/launch.md` says "say what a
gateway-pointed session does not have — the skill lists those." That list lives
in `skills/launch/SKILL.md` under a heading of exactly that name, and it was not
in context, because invoking the skill returned the command.

Compare `spinoff`, which deliberately avoids the collision: commands are
`start-session` / `start-split` / `start-workspace`, the skill is `spinoff`.

**Owner:** this is squarely the `feature/gateway-surfaces` workstream — it is
open question #2 in that handoff ("do commands and skills share names?"),
now answered with evidence rather than speculation. Do not fix it here without
coordinating; the naming decision shapes that whole branch.

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
  **Updated 2026-08-10:** the premise narrowed but the gap is real and was
  worse than recorded. The layer read `server.token` from gateway.yaml only, so
  when setup migrated the credential to the Keychain and dropped that key, it
  went dark ON A MACHINE THAT HAD BOTH a gateway and a stored token — and said
  "no gateway config resolved", which is not what happened. It now resolves
  through `spawn::token_fallback` (config, then env, then Keychain) and scans
  every DISTINCT value rather than only the one the plugin would use, so a
  stale exported `GATEWAY_TOKEN` can no longer mask the live one. The two skip
  reasons are reported separately. The R11 clean-checkout skip is unchanged.
- **A `RETURN` trap survives in `self_check`** (`run-tests.sh:98`) — the sibling
  function documents this hazard and avoids it. Harmless only because `main`
  ends in `exit`.

## Resolved: the credential that was in the working tree

`docs/handoff.md` held the live gateway token twice. **Scrubbed 2026-08-07** —
both occurrences are now `${GATEWAY_TOKEN}`, which is also the shape the gateway
itself expands, so the lines stay copy-pasteable. The repo-wide scan is green.

It was never published. Verified exhaustively before touching anything: no
commit on any ref (`git log --all -S`), no blob reachable from any ref, no stash,
no reflog entry. A history rewrite was considered and **correctly not done** —
it would have rewritten the branch behind an open PR and forced a push to remove
something that was never there. Re-verify scope before any destructive
remediation, even an explicitly authorised one.

Two things worth keeping from how this was found:

- **The old scan could not have seen it.** It was scoped to `plugins/gateway/`
  while a merge publishes the whole (public) repo. Widening it to the repo found
  a real credential on the first run — the gate was not looking where the
  exposure was.
- **No heuristic would have caught it.** The token is 15 characters and
  word-shaped; the prefix layer (`sk-`, `ghp_`, `AKIA`) never matches it. Only
  the exact-token layer does — the same layer that, before this round, printed a
  green `ACTIVE` while grepping for the literal text `${GATEWAY_TOKEN}`.

**Still worth doing:** rotate the token in `~/gateway-0.1.1/gateway.yaml` if that
file has ever been shared, synced or backed up. Scrubbing removes the copy, not
the exposure of the original.

## Testing gaps worth closing

Updated 2026-08-07 alongside the residual fixes:

- ~~No test drives concurrent `ensure` calls against a down gateway~~ —
  `gatewayctl.bats` has had an 8-way concurrent-ensure test since U2. What
  remains untested is the narrower **stale-lock break race** (pre-seeded dead
  lock, multiple waiters, mv-then-rm break): that fix is still guarded by
  reasoning and a reproduction, not a test.
- Mid-flight TERM is now tested for **launch** (the R2 test TERMs it mid-seed
  and asserts the child is dead and the scratch dir gone). The equivalent for
  **lens** — TERM mid-curl, assert the credential dir is gone — still has no
  test; that fix remains verified by hand only.
- `--timeout 0` on the lens is refused since `2b4ab3b`, but no test pins it —
  the guard itself has never been seen red. (`GATEWAY_LAUNCH_TIMEOUT=0` on
  launch IS pinned, mutation-verified.)
- No test exercises the `--flag=value` half of any argument parser — roughly half
  the parse surface across all three scripts.
- The fixture's Bearer-token path is never exercised; every test authenticates
  with `x-api-key` while the plugin sends both headers, so neither header is
  individually load-bearing in any assertion.
