#!/usr/bin/env bats
# U7 — orchestration, rotation, and the round-trip proof (`setup.sh` with no verb).
#
# WHAT THIS FILE IS ABOUT: setup refuses unearned success. Everything else here
# — the ordering, the accumulators, the rotation warnings — exists to make that
# refusal provable.
#
# THE FALSE-GREEN TRAPS IT IS WRITTEN AGAINST
#   1. "verified" meaning "we wrote the files". Every config setup writes can be
#      correct while the credential the gateway holds is refused, so the AE3
#      test drives a gateway that authenticates the liveness probe and REFUSES
#      the completion, and asserts the run fails with the auth class.
#   2. "the gateway is guarded" being proven only by requests that PRESENT a
#      credential. Every such request passes against an open proxy, so the
#      unauthenticated reject probe is asserted directly AND shown to be
#      load-bearing by running against a gateway in --no-auth mode.
#   3. A state report assembled after the fact. `steps` and `changed` are
#      asserted on the SUCCESS object as well as the failure one — a report
#      built only in the error handler cannot satisfy both.
#   4. "it re-ran safely" being vacuously true of a run that prompted again.
#      The dialog fixture records every invocation, and a bare re-run is
#      asserted to add none.
#
# THE GATEWAY IN THIS SUITE IS REAL ENOUGH TO FAIL. spawnctl.sh starts the
# install's binary for real, that binary serves tests/fixtures/fake-gateway.py
# on the port its own gateway.yaml declares, and setup's round-trip is a real
# curl over a real socket. The only thing faked is what is behind the gateway.
#
# NO REAL CREDENTIAL IS USED OR NEEDED, and no synthetic value here carries a
# credential-shaped prefix — the repo-wide secret scan reads this file.

EX_UNREACHABLE_T=3

setup() {
    FIX="$(cd "$BATS_TEST_DIRNAME/../fixtures" && pwd)"
    LIB="$(cd "$BATS_TEST_DIRNAME/../../lib" && pwd)"
    SETUP="$LIB/setup.sh"
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/gw-setup.XXXXXX")"
    WORK="$(cd "$WORK" && pwd -P)"
    . "$BATS_TEST_DIRNAME/../lib/sweep.bash"

    # --- safety rails. Every path setup can write to lives under $WORK. ------
    export SPAWN_SEARCH_ROOT="$WORK/root"
    mkdir -p "$SPAWN_SEARCH_ROOT"
    export SPAWN_STATE_HOME="$WORK"
    export SPAWN_CODEX_CONFIG="$WORK/dot-codex/config.toml"
    export SPAWN_GATEWAY_ENV_FILE="$WORK/dot-gateway/env.sh"
    export SPAWN_SHELL_RC="$WORK/dot-zshrc"
    # The supervisor step's three surfaces. The agents directory is the loudest
    # rail in this file: its default is the operator's real ~/Library/LaunchAgents,
    # and an orchestrated run that swept it could repoint the agent supervising
    # the machine this suite is running on.
    export SPAWN_LAUNCH_AGENTS_DIR="$WORK/LaunchAgents"
    mkdir -p "$SPAWN_LAUNCH_AGENTS_DIR"
    export SPAWN_GATEWAY_LAUNCHER="$WORK/dot-gateway/spawn-launch.sh"

    # --- seams --------------------------------------------------------------
    export SPAWN_PLUTIL_BIN="$FIX/fake-plutil.sh"
    export SPAWN_LAUNCHCTL_BIN="$FIX/fake-launchctl.sh"
    export FAKE_PLUTIL_RECORD="$WORK/plutil-argv"
    export FAKE_LAUNCHCTL_RECORD="$WORK/launchctl-argv"
    export SPAWN_CURL_BIN="$FIX/fake-curl.sh"     # the GitHub API, not the gateway
    export SPAWN_CARGO_BIN="$FIX/fake-cargo.sh"
    export FAKE_CURL_RECORD_DIR="$WORK/rec-curl"
    export FAKE_CARGO_RECORD_DIR="$WORK/rec-cargo"
    export FAKE_CURL_MODE=ok
    export FAKE_CARGO_MODE=ok
    export FAKE_CURL_TAG="v9.9.9"
    export FAKE_CURL_SHA="abc1234abc1234abc1234abc1234abc1234abc12"
    export FAKE_CURL_TARBALL="$WORK/src.tar.gz"
    : > "$FAKE_CURL_TARBALL"

    export SPAWN_SECURITY_BIN="$FIX/fake-security.sh"
    export FAKE_SECURITY_STORE_DIR="$WORK/kc-store"
    export FAKE_SECURITY_RECORD_DIR="$WORK/kc-record"
    mkdir -p "$FAKE_SECURITY_STORE_DIR" "$FAKE_SECURITY_RECORD_DIR"
    export FAKE_SECURITY_MODE=ok
    export SPAWN_KEYCHAIN_SERVICE="spawn-gateway-test"
    export SPAWN_KEYCHAIN_ACCOUNT_TOKEN="gateway-token"
    export SPAWN_KEYCHAIN_ACCOUNT_OPENROUTER="openrouter-api-key"

    export SPAWN_OSASCRIPT_BIN="$FIX/fake-osascript.sh"
    export FAKE_OSASCRIPT_RECORD_DIR="$WORK/dlg-record"
    mkdir -p "$FAKE_OSASCRIPT_RECORD_DIR"
    export FAKE_OSASCRIPT_MODE=ok
    # A synthetic key. Deliberately NOT in the shape of a real OpenRouter key —
    # the repo's secret scan reads this file, and a realistic prefix here would
    # fail it for a value that is not a credential.
    export FAKE_OSASCRIPT_ANSWER="fixture-openrouter-value-1"

    # Harness detection (KTD12) is answered by RUNNING against a directory that
    # holds exactly what each test puts in it.
    BINDIR="$WORK/bin"
    mkdir -p "$BINDIR"
    export SPAWN_CLAUDE_BIN="$BINDIR/claude"
    export SPAWN_CODEX_BIN="$BINDIR/codex"
    export FAKE_CODEX_RECORD="$WORK/codex-argv"

    # --- the gateway's port, chosen before its config is written ------------
    PORT="$(free_port)"
    export SPAWN_BASE_URL="http://127.0.0.1:$PORT/anthropic"
    export SPAWN_CONNECT_TIMEOUT=2
    export SPAWN_PROBE_TIMEOUT=5
    export SPAWN_START_TIMEOUT=15
    export GW_REQUEST_LOG="$WORK/gw-requests.jsonl"
    export GW_EXTRA_ARGS=""
    unset GATEWAY_TOKEN OPENROUTER_API_KEY SPAWN_CONFIG SPAWN_INSTALL_DIR SPAWN_MODELS_JSON

    INSTALL="$SPAWN_SEARCH_ROOT/gateway-9.9.9"
    make_install "$INSTALL" "$PORT"

    OUT="$WORK/out.json"
    ERR="$WORK/err.txt"
    RC=0
}

teardown() {
    local pid p
    pid="$(cat "$WORK/.gateway.pid" 2>/dev/null || true)"
    [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null
    sweep_work
    rm -rf "$WORK"
    return 0
}

# --- helpers ---------------------------------------------------------------

free_port() {
    python3 -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()'
}

# make_install <dir> <port> — a complete, RUNNABLE install: a gateway.yaml
# binding the chosen port, and a binary that actually serves.
#
# The binary is written here rather than in tests/fixtures because it is this
# suite's topology, not a shared fixture: it stands in for the built gateway on
# the one path where the gateway has to be genuinely startable by spawnctl.sh
# (the round-trip is a real socket call, and a restart has to stop and respawn
# something real). It reads its token the way the real gateway does — from the
# mode-0600 delivery file in its CWD, or from the environment — so a rotated
# token reaches it without the test doing anything.
#
# It does NOT exec python: spawnctl.sh's pid_is_gateway matches the recorded
# binary path as an argv element, and an exec would replace this argv with
# python's, so `stop` would stop recognizing a process it legitimately owns —
# which is exactly what a restart needs.
make_install() {
    local dir="$1" port="$2"
    mkdir -p "$dir/target/release"
    cat > "$dir/gateway.yaml" <<EOF
server:
  bind: "127.0.0.1:$port"

models:
  kimi:
    model: openrouter/moonshotai/kimi-k2.7-code
  glm:
    model: openrouter/z-ai/glm-5.2
EOF
    cat > "$dir/target/release/gateway" <<EOF
#!/usr/bin/env bash
set -uo pipefail
FAKE_GATEWAY_PY="$FIX/fake-gateway.py"
EOF
    cat >> "$dir/target/release/gateway" <<'EOS'
case "${1:-}" in
  --version|--help) printf 'gateway (suite install binary)\n'; exit 0 ;;
esac

CFG=""; prev=""
for a in "$@"; do
  [ "$prev" = "--config" ] && CFG="$a"
  prev="$a"
done
[ -f "$CFG" ] || { printf 'no readable --config\n' >&2; exit 1; }

port="$(sed -n 's/.*bind:[[:blank:]]*"127.0.0.1:\([0-9][0-9]*\)".*/\1/p' "$CFG" | head -1)"
aliases="$(grep -E '^  [A-Za-z0-9._-]+:[[:blank:]]*$' "$CFG" | tr -d ' :' | paste -sd, -)"
# A gateway may serve a list that is not this machine's config aliases — a bare
# install from the upstream template is exactly that case. GW_ALIASES lets a
# test create the divergence.
[ -n "${GW_ALIASES:-}" ] && aliases="$GW_ALIASES"

# The token, with the real gateway's own precedence: the process environment
# first, then the CWD-relative delivery file it is handed at exec.
tok="${GATEWAY_TOKEN:-}"
if [ -z "$tok" ] && [ -f "$PWD/.env.local" ]; then
  tok="$(sed -n 's/^GATEWAY_TOKEN=//p' "$PWD/.env.local" | head -1)"
fi

log_args=""
[ -n "${GW_REQUEST_LOG:-}" ] && log_args="--request-log $GW_REQUEST_LOG"

# shellcheck disable=SC2086
python3 "$FAKE_GATEWAY_PY" --port "$port" --token "$tok" --aliases "$aliases" \
    $log_args ${GW_EXTRA_ARGS:-} 3>&- &
child=$!
trap 'kill "$child" 2>/dev/null; exit 143' TERM
trap 'kill "$child" 2>/dev/null; exit 130' INT
wait "$child"
EOS
    chmod +x "$dir/target/release/gateway"
}

seed_keychain() {   # seed_keychain <account> <value>
    printf '%s\n%s\n' "$2" "$2" \
        | "$SPAWN_SECURITY_BIN" add-generic-password -a "$1" -s "$SPAWN_KEYCHAIN_SERVICE" -U -w
}

stored_value() {    # stored_value <account> — read back through the fake store
    "$SPAWN_SECURITY_BIN" find-generic-password -a "$1" -s "$SPAWN_KEYCHAIN_SERVICE" -w 2>/dev/null
}

install_claude() {
    cat > "$SPAWN_CLAUDE_BIN" <<'EOS'
#!/usr/bin/env bash
exit 0
EOS
    chmod +x "$SPAWN_CLAUDE_BIN"
}

install_codex() {
    cp "$FIX/fake-codex.sh" "$SPAWN_CODEX_BIN"
    chmod +x "$SPAWN_CODEX_BIN"
    export FAKE_CODEX_MODE="${1:-ok}"
}

# run_setup [--script <path>] [flags...] — stdout and stderr to SEPARATE files:
# bats' own `run` merges them, and this script prints progress to stderr, so a
# merged capture would have every jq assertion parsing diagnostics.
run_setup() {
    local script="$SETUP"
    if [ "${1:-}" = "--script" ]; then script="$2"; shift 2; fi
    rm -f "$OUT" "$ERR"
    RC=0
    bash "$script" "$@" >"$OUT" 2>"$ERR" || RC=$?
    return 0
}

assert_one_json() {
    [ -s "$OUT" ]
    [ "$(grep -c . "$OUT")" -eq 1 ]
    jq -e . "$OUT" >/dev/null
    jq -e 'has("ok") and has("error") and has("exit_code")' "$OUT" >/dev/null
}

dialog_count() {
    grep -c -- '--- invocation ---' "$FAKE_OSASCRIPT_RECORD_DIR/argv" 2>/dev/null || printf '0'
}

step_status() {   # step_status <name>
    jq -r --arg s "$1" '.steps[] | select(.step == $s) | .status' "$OUT"
}

# mutant <file> <sed-expression> — a copy of the whole lib with ONE script
# mutated (the scripts source each other, and setup.sh re-invokes itself, both
# relative to their own location, so a mutated copy drives its own mutated
# verbs). Prints the mutated script's path.
mutant() {
    local file="$1" expr="$2" dir="$WORK/mutlib"
    rm -rf "$dir"
    mkdir -p "$dir"
    cp "$LIB"/*.sh "$dir/"
    [ -f "$LIB/models.json" ] && cp "$LIB/models.json" "$dir/"
    sed -i '' "$expr" "$dir"/*.sh
    printf '%s' "$dir/$file"
}

# --- the happy path ---------------------------------------------------------

@test "F1: a first run walks every step in order, verifies both layers, and reports what it changed" {
    install_claude
    run_setup --consent-shell-rc
    [ "$RC" -eq 0 ]
    assert_one_json
    [ "$(jq -r '.ok' "$OUT")" = "true" ]

    # ORDER is the assertion, not merely presence. The two credential steps run
    # BEFORE acquire on purpose: acquire refuses to promote an install whose
    # config declares no token while no token is stored (R9's static half), so
    # F1's written order cannot complete a first run.
    [ "$(jq -r '[.steps[].step] | join(",")' "$OUT")" \
        = "prereqs,openrouter-key,gateway-token,acquire,supervisor,wire,start,verify" ]

    # R28. This machine has no supervising agent, so the step reports that and
    # writes nothing — it adopts an agent, it never creates one.
    [ "$(jq -r '.steps[] | select(.step == "supervisor") | .status' "$OUT")" = "not-supervised" ]
    [ ! -e "$SPAWN_GATEWAY_LAUNCHER" ]
    [ -z "$(find "$SPAWN_LAUNCH_AGENTS_DIR" -type f 2>/dev/null)" ]

    # The key was captured through the dialog exactly once, and its value is
    # nowhere in the output or the diagnostics (R5).
    [ "$(dialog_count)" -eq 1 ]
    run grep -F -- "$FAKE_OSASCRIPT_ANSWER" "$OUT" "$ERR"
    [ "$status" -ne 0 ]

    # Both verification layers, separately attributable (KTD13).
    [ "$(jq -r '.verification.round_trip[0].harness' "$OUT")" = "claude-code" ]
    [ "$(jq -r '.verification.round_trip[0].route' "$OUT")" = "/anthropic/v1/messages" ]
    [ "$(jq -r '.verification.round_trip[0].http_status' "$OUT")" = "200" ]
    [ "$(jq -r '.verification.unauthenticated_probe.rejected' "$OUT")" = "true" ]
    [ "$(jq -r '.verification.unauthenticated_probe.http_status' "$OUT")" = "401" ]
    jq -e '.verification | has("config_validation")' "$OUT" >/dev/null

    # R18's accumulator, asserted from the SUCCESS side too: a report built only
    # in the error handler cannot satisfy this. Both ends of the accumulator are
    # named: `keychain-item` is recorded by do_setup's own credential step, and
    # `shell-rc` is forwarded up out of the wire child — the operator's rc file
    # is the edit they are most entitled to see reported.
    jq -e '[.changed[].what] | index("keychain-item") != null' "$OUT" >/dev/null
    jq -e '[.changed[].what] | index("shell-rc") != null' "$OUT" >/dev/null
    jq -e '[.changed[].target] | index($ENV.SPAWN_GATEWAY_ENV_FILE) != null' "$OUT" >/dev/null

    # R15's losses reach the top-level object rather than being lost in a child.
    [ "$(jq -r '.losses | length' "$OUT")" -ge 4 ]
    [ "$(jq -r '[.wired[].harness] | join(",")' "$OUT")" = "claude-code" ]
    [ "$(jq -r '[.skipped[].harness] | join(",")' "$OUT")" = "codex" ]

    # And the machine really has the things it says it has.
    [ -f "$SPAWN_GATEWAY_ENV_FILE" ]
}

@test "KTD13: each wired harness round-trips in ITS OWN wire shape, with a Bearer header and a bounded budget" {
    install_claude
    install_codex ok
    run_setup --consent-shell-rc
    [ "$RC" -eq 0 ]

    [ "$(jq -r '[.verification.round_trip[].harness] | sort | join(",")' "$OUT")" = "claude-code,codex" ]
    [ -s "$GW_REQUEST_LOG" ]

    # The Anthropic-shaped call: Claude Code's route, its body shape, a Bearer
    # header, and a minimal output budget.
    local anth
    anth="$(jq -c 'select(.path == "/anthropic/v1/messages")' "$GW_REQUEST_LOG" | head -1)"
    [ -n "$anth" ]
    printf '%s' "$anth" | jq -e '.headers.authorization | startswith("Bearer ")' >/dev/null
    printf '%s' "$anth" | jq -e '.body.max_tokens <= 16' >/dev/null
    printf '%s' "$anth" | jq -e '.body.messages | length == 1' >/dev/null

    # The Codex-shaped call: a different route and a different body shape, so a
    # client that posted the Anthropic shape to both would fail here.
    local resp
    resp="$(jq -c 'select(.path == "/v1/responses")' "$GW_REQUEST_LOG" | head -1)"
    [ -n "$resp" ]
    printf '%s' "$resp" | jq -e '.headers.authorization | startswith("Bearer ")' >/dev/null
    printf '%s' "$resp" | jq -e '.body.max_output_tokens <= 16' >/dev/null
    printf '%s' "$resp" | jq -e '.body | has("input")' >/dev/null

    # The alias came from the gateway's SERVED list at run time, not from a
    # constant: it is one of the two this install's config declares.
    local used
    used="$(printf '%s' "$anth" | jq -r '.body.model')"
    [ "$used" = "kimi" ] || [ "$used" = "glm" ]

    # Layer two is attributed per harness rather than folded into one verdict.
    jq -e '.verification.config_validation[] | select(.harness == "codex") | .covered == true' "$OUT" >/dev/null
    jq -e '.verification.config_validation[] | select(.harness == "claude-code") | .covered == false' "$OUT" >/dev/null
}

@test "KTD13: the test alias comes from what the gateway SERVES, not from the config setup read" {
    install_claude
    # The gateway serves an alias this machine's config does not declare —
    # which is the ordinary state of a bare-machine install from the upstream
    # template, and the reason the alias cannot be picked from a local table.
    export GW_ALIASES="zeta"

    run_setup --consent-shell-rc
    [ "$RC" -eq 0 ]
    [ "$(jq -r '.verification.round_trip[0].alias' "$OUT")" = "zeta" ]
    [ "$(jq -r '.verification.round_trip[0].http_status' "$OUT")" = "200" ]
    # Guard the guard: the aliases the CONFIG declares are still the ones the
    # wiring emitted, so this is a divergence between served and configured and
    # not a suite that quietly renamed everything.
    [ "$(jq -r '[.wired[].harness] | join(",")' "$OUT")" = "claude-code" ]
    grep -qF 'kimi:' "$INSTALL/gateway.yaml"
}

# --- AE3: writing the files is not evidence ---------------------------------

@test "AE3/R16/R17: every config is written correctly but the credential is refused — the run fails with the auth class" {
    install_claude
    # The gateway authenticates the liveness probe and refuses the completion.
    # Nothing about the files setup wrote is wrong; only the round-trip can see
    # this, which is the whole reason the round-trip exists.
    export GW_EXTRA_ARGS="--scenario auth-reject-post"

    run_setup --consent-shell-rc
    [ "$RC" -ne 0 ]
    assert_one_json
    [ "$(jq -r '.ok' "$OUT")" = "false" ]
    [ "$(jq -r '.failed_step' "$OUT")" = "verify" ]
    [ "$(jq -r '.failure_class' "$OUT")" = "auth" ]
    jq -e '.error | test("REJECTED the stored credential")' "$OUT" >/dev/null

    # Guard the guard: the wiring really did happen, so this is a verification
    # failure over a correctly configured machine and not a run that fell over
    # earlier.
    [ -f "$SPAWN_GATEWAY_ENV_FILE" ]
    [ "$(step_status wire)" = "ok" ]
    [ "$(step_status start)" = "ok" ]
}

@test "AE5/R18: a failing round-trip names the step AND reports the install and the stored key as already done" {
    install_claude
    export GW_EXTRA_ARGS="--scenario upstream-5xx"

    run_setup --consent-shell-rc
    [ "$RC" -ne 0 ]
    assert_one_json
    [ "$(jq -r '.ok' "$OUT")" = "false" ]
    [ "$(jq -r '.failed_step' "$OUT")" = "verify" ]
    [ "$(jq -r '.steps[-1].status' "$OUT")" = "failed" ]

    # The operator must be able to see, without inspecting the machine, that
    # re-running will not redo the install or re-prompt for the key.
    [ "$(step_status acquire)" = "skipped" ]
    [ "$(step_status openrouter-key)" = "stored" ]
    [ "$(step_status gateway-token)" = "generated" ]
    jq -e --arg s "$SPAWN_KEYCHAIN_SERVICE" \
        '[.changed[] | select(.what == "keychain-item") | .target] | index($s + "/openrouter-api-key") != null' "$OUT" >/dev/null
    # F3: the release just installed is named, so an upstream break is
    # attributable to a version.
    [ "$(jq -r '.release.tag' "$OUT")" = "v9.9.9" ]
}

# --- AE7: the key never reaches the output ----------------------------------

@test "AE7/R5: the gateway's 401 body quotes the credential back — setup's output and stderr carry none of it" {
    install_claude
    export GW_EXTRA_ARGS="--scenario auth-reject-post --echo-credential-in-401"

    run_setup --consent-shell-rc
    [ "$RC" -ne 0 ]
    [ "$(jq -r '.ok' "$OUT")" = "false" ]

    local tok
    tok="$(stored_value gateway-token)"
    [ -n "$tok" ]
    run grep -F -- "$tok" "$OUT" "$ERR"
    [ "$status" -ne 0 ]
    run grep -F -- "$FAKE_OSASCRIPT_ANSWER" "$OUT" "$ERR"
    [ "$status" -ne 0 ]

    # Guard the guard: the fixture really does echo the presented credential, so
    # the assertion above is about setup's discipline and not about a fixture
    # that had nothing to leak.
    run curl -s -H "authorization: Bearer $tok" -H 'content-type: application/json' \
        -d '{"model":"kimi","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}' \
        "http://127.0.0.1:$PORT/anthropic/v1/messages"
    [ "$status" -eq 0 ]
    printf '%s' "$output" | grep -qF -- "$tok"
}

# --- R9 against the live process --------------------------------------------

@test "R9: a gateway that serves an unauthenticated request fails the run — the reject probe is load-bearing" {
    install_claude
    # An open proxy. Every credential-bearing probe passes against it, so only
    # the request that presents nothing can tell it apart from a guarded one.
    export GW_EXTRA_ARGS="--no-auth"

    run_setup --consent-shell-rc
    [ "$RC" -ne 0 ]
    assert_one_json
    [ "$(jq -r '.ok' "$OUT")" = "false" ]
    [ "$(jq -r '.failed_step' "$OUT")" = "verify" ]
    [ "$(jq -r '.failure_class' "$OUT")" = "open-proxy" ]
    jq -e '.error | test("open proxy")' "$OUT" >/dev/null
    # Guard the guard: failure_class 'open-proxy' is set ONLY in the 2xx branch
    # of the unauthenticated probe, and do_verify reaches that probe only after
    # every authenticated round-trip has already passed. So this run failed on
    # the reject probe and on nothing else. That used to be shown by curling
    # the gateway afterwards and expecting 200 — which quietly also asserted
    # that setup LEFT the open proxy running, and is now the opposite of the
    # contract.

    # AND THE OPEN PROXY IS DOWN. Refusing while leaving it up meant a machine
    # forwarding unauthenticated requests to a paid provider for as long as it
    # took someone to read the message — and under a KeepAlive agent, longer.
    run curl -s -o /dev/null -m 5 -w '%{http_code}' -X POST -H 'content-type: application/json' \
        -d '{"model":"kimi","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}' \
        "http://127.0.0.1:$PORT/anthropic/v1/messages"
    [ "$output" != "200" ]
    # ...and the operator is told so, rather than told to go do it themselves.
    jq -e '.error | test("was stopped|could NOT be stopped")' "$OUT" >/dev/null
}

@test "G3: with the unauthenticated reject probe removed, the open proxy reports SUCCESS — the probe is what catches it" {
    install_claude
    export GW_EXTRA_ARGS="--no-auth"
    local mutated
    # The mutation: the reject probe's verdict is discarded. Everything else —
    # the authenticated round-trips, the config validation — is untouched.
    mutated="$(mutant setup.sh 's@^        401.403) ;;$@        401|403|2*) ;;@')"

    run_setup --script "$mutated" --consent-shell-rc
    [ "$RC" -eq 0 ]
    [ "$(jq -r '.ok' "$OUT")" = "true" ]
}

# --- AE8: re-running and rotation -------------------------------------------

@test "AE8/R21/R22: a bare re-run reuses both stored secrets, prompts for nothing, and re-verifies" {
    install_claude
    run_setup --consent-shell-rc
    [ "$RC" -eq 0 ]
    local first_dialogs first_token first_key
    first_dialogs="$(dialog_count)"
    first_token="$(stored_value gateway-token)"
    first_key="$(stored_value openrouter-api-key)"
    [ "$first_dialogs" -eq 1 ]

    run_setup --consent-shell-rc
    [ "$RC" -eq 0 ]
    [ "$(jq -r '.ok' "$OUT")" = "true" ]
    [ "$(step_status openrouter-key)" = "reused" ]
    [ "$(step_status gateway-token)" = "reused" ]
    # Not one more dialog, and both stored values are byte-identical: shells
    # that were already open keep authenticating.
    [ "$(dialog_count)" -eq "$first_dialogs" ]
    [ "$(stored_value gateway-token)" = "$first_token" ]
    [ "$(stored_value openrouter-api-key)" = "$first_key" ]
    # And it re-verified rather than short-circuiting on "already set up".
    [ "$(jq -r '.verification.round_trip[0].http_status' "$OUT")" = "200" ]
}

@test "AE8/R22: --rotate-gateway-token warns about open shells BEFORE it acts, then replaces the token and restarts" {
    install_claude
    run_setup --consent-shell-rc
    [ "$RC" -eq 0 ]
    local before pid_before
    before="$(stored_value gateway-token)"
    pid_before="$(cat "$WORK/.gateway.pid")"

    run_setup --rotate-gateway-token --consent-shell-rc
    [ "$RC" -eq 0 ]
    [ "$(step_status gateway-token)" = "rotated" ]
    [ "$(stored_value gateway-token)" != "$before" ]

    # BEFORE it acts, not after: the warning is printed ahead of the token
    # write and therefore ahead of every step that follows it. The acquire
    # step's own line is the first thing that happens after the token step, so
    # a warning emitted at the end of the run — or at the restart — lands after
    # it and fails here.
    grep -q 'ALREADY OPEN' "$ERR"
    local warn_line after_line
    warn_line="$(grep -n 'ALREADY OPEN' "$ERR" | head -1 | cut -d: -f1)"
    after_line="$(grep -n 'already installed and runnable' "$ERR" | head -1 | cut -d: -f1)"
    [ -n "$warn_line" ] && [ -n "$after_line" ]
    [ "$warn_line" -lt "$after_line" ]

    # A rotation restarts rather than leaving the old process holding the old
    # value in memory — and the new gateway authenticates the new token, which
    # is what the round-trip proves.
    [ "$(cat "$WORK/.gateway.pid")" != "$pid_before" ]
    [ "$(jq -r '.verification.round_trip[0].http_status' "$OUT")" = "200" ]
    [ "$(dialog_count)" -eq 1 ]
}

@test "KTD5: --rotate-openrouter-key re-prompts once, replaces the stored item in place, and restarts the gateway" {
    install_claude
    run_setup --consent-shell-rc
    [ "$RC" -eq 0 ]
    local pid_before token_before
    pid_before="$(cat "$WORK/.gateway.pid")"
    token_before="$(stored_value gateway-token)"

    export FAKE_OSASCRIPT_ANSWER="fixture-openrouter-value-2"
    run_setup --rotate-openrouter-key --consent-shell-rc
    [ "$RC" -eq 0 ]
    [ "$(step_status openrouter-key)" = "rotated" ]
    [ "$(dialog_count)" -eq 2 ]
    [ "$(stored_value openrouter-api-key)" = "fixture-openrouter-value-2" ]
    # One item, updated in place, not a second one alongside it.
    [ "$(find "$FAKE_SECURITY_STORE_DIR" -type f | wc -l | tr -d ' ')" -eq 2 ]
    # The gateway is restarted so it reads the new key; the TOKEN is untouched,
    # so already-open shells are unaffected by a key rotation.
    [ "$(cat "$WORK/.gateway.pid")" != "$pid_before" ]
    [ "$(stored_value gateway-token)" = "$token_before" ]
}

@test "a run that failed after the key was stored re-runs to completion without prompting again" {
    install_claude
    export GW_EXTRA_ARGS="--scenario upstream-5xx"
    run_setup --consent-shell-rc
    [ "$RC" -ne 0 ]
    [ "$(dialog_count)" -eq 1 ]

    # The machine is left as an interrupted run leaves it: the install and both
    # credentials in place, no gateway running.
    # SIGTERM, not SIGKILL: the install binary passes the signal on to the
    # server it spawned, and a -9 would orphan that child still holding the
    # port — which would make the retry below talk to the FAILING gateway and
    # fail for a reason that has nothing to do with what this test asserts.
    kill "$(cat "$WORK/.gateway.pid")" 2>/dev/null || true
    rm -f "$WORK/.gateway.pid" "$WORK/.gateway.pid.bin"
    local i
    for i in $(seq 1 50); do
        curl -s -o /dev/null --connect-timeout 1 "http://127.0.0.1:$PORT/health" || break
        sleep 0.1
    done

    # Whatever went wrong, the key is stored, so the retry costs no interaction.
    export GW_EXTRA_ARGS=""
    run_setup --consent-shell-rc
    [ "$RC" -eq 0 ]
    [ "$(jq -r '.ok' "$OUT")" = "true" ]
    [ "$(dialog_count)" -eq 1 ]
    [ "$(step_status openrouter-key)" = "reused" ]
}

# --- the flag surface and the consent path ----------------------------------

@test "an unknown argument is refused with exit 2 and one JSON object" {
    run_setup --rotate-everything
    [ "$RC" -eq 2 ]
    assert_one_json
    [ "$(jq -r '.ok' "$OUT")" = "false" ]
    jq -e '.error | test("unexpected argument")' "$OUT" >/dev/null
    # Refused before anything was written or prompted for.
    [ "$(dialog_count)" -eq 0 ]
}

@test "KTD17/R18: a consent refusal mid-run exits 8 naming the flag AND reports what had already changed" {
    install_claude
    # A shell rc the operator owns: appending the source line needs consent.
    # This used to use the gw wrapper as its example of a consent gate; that
    # step is gone, but the MECHANISM is not — so the coverage moved to another
    # gate rather than being deleted with the step it happened to exercise.
    printf '# my own shell rc\n' > "$SPAWN_SHELL_RC"
    local before
    before="$(shasum -a 256 "$SPAWN_SHELL_RC" | awk '{print $1}')"

    run_setup
    [ "$RC" -eq 8 ]
    assert_one_json
    [ "$(jq -r '.consent_required' "$OUT")" = "shell-rc" ]
    [ "$(jq -r '.failed_step' "$OUT")" = "wire" ]
    # The operator is about to re-run: they need to know the credentials are
    # already stored and the install is already there.
    [ "$(step_status acquire)" = "skipped" ]
    [ "$(jq -r '[.changed[].what] | index("keychain-item") != null' "$OUT")" = "true" ]
    # And their file is untouched.
    [ "$(shasum -a 256 "$SPAWN_SHELL_RC" | awk '{print $1}')" = "$before" ]
}

@test "R11: with no harness installed the run fails at wire rather than reporting an empty success" {
    run_setup --consent-shell-rc
    [ "$RC" -ne 0 ]
    assert_one_json
    [ "$(jq -r '.ok' "$OUT")" = "false" ]
    [ "$(jq -r '.failed_step' "$OUT")" = "wire" ]
    jq -e '.error | test("no supported harness")' "$OUT" >/dev/null
    # Nothing was verified, and the object says so rather than omitting it.
    [ "$(jq -r '.verification' "$OUT")" = "null" ]
}

# --- G3: the deliberate-fail proofs -----------------------------------------

@test "G3: a run that treats a rejected round-trip as success makes the AE3 test go red" {
    install_claude
    export GW_EXTRA_ARGS="--scenario auth-reject-post"
    local mutated
    # The mutation: a 401 on the round-trip is accepted as a pass, exactly the
    # wrong-success AE3 is about.
    mutated="$(mutant setup.sh 's@^            200.201)$@            200|201|401|403)@')"

    run_setup --script "$mutated" --consent-shell-rc
    [ "$RC" -eq 0 ]
    [ "$(jq -r '.ok' "$OUT")" = "true" ]
    [ "$(jq -r '.verification.round_trip[0].http_status' "$OUT")" = "401" ]
}

@test "G3: building the state report in the error handler instead of accumulating makes the AE5 test go red" {
    install_claude
    export GW_EXTRA_ARGS="--scenario upstream-5xx"
    local mutated
    # The mutation: the failure object stops serializing the accumulator and
    # builds its `changed` list where the failure is handled — which is where
    # it has nothing to say.
    mutated="$(mutant setup.sh 's|--argjson steps "$steps" --argjson changed "$CHANGED_JSON"|--argjson steps "$steps" --argjson changed "[]"|')"

    run_setup --script "$mutated" --consent-shell-rc
    [ "$RC" -ne 0 ]
    # The failure is still named — that half survives — but everything the
    # machine already has is gone from the report, which is the half R18 is for.
    [ "$(jq -r '.failed_step' "$OUT")" = "verify" ]
    [ "$(jq -r '.changed | length' "$OUT")" -eq 0 ]
}

# ---------------------------------------------------------------------------
# The restart decision. This is the residual the code review found: start_verb
# was chosen from the ROTATION FLAGS, so a run that installed a new release
# while a gateway was already serving probed the OLD process, verified the OLD
# process, and reported success naming the NEW tag. Every claim the success
# object made about the new release was unsupported by the evidence collected.
# ---------------------------------------------------------------------------
@test "a run that installs a new release RESTARTS, so the old process cannot be what gets verified" {
    install_claude
    run_setup --consent-shell-rc
    [ "$RC" -eq 0 ]
    local first_pid
    first_pid="$(cat "$SPAWN_STATE_HOME/.gateway.pid" 2>/dev/null)"
    [ -n "$first_pid" ]
    kill -0 "$first_pid" 2>/dev/null

    # Publish a NEWER release so the second run installs rather than skips.
    export FAKE_CURL_TAG="v9.9.10"
    run_setup --consent-shell-rc

    # The property: a restart STOPS the process that was serving. A plain start
    # finds it alive and leaves it, which is how the old code came to verify a
    # gateway running the PREVIOUS binary while reporting the new tag.
    [ "$(step_status acquire)" = "installed" ]
    ! kill -0 "$first_pid" 2>/dev/null

    # The run does not reach a green round-trip here, and that is the fixture's
    # limit rather than the code's: fake-cargo's stub answers --version but does
    # not serve, so nothing can come up from a fixture-built install. G4 is
    # where a real build proves the rest.
    [ "$RC" -eq "$EX_UNREACHABLE_T" ]
    [ "$(jq -r '.failed_step' "$OUT")" = "start" ]
}

# ---------------------------------------------------------------------------
# R28, ORCHESTRATED. The supervisor verb is covered twenty-six ways in
# setup-supervisor.bats; what these two cover is the seam BETWEEN the verb and
# the run — the arm of do_setup that turns an "adopted" answer into the two
# `changed` entries and the step status. That arm ran in no test, so a report
# that silently stopped mentioning the startup path it now owns would have been
# green.
#
# The agents directory is this suite's own sandbox (SPAWN_LAUNCH_AGENTS_DIR),
# and the operator's real ~/Library/LaunchAgents is never read or written.
# ---------------------------------------------------------------------------

# plant_agent <basename> <program-path> <install-dir> — an operator-written
# agent in the shape the build machine's really is in.
plant_agent() {
    cat > "$SPAWN_LAUNCH_AGENTS_DIR/$1.plist" <<EOP
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.example.$1</string>
	<key>ProgramArguments</key>
	<array>
		<string>$2</string>
		<string>--config</string>
		<string>$3/gateway.yaml</string>
	</array>
	<key>KeepAlive</key>
	<true/>
	<key>RunAtLoad</key>
	<true/>
	<key>WorkingDirectory</key>
	<string>$3</string>
</dict>
</plist>
EOP
    printf '%s' "$SPAWN_LAUNCH_AGENTS_DIR/$1.plist"
}

@test "R28: an orchestrated run ADOPTS a supervising agent, records both files, and still verifies" {
    local plist
    plist="$(plant_agent gateway "$INSTALL/target/release/gateway" "$INSTALL")"
    install_claude

    run_setup --consent-shell-rc --consent-adopt-agent
    [ "$RC" -eq 0 ]
    assert_one_json
    [ "$(jq -r '.ok' "$OUT")" = "true" ]

    # The arm this test exists for.
    [ "$(step_status supervisor)" = "adopted" ]
    jq -e '[.changed[] | select(.what == "launcher")] | length == 1' "$OUT" >/dev/null
    jq -e '[.changed[] | select(.what == "launch-agent")] | length == 1' "$OUT" >/dev/null
    [ "$(jq -r '.changed[] | select(.what == "launcher") | .target' "$OUT")" = "$SPAWN_GATEWAY_LAUNCHER" ]
    [ "$(jq -r '.changed[] | select(.what == "launch-agent") | .target' "$OUT")" = "$plist" ]
    # KTD21's stated cost reaches the operator's report, not just the verb's.
    jq -e '.steps[] | select(.step == "supervisor") | .detail | test("STARTUP PATH")' "$OUT" >/dev/null

    # ...and it really happened on disk: the agent starts through the launcher,
    # which carries a Keychain read and no credential value.
    [ -x "$SPAWN_GATEWAY_LAUNCHER" ]
    [ "$(/usr/bin/plutil -convert json -o - "$plist" | jq -r '.ProgramArguments | join(" ")')" = "$SPAWN_GATEWAY_LAUNCHER" ]
    grep -qF 'find-generic-password' "$SPAWN_GATEWAY_LAUNCHER"
    run grep -F -- "$(stored_value gateway-token)" "$SPAWN_GATEWAY_LAUNCHER" "$OUT"
    [ "$status" -ne 0 ]

    # The run still reaches its normal outcome — adoption is not a detour.
    [ "$(jq -r '.verification.round_trip[0].http_status' "$OUT")" = "200" ]
    [ "$(jq -r '.verification.unauthenticated_probe.rejected' "$OUT")" = "true" ]
}

@test "R28: an agent still following a RETIRED install is rebased, and the run says so" {
    # The upgrade shape: the operator wrote gateway-1.0.0 into the plist, this
    # run resolves gateway-9.9.9, and the older tree no longer exists. Without
    # the rebase the step reports not-supervised and the run reports success
    # while launchd goes on starting a binary that is gone.
    local old plist
    old="$SPAWN_SEARCH_ROOT/gateway-1.0.0"
    plist="$(plant_agent gateway "$old/target/release/gateway" "$old")"
    [ ! -e "$old" ]
    install_claude

    run_setup --consent-shell-rc --consent-adopt-agent
    [ "$RC" -eq 0 ]
    assert_one_json
    [ "$(step_status supervisor)" = "adopted" ]

    # The rebase is REPORTED, not absorbed: an operator whose agent silently
    # started following a different install is told which one it left.
    jq -e '[.changed[] | select(.what == "launch-agent-rebase")] | length == 1' "$OUT" >/dev/null
    jq -e --arg o "$old" '.changed[] | select(.what == "launch-agent-rebase") | .detail | test($o)' "$OUT" >/dev/null
    jq -e --arg i "$INSTALL" '.steps[] | select(.step == "supervisor") | .detail | test($i)' "$OUT" >/dev/null

    # And the launcher execs the RESOLVED build, not the retired one.
    # The launcher starts the gateway as a child and supervises it rather than
    # exec'ing it, so the launch line is the argv followed by `&`.
    grep -qF -- "'$INSTALL/target/release/gateway' '--config'" "$SPAWN_GATEWAY_LAUNCHER"
    run grep -F -- "exec '$old" "$SPAWN_GATEWAY_LAUNCHER"
    [ "$status" -ne 0 ]
    # ...while the recorded original still names what was first adopted.
    grep -qF -- "# spawn-setup-original-argv: " "$SPAWN_GATEWAY_LAUNCHER"
    grep -qF -- "$old/target/release/gateway" "$SPAWN_GATEWAY_LAUNCHER"
}

@test "KTD17: a bare orchestrated run will not adopt the supervising agent without consent" {
    install_claude
    local plist
    plist="$(plant_agent gateway "$INSTALL/target/release/gateway" "$INSTALL")"

    # No --consent-adopt-agent. Adoption puts setup in this machine's startup
    # path, so the run must stop and ASK rather than quietly taking it over.
    run_setup --consent-shell-rc
    [ "$RC" -eq 8 ]
    assert_one_json
    [ "$(jq -r '.ok' "$OUT")" = "false" ]
    [ "$(jq -r '.failure_class' "$OUT")" = "consent" ]
    jq -r '.error' "$OUT" | grep -qF -- '--consent-adopt-agent'
    # The operator's plist is untouched: a refusal that had already repointed it
    # would be asking permission for something it had done.
    # A plain `! grep` would be exempt from set -e and could never fail this
    # test, which is the shape this repo has been bitten by; run it as a plain
    # command instead.
    run grep -F -- 'spawn-launch' "$plist"
    [ "$status" -ne 0 ]
}
