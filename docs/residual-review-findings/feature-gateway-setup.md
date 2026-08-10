# Residual review findings — feature/gateway-setup

Code review ran three local reviewers (correctness, security, reliability) at
`5b6f6c0`. Thirteen findings. Four were applied in `030b788` and a fifth — the P1
below — in `02c150f`; the remaining eight were not, and this file is their durable record. No tracker is configured for
this repo, so the findings are inlined here in full rather than linked.

The adversarial lens did **not** run. The cross-model route (GPT-5.6 Sol through
the local gateway) returned HTTP 502 on two attempts with a 167 KB prompt while
answering a one-line ping normally, so the failure looks like an upstream size
limit rather than an outage. Independent adversarial coverage of this diff is
therefore missing — the one lens specifically aimed at wrong-success paths, on a
change whose entire purpose is refusing unearned success.

## Found live during the G4 smoke run

**Root cause of the whole chain below: a third control surface nobody modelled.**
`~/Library/LaunchAgents/com.shawnroos.gateway.plist` supervises the gateway on
the machine this was built for (`launchctl list` shows `com.shawnroos.gateway`
owning the listener). It predates this work and nothing in the plugin creates
it. KTD4 assumed exactly two surfaces sharing `~/.gateway.pid` — the plugin and
the hand-written `gw` — and a supervisor is a third that outranks both: it
restarts on its own schedule, its relaunch never sees the transient delivery
file, and it silently undoes a `stop` the plugin performs.

Every observation below follows from it. The plan needs a position on
supervised installs before any of the individual fixes are worth much: detect a
LaunchAgent owning the port and refuse to manage that gateway, or own the plist
and write the credential path into it. Managing a supervised process through a
pidfile the supervisor does not write cannot be made to work.


- **P1 · retiring the config token can leave a RUNNING gateway open, and nothing
  owns the transition.** Observed on a real machine. Run 1 retired the token out
  of `gateway.yaml` and stored a generated one in the Keychain, then stopped at
  the `gw` consent gate before reaching the start step. Run 2 found nothing left
  to retire, so `needs_restart` stayed 0 and the gateway was started rather than
  restarted — and it came up reading an `.env.local` that carried
  `OPENROUTER_API_KEY` but no `GATEWAY_TOKEN`, so its auth list was **empty**.
  The gateway treats an empty list as "no auth required": an open proxy on
  127.0.0.1:4000 forwarding to a paid account, reachable by anything on the box.
  Verified after the fact: `GET /anthropic/v1/models` with no credential returned
  200.

  The authenticated round-trip **passed** on that same run, which is the whole
  point — with an empty auth list every request returns 200, so a green
  round-trip proves nothing on its own. Only the unauthenticated reject probe
  caught it, and setup correctly refused to report success with
  `failure_class: "open-proxy"`. That probe is the single most valuable thing
  in the verification contract and it earned its place on the first live run.

  Fix direction: the restart trigger must be a property of *state*, not of what
  this run happened to do. Before start, compare what the running gateway can
  authenticate against what is now stored — or simply treat "config carries no
  token and a credential is stored" as requiring a restart, since a
  already-running process cannot have loaded a token that was minted after it
  started. The narrower flag-and-action triggers keep missing the case where a
  prior run did the mutating.

- **P1 · a failed verify leaves a running gateway that the plugin can no longer
  stop.** Observed immediately after the open-proxy finding above. Setup started
  the gateway, verify failed, setup exited 2 — and the gateway kept serving with
  `~/.gateway.pid` **absent**, so `stop` answered `result: "unmanaged"` and
  refused to signal anything. The refusal is correct on its own terms (KTD4's
  shared-pidfile discipline means never signalling a process it cannot
  identify), but the combination is the problem: setup started something,
  declined to call it success, and left it running with no supported way to shut
  it down. The operator had to be handed a raw `kill <pid>` found via `lsof`.

  Compounds the open-proxy P1 directly — the process that could not be stopped
  was the one serving unauthenticated. Not yet determined whether the pidfile
  was never written or was written and then removed on the failure path; the
  run that produced it is gone, so this needs reproducing under fixtures before
  it is fixed. Fix direction, whichever it turns out to be: a start that
  succeeds must leave a pidfile that survives a later step's failure, and a
  `stop` that finds a serving gateway with no pidfile should offer the pid it
  can see rather than only refusing.

- **P2 · the 401 diagnostic names the wrong token source.** On the preceding run
  the failure read `token came from /Users/shawnroos/gateway-0.1.1/gateway.yaml`
  while that file had zero token lines — the value came from the Keychain. An
  operator following that message goes to edit an empty file. The source label
  is reported from the wrong variable somewhere on the probe's failure path.

- **P3 · setup truncates a pre-existing `.env.local` in the install dir.** The
  delivery path replaces that file rather than merging into it, so an operator
  who kept provider keys there loses them on the first start. On this machine
  the original survived only because delivery never wrote. Either merge, or back
  it up and say so in `changed`.

## Open after the G4 run — setup's own start competes with the supervisor

**G4 itself is now PASSED** (`ok:true`, exit 0, both verification layers green,
unauthenticated probe rejected 401). But it passed on the *second* attempt,
after the competing process was cleared by hand. The finding below is what made
the first attempt fail, and it will make the FIRST run on any supervised
machine fail the same way — which is the run that matters, because it is the
one a new operator makes.

- **P1 · after adopting a supervisor, setup still starts the gateway itself, and
  the two fight over the port.** Observed live. The `supervisor` step reloads the
  agent, so launchd immediately tries to start the gateway through the new
  launcher — but `spawnctl`'s start path holds `127.0.0.1:4000` with the process
  from before adoption. launchd's `KeepAlive` retries and loses every time
  (`Error: Os { code: 48, kind: AddrInUse }`, repeatedly, in `~/.gateway.log`),
  the `start` step sees "a gateway is up" and reports ok without restarting, and
  `verify` then correctly fails on the still-unauthenticated old process.

  So the run cannot reach a clean pass on a supervised machine, even though
  every individual piece works: killing the competing process by hand let
  launchd win the port, and the launcher then produced exactly the wanted state
  — unauthenticated 401, bogus token 401, real token 200, and no
  `OPENROUTER_API_KEY` in the process environment.

  The launcher is not at fault; the ownership model is. On a supervised install
  launchd owns the lifecycle, so setup must not start the gateway itself: after
  adoption the `start` step should stop any process it started, let the reload
  bring the gateway up through the launcher, and wait for that to answer —
  rather than racing it. The narrower restart triggers added twice already
  (rotation, install, token retirement, and now adoption) keep missing cases
  because they ask "did this run change something?" instead of "is the process
  currently serving the one that would be started now?".

## Known gaps in the supervisor adoption (R28) — both CLOSED

- **CLOSED.** ~~P2 · detection is exact-binary-match, so it silently no-ops on the upgrade
  path.~~ `supervisor` matches an agent whose `ProgramArguments[0]` equals the
  *resolved* gateway binary. The moment `acquire` installs a version newer than
  the plist points at, that comparison fails, the step reports
  `not-supervised`, and setup reports success — while launchd keeps starting the
  **old** binary, which after token retirement comes up unauthenticated. The
  wrong-success shape R28 exists to prevent, reintroduced one release later, on
  exactly the machine it was written for. It does not bite today only because
  the installed version and the plist agree. Fix direction: match any sibling
  `gateway-*` install rather than the resolved one, and rebase the adopted
  launcher's recorded argv onto the newly resolved install so the agent follows
  an upgrade instead of pinning to the version it was written against.

- **CLOSED.** ~~P3 · the orchestrated `repointed` arm has no test.~~ `setup.bats` covers
  only `supervisor → not-supervised`; the two `record_change` calls and the
  "adopted" `step_done` inside `do_setup` run in no test. The verb itself is
  covered nineteen ways, so this is a seam gap rather than a logic gap — adding
  a matching agent inside `setup.bats`'s sandbox closes it.

## Wrong-success paths — the highest-value residuals

- **RESOLVED in `02c150f`.** ~~**P1 · setup does not restart an already-running gateway after installing a new
  release** (`plugins/spawn/lib/setup.sh`, `do_setup`). `start_verb` becomes
  `restart` only when a credential was rotated; an acquire reporting
  `action:"installed"` does not set it. On the steady-state upgrade path the
  probe finds the old process already serving, returns without restarting, and
  the round-trip then verifies **the old process**. Setup reports `ok:true` with
  the new tag and new install dir while the newly built binary and the newly
  migrated token-free config have never been executed or read. Every claim the
  success object makes about the new release is unsupported by the evidence the
  run collected. Fix direction: set a `needs_restart` flag when acquire installs
  or when `retire_installed_token` rewrote the live config, or have the start
  step compare the serving process's binary against the one just promoted.
  *(correctness, confidence 90)*~~ The restart decision now keys on what the run
  changed — a rotated credential, a promoted install, or the token retired out
  of the live config — and `setup.bats` asserts the observable (a restart stops
  the process that was serving) with a mutation proof.

- **P2 · Codex wired without Claude Code references a `GATEWAY_TOKEN` nothing
  sets** (`do_wire`). The KTD15 shell snippet is the only thing that exports
  `GATEWAY_TOKEN`, and it is written only when Claude Code is present. On a
  codex-installed / claude-absent machine the emitted provider names an
  environment variable no file populates, so Codex cannot authenticate — and
  nothing catches it, because `config.load` validates syntax and the round-trip
  builds its own request with a token read straight from the Keychain rather
  than through Codex's environment. `tests/unit/setup-wiring.bats:187` asserts
  the snippet's *absence* in that case, so the suite currently enshrines the
  gap. Fix direction: write the env snippet whenever any harness is wired, and
  gate only the rc append on Claude Code. *(correctness, confidence 85)*

- **P2 · an interrupted rotation followed by a plain re-run reports success over
  the old credential** (`do_setup`). `rotated` is set from the command-line flag,
  never from whether a credential was actually replaced. Rotate, get interrupted
  during the build, re-run plainly: the key step sees the item exists and reports
  "reused", no restart happens, and the still-running gateway holds the previous
  key. If the old key is still valid — the common case for a proactive rotation —
  every round-trip passes and setup reports success having silently not applied
  the rotation. The token variant fails loudly instead, but its 401 message names
  `--rotate-openrouter-key`, the wrong credential. *(reliability, confidence 80)*

## State and reporting

- **P2 · `deliver_secrets` does not check the write that puts the credentials
  into `.env.local`** (`plugins/spawn/lib/spawnctl.sh`). `set -e` is off by
  design, so a failed write (ENOSPC, quota, read-only mount) falls through;
  `KEY_DELIVERED`/`TOKEN_DELIVERED` are set unconditionally, the child unsets the
  inherited variables *because* it believes delivery happened, and the gateway
  starts against an empty file — the open-proxy state the R9 guard exists to
  prevent. Only the full setup path's reject probe would catch it; `gw start`
  would not. *(correctness, confidence 60)*

- **P2 · a failed wire step leaves the env file and the rc line written and
  reports neither** (`do_wire`). Claude Code's side is written first; when the
  Codex validation then fails, the restore covers only the Codex config, and the
  child dies with no record of the other two edits — one of them the
  consent-gated edit to a file setup does not own. *(reliability, confidence 80)*

- **P3 · a jq failure in the state accumulators discards the entire list.**
  `step_done` and `record_change` both end `|| STEPS_JSON="[]"`, so one failed
  invocation throws away every step and change recorded so far, and the failure
  object then reports an empty `changed` list on a machine that has an install,
  two Keychain items and a rewritten wrapper. `emit_setup_failure` already uses
  the right pattern three functions down: fall back to the last good value.
  *(reliability, confidence 55)*

## Smaller correctness residuals

- **P3 · a migrated `gateway.yaml` loses its file mode on promotion.**
  `stage_config` writes under the process umask and moves into place with no
  mode carried over; `retire_installed_token`, doing the same edit in place,
  explicitly preserves it with stat/chmod. The two token-retirement paths
  disagree, so an operator who tightened their config to 0600 silently gets 0644
  after an upgrade. *(correctness, confidence 80)*

- **P3 · after an upgrade the previous install's config keeps its literal
  token.** Retirement is applied to the copy that becomes the new install and,
  on the skip path, in place — but a version-changing acquire leaves
  `~/gateway-<older>/gateway.yaml` untouched with the literal still in it.
  Nothing runs from it, so this is data at rest rather than a live credential,
  but the plugin's claim is that setup retires the token and the file it
  migrated *from* is the one still holding it. *(correctness, confidence 75)*

- **P3 · `strip_server_token` corrupts a multi-line flow-sequence token list, and
  the detector then passes it.** The stripper drops the `tokens:` line and then
  only continues dropping block-sequence items, so `tokens: [` / `"a",` / `]`
  loses its opening line and leaves the rest as invalid YAML.
  `config_has_server_token` reports no token (the key is gone), the post-strip
  guard passes, and the failure surfaces later as a gateway that will not parse
  its config. *(correctness, confidence 60)*

- **P3 · `do_setup` can exit outside the frozen enum.** `die "$SUB_RC"` forwards
  a sub-verb child's raw status as both the process exit code and the JSON
  `exit_code` — 1 on an interpreter crash, 130/143/129 on a signal — while the
  plugin freezes the enum at 0/2/3/8/9. *(correctness, confidence 80)*

- **P3 · `GATEWAY_ROOT_URL` trims `/anthropic` before the trailing slash**
  (`setup.sh` top-level), so an override ending in `/anthropic/` keeps the route
  prefix and the emitted Codex `base_url` becomes `/anthropic/v1`, which the
  gateway does not serve. The equivalent trim inside `do_setup` does it in the
  correct order, so the two copies disagree. *(correctness, confidence 75)*

## Accepted, not defects

Recorded so a later reviewer does not re-open them: the Keychain's default ACL
authenticates `/usr/bin/security` rather than the caller (documented in the
plugin README as a limitation, not solved); SIGKILL can strand the delivery
file; the gateway token deliberately reaches a child's exec-time environment
because it is loopback-only and cheap to rotate; and Codex ships fixture-proven
because it is not installed on this machine.

One security residual worth naming separately: **the failed-start log tail is
relayed to stderr** (`spawnctl.sh`), and the gateway's log can carry an upstream
provider error body — which may quote the credential presented. The round-trip
path drops response bodies for exactly this reason; the log tail does not.
Pre-existing, but this branch is what began delivering the OpenRouter key into
that process. *(security, confidence 50)*

## Test gaps the reviewers named

- No test runs setup while a gateway from a prior run is already serving — the
  precondition that hides the P1 above.
- No test asserts a wired harness can actually obtain the credential its config
  references; the round-trip supplies its own token, which is not the path
  either harness uses.
- No test sends a signal mid-run. One bats case that backgrounds setup, kills it
  during verify, and asserts both a parseable JSON object and no surviving
  `spawn-rt.*` directory would cover two of the applied fixes.
- No test exercises a failing write inside `deliver_secrets`.
- `strip_server_token` has no multi-line flow-sequence fixture.
- No test drives a trailing-slash base-URL override.

## R27 was only half-applied — found by the post-rebase end-to-end check

**Severity: P1. Fixed in this branch.**

R27 added the env-then-Keychain token fallback to `spawnctl.sh`'s probe and
nowhere else. `lens.sh` and `launch.sh` each resolve their own credential (KTD6
keeps the delivery builders separate on purpose), and both still read the
config alone. Once `setup` retired the config token, `spawnctl status` reported
`ok:true` while a real `lens` call returned exit 7 `auth_rejected` — which is
exactly what the live check after the rebase hit.

`lens.sh:615` had already written down why this is the worst shape for a bug:
"a lens that authenticated with a different token than the probe would pass
preflight and then 401, and that divergence is undebuggable from the outside."
The comment was right and could not enforce itself.

Fix: one chain, `spawn::token_fallback` in `secrets.sh`, called by all three.
The `server.token` awk parsers stay duplicated (common.sh names them as
deliberate); only the env/Keychain half is shared, and it resolves in-process,
so no token crosses a boundary it did not already cross.

`launch.sh` had **two** consumers, not one: the in-process token and the
printed attach command, which re-resolves in the user's shell at attach time.
Fixing only the first would have left a handle that works today and 401s hours
later. Both now carry the chain; the attach test EXECUTES the printed command
rather than grepping it for the fallback text.

## Latent: a blanked `token:` line parses as its own trailing comment

**Severity: P3. Not fixed — recorded deliberately.**

All three parsers decomment with `[ \t]+#`, which needs whitespace before the
`#`. A line like `  token:        # Bearer or x-api-key` (key present, value
removed, comment kept) leaves the `#` flush against the start of the value, so
every parser returns the literal `# Bearer or x-api-key` as the token — a
non-empty garbage credential that also suppresses the R27 fallback, since that
only fires on an empty value.

Not reachable today: `setup` retires the token by removing the whole key, not
by blanking it, and the real `gateway.yaml` has no `token:` line at all. It
would bite anyone who blanks the value by hand. Left alone because the fix
touches three parsers that KTD6/common.sh deliberately keep separate, and all
three currently agree — there is no divergence here, only a shared blind spot.

## Code review on PR #31 — five findings, all fixed

**#1 + #2 (P1, one design fault): the launcher neither registered nor fed the
process.** `launcher_body` exec'd the gateway directly, so a launchd-started
gateway wrote no pidfile and spawnctl saw it as unmanaged — `stop` refused
(correctly; it will not guess which process to signal) and every restart path
aborted over a healthy gateway. The same launcher relied on a pre-existing
`.env.local`, and there never is one: spawnctl writes that file to start the
gateway and removes it once the probe settles, so a launchd start came up with
no upstream credential at all.

Fixed together, because they are one fault. The launcher now delivers the key
itself (mirroring `deliver_secrets`, with a cleaner child so the file does not
outlive startup — KTD1 keeps the key in the Keychain, not on disk) and records
`$$` plus the binary path before `exec`, which keeps the pid. `exec spawnctl
start` was considered and rejected: spawnctl daemonizes and exits, so launchd
would see the job die and KeepAlive would respawn it forever.

Two things surfaced while fixing it:
- The launcher could lose a race with setup's own start step and clobber the
  winner's pidfile, pointing spawnctl at a process that is not serving. It now
  leaves a live pidfile alone.
- `write_launcher` could land a BROKEN launcher and still report `ok:true`. An
  unset variable killed one heredoc inside the command substitution; the rest
  still emitted and the substitution still exited 0, so what landed was missing
  its whole configuration block and failed at start with `cd: null directory`.
  It now proves every required name is present before replacing a working file.

**#3 (P2): the open-proxy refusal left the open proxy running.** It told the
operator to stop it. It now unloads the supervising agent first (or a KeepAlive
respawn defeats the stop), then stops the gateway, and reports which of those
actually happened rather than claiming either.

**#4 (P2): `deliver_secrets` had no xtrace guard.** Fixed as a class, not an
instance: `deliver_secrets`, `round_trip` and `do_setup` all got `local -; set
+x`, and the top-level R27 fallback blocks in `lens.sh`/`launch.sh` are now
wrapped in a function so `local -` exists to scope it.

**#5 (P2): the plist repoint had no consent gate.** Now `--consent-adopt-agent`,
using the existing EX_CONSENT=8 path, passed through `pass_consent` like `gw`
and `wire`. It is the more consequential of the three consent gates: it changes
what happens at every login.

**The testing gap the review named is closed.** `fake-launchctl.sh` records argv
and execs nothing, so every existing test proved the launcher was WRITTEN, none
proved what happens when launchd RUNS it — which is exactly where both P1s
lived. Five tests now execute the generated launcher, and the suite grew a
fourth safety rail (`SPAWN_PIDFILE`), without which those tests would write the
operator's real `~/.gateway.pid`.

## The exec-based cleaner did not survive launchd — found on the real machine

**Severity: P1. Fixed.**

The first fix for #2 delivered the key and forked a `( sleep N; rm )` child to
remove the file, then `exec`'d the gateway. Verifying it against the real
adopted agent showed the key still on disk minutes later, with `DELIVERY_TTL`
correctly baked and no `sleep` pending: under launchd that child does not
survive to run. It works under a direct run, which is exactly why the test that
executes the launcher directly could not see the difference — the same class of
blind spot the review had just caught.

The launcher no longer execs. It starts the gateway as a child, registers the
CHILD's pid, removes the delivery file itself after a bounded wait, and waits.
launchd is satisfied by any long-lived process, and cleanup is now in-process
rather than depending on an orphan. Because a parent now sits between launchd
and the gateway, a TERM has to be forwarded or an unload would orphan the
gateway holding the port — so it is, and a test kills the launcher and asserts
the gateway went down because it was signalled.

The pidfile is also removed when the gateway exits: one left naming a dead pid
is what makes a later stop signal the wrong process.

## Verified against real launchd (2026-08-09)

The supervising launcher was confirmed on the machine, not only in tests:
launchd's tracked job pid IS the launcher, the gateway is its child, the
pidfile names the serving gateway, and `.env.local` is gone after startup —
the cleanup that failed twice under the exec design.

Getting there surfaced one more thing worth writing down. The FIRST adoption
had left a gateway started by the old exec launcher, and launchd had lost the
association with it across reloads, so it survived two `launchctl unload`s and
kept port 4000. The new supervising launcher then crash-looped behind it
(~12s per cycle, re-delivering the key each time) while `setup` reported
ok:true, `verify` passed both layers, `spawnctl status` was green and a lens
call returned exit 0 — all served by the STALE process. Every check proved a
gateway was healthy; none proved it was the SUPERVISED one.

That specific stranding was a migration artifact of the exec design and cannot
recur the same way: launchd now tracks the launcher, which forwards TERM to its
child, so `unload` stops the gateway.

## Still open

- **`spawnctl start` can overwrite the launchd launcher's pidfile claim, leaving
  a stale pid over a supervised gateway (P1). Observed live, 2026-08-10.**
  Timeline from the machine: launcher pid 8123 started 21:37:35 and claimed the
  pidfile; the gateway it spawned (8139) held :4000; at 22:58:57 — 81 minutes
  later — the pidfile was rewritten to 66681, which then died. Result:
  `spawnctl status` reported `running:true, pid_verified:false` against a
  pidfile pointing at a corpse, while the real, supervised gateway ran
  unmanaged. `stop`/`restart` are refused in that state, so the machine cannot
  be controlled through the plugin at all.

  The launcher has the correct guard — it declines to claim when the recorded
  pid is ALIVE and names the same binary (spawn-launch.sh:99-112). `spawnctl`'s
  own start path has no reciprocal guard: nothing stops it stamping its pid over
  a claim the launcher already holds.

  Verified fixable and verified NOT a launcher defect: `launchctl unload` then
  `load` restored `pid_verified:true` with the pidfile naming the live process,
  and the unload released :4000 with zero listeners left — so the launcher's
  signal forwarding and pidfile claim both work when they run uncontested.

  Fix: give `do_start_locked` the mirror of the launcher's guard — refuse to
  overwrite a pidfile whose recorded pid is alive and names the same binary —
  and/or have it detect a loaded launchd agent and route through it rather than
  starting a competing process.


- **`setup` does not confirm the adoption took effect (P2).** After
  `unload`/`load` it reports "adopted" without checking that the gateway now
  serving is the one launchd started. A gateway started OUTSIDE launchd (a
  plain `spawnctl start`) holds the port, the supervised launcher cannot bind,
  and every downstream check still passes because the unsupervised process
  answers. The check to add: the pidfile pid's parent should be the launcher.

- **`spawnctl stop` is a ~10s restart on a supervised machine, not a stop
  (P2).** It kills the gateway, the launcher's `wait` returns, the launcher
  exits, and KeepAlive respawns it. `result:"stopped"` is true only
  momentarily. This is the same thing the open-proxy fix already says out loud
  ("stopping the process only triggers a respawn", which is why that path
  unloads first) — it is now the everyday behaviour on an adopted machine.
  `stop` should detect the supervised case and either unload the agent or say
  plainly that the agent must be unloaded. Operator-visible, not a
  wrong-success, so it is not merge-blocking.

- **Setup bakes the path of the checkout it runs from into `~/.local/bin/gw`
  (P2).** Line 7 of the generated wrapper pins `SPAWNCTL=` to an absolute path.
  Run setup from a git worktree and the wrapper points into that worktree; when
  the worktree is removed after the PR lands, `gw` breaks with no warning and
  nothing on the machine explains why. The launcher and `env.sh` do not have
  this problem — they bake only machine paths and the gateway binary. Worth
  either resolving the plugin root to a durable checkout or refusing/warning
  when setup runs from a worktree. Remedy today: re-run setup from the
  permanent checkout once the plugin has landed there.

- **A lint for the xtrace class.** #4 was fixed everywhere it exists today, but
  nothing stops the next credential-holding function from shipping unguarded.
  The reviewer's suggestion — fail any credential assignment outside an
  xtrace-guarded scope — is the durable fix and is not written.
- **Start-vs-supervisor race: mitigated, not resolved.** `needs_restart` is now
  cleared when the supervisor step already restarted the gateway, and the
  launcher will not steal a live pidfile. The deeper question — what `stop`
  should mean when a KeepAlive agent will respawn — is untouched.
- **No cross-provider review.** All five review contexts were Claude siblings.
  The 502s blocking a cross-vendor lens are an input x output size ceiling
  (185KB in at 8000 max-tokens works; 35KB at 24000 fails), so the fix is to
  slice the diff and cap output, not to retry the whole thing.
