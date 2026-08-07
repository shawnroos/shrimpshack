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
