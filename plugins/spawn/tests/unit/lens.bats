#!/usr/bin/env bats
# U3 — headless lens.
#
# Everything runs against tests/fixtures/fake-gateway.py. The real gateway on
# port 4000 and OpenRouter are out of the test path by decision, and a suite
# that touched either would fight a live process or spend real money — both of
# which turn green into noise.
#
# Failure-class coverage is asserted on EXIT CODES, not messages (plan,
# Verification Contract): a caller branches on the number, so the number is
# what has to be pinned.

setup() {
    FIX="$(cd "$BATS_TEST_DIRNAME/../fixtures" && pwd)"
    LIB="$(cd "$BATS_TEST_DIRNAME/../../lib" && pwd)"
    LENS="$LIB/lens.sh"
    CTL="$LIB/spawnctl.sh"
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/gw-lens.XXXXXX")"
    WORK="$(cd "$WORK" && pwd -P)"
    TOKEN="tok-lens-s3cr3t-9f2a"
    GW_PID=""
    SPILLS=()
    REAL_CURL="$(command -v curl)"

    # State and search root are redirected into $WORK so no test can touch
    # ~/.gateway.pid / .log / .lock or discover the real ~/gateway-* install.
    export SPAWN_STATE_HOME="$WORK"
    export SPAWN_SEARCH_ROOT="$WORK/searchroot"
    mkdir -p "$SPAWN_SEARCH_ROOT"
    # Own TMPDIR per test. Scratch dirs and spill files are named by pattern,
    # so a leftover from an unrelated (or killed) run in a shared /tmp would
    # otherwise be indistinguishable from one this test just leaked.
    export TMPDIR="$WORK/tmp"
    mkdir -p "$TMPDIR"
    # lens.sh now sources secrets.sh for the env/Keychain token fallback, so the
    # `security` seam has to be redirected here too. Without this, any test
    # whose config carries no token would query the REAL login Keychain of
    # whoever runs the suite.
    export SPAWN_SECURITY_BIN="$FIX/fake-security.sh"
    export FAKE_SECURITY_STORE_DIR="$WORK/kc-store"
    export FAKE_SECURITY_RECORD_DIR="$WORK/kc-record"
    export SPAWN_KEYCHAIN_SERVICE="spawn-gateway-test"
    export SPAWN_KEYCHAIN_ACCOUNT_TOKEN="gateway-token-test"
    unset GATEWAY_TOKEN
    export SPAWN_CONNECT_TIMEOUT=2
    export SPAWN_PROBE_TIMEOUT=5
    export SPAWN_START_TIMEOUT=10
    export SPAWN_LOCK_TIMEOUT=30
    unset SPAWN_INSTALL_DIR SPAWN_CONFIG SPAWN_MODELS_JSON
    unset SPAWN_LENS_TIMEOUT SPAWN_SPILL_BYTES SPAWN_LENS_MAX_TOKENS
    # Default at a port nothing serves: a test that forgets to point somewhere
    # must not probe the REAL gateway on 4000.
    export SPAWN_BASE_URL="http://127.0.0.1:1/anthropic"
}

teardown() {
    if [ -n "${GW_PID:-}" ]; then
        kill "$GW_PID" 2>/dev/null || true
        wait "$GW_PID" 2>/dev/null || true
    fi
    local f
    for f in "${SPILLS[@]:-}"; do
        [ -n "$f" ] && rm -f "$f"
    done
    for p in $(pgrep -f "$WORK" 2>/dev/null); do
        [ "$p" = "$$" ] && continue
        kill -9 "$p" 2>/dev/null
    done
    rm -rf "$WORK"
}

# --- helpers ---------------------------------------------------------------

# make_config <path> <token> [alias=model ...] — enough gateway.yaml for the
# control layer's token read and drift scan. The bind port is irrelevant here:
# these tests never start a gateway, they point SPAWN_BASE_URL at the fixture.
make_config() {
    local path="$1" token="$2"; shift 2
    {
        printf 'server:\n'
        printf '  bind: "127.0.0.1:4000"\n'
        # An EMPTY token omits the line entirely, because that is what `setup`
        # actually leaves behind when it retires the config token — it removes
        # the key rather than blanking it. Writing `token:` with the trailing
        # comment still attached would model a state setup never produces, and
        # every parser reads that as the literal comment text (a garbage
        # non-empty token) rather than as absent.
        if [ -n "$token" ]; then
            printf '  token: %s        # Bearer or x-api-key\n' "$token"
        fi
        printf '\nmodels:\n'
        local spec
        for spec in "$@"; do
            printf '  %s:\n' "${spec%%=*}"
            printf '    model: %s\n' "${spec#*=}"
        done
    } > "$path"
}

# start_fixture <scenario> <aliases> [extra fake-gateway.py args...]
start_fixture() {
    local scenario="$1" aliases="$2"; shift 2
    local portfile="$WORK/port"
    # Clear it first. A test that restarts the fixture with a new scenario would
    # otherwise read the PREVIOUS run's port the instant the wait loop checks,
    # and silently point every later assertion at a dead or wrong endpoint.
    rm -f "$portfile"
    python3 "$FIX/fake-gateway.py" \
        --token "$TOKEN" --aliases "$aliases" --scenario "$scenario" \
        --port-file "$portfile" "$@" >"$WORK/gw.out" 2>"$WORK/gw.err" &
    GW_PID=$!
    local i
    for i in $(seq 1 100); do
        [ -s "$portfile" ] && break
        sleep 0.05
    done
    PORT="$(cat "$portfile")"
    [ -n "$PORT" ]
    export SPAWN_BASE_URL="http://127.0.0.1:$PORT/anthropic"

    local a
    local -a specs=() parts=()
    IFS=',' read -ra parts <<< "$aliases"
    for a in "${parts[@]}"; do specs+=("$a=up/$a"); done
    make_config "$WORK/gateway.yaml" "$TOKEN" "${specs[@]}"
    export SPAWN_CONFIG="$WORK/gateway.yaml"
}

# Run the lens capturing STDOUT ONLY, with the prompt on stdin. Every JSON
# assertion goes through this, so a diagnostic that leaked onto stdout breaks
# the parse — KTD2's "diagnostics on stderr only" is enforced by the harness
# shape rather than by a separate test remembering to check.
lens() {
    local prompt="$1"; shift
    run bash -c 'printf "%s" "$1" | bash "$2" "${@:3}" 2>/dev/null' _ "$prompt" "$LENS" "$@"
}

# Same, but stderr is kept and stdout dropped — for asserting what a human sees.
lens_stderr() {
    local prompt="$1"; shift
    run bash -c 'printf "%s" "$1" | bash "$2" "${@:3}" 2>&1 1>/dev/null' _ "$prompt" "$LENS" "$@"
}

# NEGATIVE ASSERTIONS. bats runs tests under `set -e`, but POSIX exempts a
# pipeline beginning with `!` from it — so `! grep -q "$TOKEN" file` NEVER fails
# a test, it just evaluates and moves on. That is not theory: a mutation putting
# the token back into curl's argv passed the `! grep` version of the KTD6 test.
# These helpers fail as PLAIN commands, which set -e does honour.
refute_file_match() {   # <pattern> <file...>
    local pat="$1"; shift
    if grep -qE -- "$pat" "$@"; then
        printf 'refute_file_match: unexpected match for %s in %s\n' "$pat" "$*" >&2
        grep -nE -- "$pat" "$@" >&2
        return 1
    fi
    return 0
}
refute_stdin_match() {  # <pattern>, reads stdin; use as the LAST pipeline stage
    local pat="$1" buf
    buf="$(cat)"
    if printf '%s' "$buf" | grep -qE -- "$pat"; then
        printf 'refute_stdin_match: unexpected match for %s in:\n%s\n' "$pat" "$buf" >&2
        return 1
    fi
    return 0
}

# A PATH shim recording every curl argv. fake-gateway.py records HEADERS, not
# argv, so the KTD6 "never in a child's argv" claim needs its own instrument.
# It also records the mode of any --config file, which is the one exception R12
# allows (ephemeral, 0600, removed within the invocation).
make_curl_shim() {
    mkdir -p "$WORK/bin"
    cat > "$WORK/bin/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$WORK/curl-argv.log"
prev=""
for a in "\$@"; do
  if [ "\$prev" = "--config" ]; then
    stat -f '%Sp %N' "\$a" >> "$WORK/curl-cfgmode.log" 2>/dev/null \
      || stat -c '%A %n' "\$a" >> "$WORK/curl-cfgmode.log" 2>/dev/null
  fi
  prev="\$a"
done
exec "$REAL_CURL" "\$@"
EOF
    chmod +x "$WORK/bin/curl"
    export PATH="$WORK/bin:$PATH"
}

# --- happy path ------------------------------------------------------------

@test "happy path: a prompt on stdin returns exit 0 and one JSON object carrying the model's text" {
    start_fixture healthy "alpha" --response-text "the canned answer"

    lens "what is 2+2?" --alias alpha
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -s 'length')" = "1" ]
    [ "$(echo "$output" | jq -r '.text')" = "the canned answer" ]
    [ "$(echo "$output" | jq -r '.alias')" = "alpha" ]
    [ "$(echo "$output" | jq -r '.output_file')" = "null" ]
    [ "$(echo "$output" | jq -r '.error')" = "null" ]
    [ "$(echo "$output" | jq -r '.usage.input_tokens')" = "11" ]
    [ "$(echo "$output" | jq -r '.usage.output_tokens')" = "7" ]

    # stderr carries no JSON: a consumer that merged the two streams would
    # otherwise parse a diagnostic as the answer.
    lens_stderr "what is 2+2?" --alias alpha
    echo "$output" | refute_stdin_match '^\{'
}

@test "happy path: --prompt-file is an equivalent intake and the prompt reaches the gateway intact" {
    start_fixture healthy "alpha" --request-log "$WORK/req.jsonl"
    # A prompt with the bytes that break naive string interpolation.
    printf 'diff --git a/x b/x\n+  const s = "quote\\backslash";\n' > "$WORK/prompt.txt"

    run bash -c 'bash "$1" --alias alpha --prompt-file "$2" 2>/dev/null' _ "$LENS" "$WORK/prompt.txt"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -s 'length')" = "1" ]

    local sent
    sent="$(jq -r '.body.messages[0].content' < "$WORK/req.jsonl")"
    [ "$sent" = "$(cat "$WORK/prompt.txt")" ]
    # max_tokens is always sent — the real messages API requires it even though
    # the fixture tolerates its absence.
    [ "$(jq -r '.body.max_tokens' < "$WORK/req.jsonl")" != "null" ]
    [ "$(jq -r '.body.model' < "$WORK/req.jsonl")" = "alpha" ]
}

@test "no cwd dependence: the same call from / behaves identically" {
    start_fixture healthy "alpha" --response-text "same everywhere"

    run bash -c 'cd / && printf hi | bash "$1" --alias alpha 2>/dev/null' _ "$LENS"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.text')" = "same everywhere" ]
}

@test "config resolution: with SPAWN_CONFIG unset the path comes out of ensure, and the call still succeeds" {
    # Every other test in this file exports SPAWN_CONFIG, which short-circuits
    # lens.sh's config resolution entirely — so the branch that actually runs in
    # production (read `.config` out of ensure's JSON) was never exercised. It
    # was verified that replacing ensure's `config` field with null left the
    # whole suite green while breaking the lens at runtime: no config, no token,
    # 401, exit 7.
    start_fixture healthy "alpha" --response-text "resolved through ensure"

    # start_fixture exports SPAWN_CONFIG. Production does not have it set.
    unset SPAWN_CONFIG
    [ -z "${SPAWN_CONFIG:-}" ]

    # A resolvable install: gateway.yaml beside a REGULAR, EXECUTABLE binary at
    # the canonical path. resolve_install_dir hard-fails a set-but-invalid
    # override even in soft mode, so the binary has to exist — it is never
    # executed here, because the fixture is already up and no start is attempted.
    mkdir -p "$WORK/install/target/release"
    printf '#!/bin/sh\nexit 1\n' > "$WORK/install/target/release/gateway"
    chmod +x "$WORK/install/target/release/gateway"
    make_config "$WORK/install/gateway.yaml" "$TOKEN" "alpha=up/alpha"
    export SPAWN_INSTALL_DIR="$WORK/install"

    # PRECONDITION: ensure really emits the install dir's config path. Without
    # this, the success below could be explained by anything.
    run bash -c 'bash "$1" ensure alpha 2>/dev/null' _ "$CTL"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.config')" = "$WORK/install/gateway.yaml" ]

    # CONSEQUENCE: the token was read from that file. The fixture 401s anything
    # that is not its token, and an unresolved config yields an EMPTY token —
    # so exit 0 with the canned text is only reachable if resolution worked.
    lens "what is 2+2?" --alias alpha
    [ "$status" -eq 0 ]
    [ "$status" -ne 7 ]
    [ "$(echo "$output" | jq -s 'length')" = "1" ]
    [ "$(echo "$output" | jq -r '.text')" = "resolved through ensure" ]
    [ "$(echo "$output" | jq -r '.error')" = "null" ]
}

# --- input discipline (KTD8) -----------------------------------------------

@test "KTD8: an argv prompt is refused with code 2 and never sent" {
    start_fixture healthy "alpha" --request-log "$WORK/req.jsonl"

    lens "" --alias alpha "here is my 40KB diff"
    [ "$status" -eq 2 ]
    [ "$(echo "$output" | jq -s 'length')" = "1" ]
    [ "$(echo "$output" | jq -r '.error')" = "usage" ]
    # Nothing reached the gateway: the refusal is before the wire.
    [ ! -f "$WORK/req.jsonl" ]
}

@test "a missing --alias is code 2 before any network call" {
    export SPAWN_BASE_URL="http://127.0.0.1:1/anthropic"
    lens "hi"
    [ "$status" -eq 2 ]
    [ "$(echo "$output" | jq -r '.ok')" = "false" ]
}

@test "KTD5: an alias with a control byte is refused with code 2 before any network call" {
    # BASE_URL points at nothing, so a probe would return 3. Getting 2 proves
    # the grammar check ran FIRST.
    export SPAWN_BASE_URL="http://127.0.0.1:1/anthropic"
    lens "hi" --alias "$(printf 'al\033[31mpha')"
    [ "$status" -eq 2 ]
    lens "hi" --alias 'alpha;rm -rf /'
    [ "$status" -eq 2 ]
}

@test "a 200 with no text block is exit 5, not a green empty answer" {
    # FOUND BY DRIVING THE REAL GATEWAY, not by a fixture. kimi at
    # --max-tokens 40 returned stop_reason=max_tokens with content types
    # ["thinking"] and no text block, three runs out of three. The extraction
    # selects `.type == "text"`, so the lens reported ok:true / bytes:0 /
    # exit 0 — the caller paid for 40 output tokens and got a green empty
    # answer. A fan-out orchestrator reads that as a successful empty review.
    start_fixture thinking-only "alpha"

    lens "explain something" --alias alpha --max-tokens 40
    [ "$status" -eq 5 ]
    [ "$(echo "$output" | jq -s 'length')" = "1" ]
    [ "$(echo "$output" | jq -r '.ok')" = "false" ]
    [ "$(echo "$output" | jq -r '.error')" = "no_text_truncated" ]
    # The detail must name the remedy — the whole point of splitting this from
    # the generic empty case is that raising the budget fixes THIS one.
    run grep -q 'raise --max-tokens' <<< "$(echo "$output" | jq -r '.detail')"
    [ "$status" -eq 0 ]
}

@test "a 200 with no text and no truncation is a distinct error value" {
    # stop_reason end_turn: the model simply said nothing. Raising the budget
    # would not help, so it must not claim that it would.
    start_fixture empty-text "alpha"

    lens "explain something" --alias alpha
    [ "$status" -eq 5 ]
    [ "$(echo "$output" | jq -r '.error')" = "no_text_in_response" ]
    run grep -q 'raise --max-tokens' <<< "$(echo "$output" | jq -r '.detail')"
    [ "$status" -ne 0 ]
}

@test "R1: --timeout 0 is refused with code 2, not accepted as 'no deadline'" {
    # `curl --max-time 0` does NOT mean "no cap" — it DISABLES the deadline, so
    # the value a caller reads as "don't impose an artificial limit" would be an
    # unbounded hang. Measured before the fix: it ran until the peer died and
    # exited rc=56, which this script then classified as exit 3 (unreachable)
    # rather than exit 6 (deadline) — so the failure was also mislabelled.
    #
    # BASE_URL points at a dead port, so a probe would give 3. Getting 2 proves
    # the refusal happens during validation, before any network call.
    export SPAWN_BASE_URL="http://127.0.0.1:1/anthropic"
    lens "hi" --alias kimi --timeout 0
    [ "$status" -eq 2 ]
    [ "$(echo "$output" | jq -s 'length')" = "1" ]
    [ "$(echo "$output" | jq -r '.error')" = "usage" ]

    # A fractional zero is the same hole spelled differently.
    lens "hi" --alias kimi --timeout 0.0
    [ "$status" -eq 2 ]

    # And the previously unvalidated connect timeout.
    export SPAWN_CONNECT_TIMEOUT=0
    lens "hi" --alias kimi
    [ "$status" -eq 2 ]
    [ "$(echo "$output" | jq -r '.error')" = "usage" ]
    unset SPAWN_CONNECT_TIMEOUT
}

@test "an empty prompt is code 2, not an empty call to a paid model" {
    start_fixture healthy "alpha" --request-log "$WORK/req.jsonl"
    lens "" --alias alpha
    [ "$status" -eq 2 ]
    [ ! -f "$WORK/req.jsonl" ]
}

# --- failure classes (KTD2) ------------------------------------------------

@test "AE4 unknown alias: code 4, distinct from gateway-down, and the JSON names the alias" {
    start_fixture healthy "alpha,beta"

    lens "hi" --alias gamma
    [ "$status" -eq 4 ]
    [ "$(echo "$output" | jq -s 'length')" = "1" ]
    [ "$(echo "$output" | jq -r '.alias')" = "gamma" ]
    [ "$(echo "$output" | jq -r '.error')" = "alias_unknown" ]
    # R3: the object is in the LENS's vocabulary — the fields a consumer
    # branches on are present even though the failure came from the preflight —
    # and ensure's own object rides along whole under `preflight`.
    [ "$(echo "$output" | jq 'has("text") and has("usage") and has("detail")')" = "true" ]
    [ "$(echo "$output" | jq -r '.preflight.served_aliases|sort|join(",")')" = "alpha,beta" ]
    # AE4's actual demand: 4 is not 3.
    [ "$status" -ne 3 ]
}

@test "R3: a preflight auth failure reaches the consumer as the lens's own enum, not spawnctl prose" {
    # Exit 7 out of the PREFLIGHT (ensure's probe is rejected before the lens
    # ever reaches the messages endpoint). ensure's object is {verb, error:
    # <prose>} — forwarding it verbatim put English where the enum belongs and
    # dropped text/usage, breaking `.error` branching exactly when every caller
    # in a fan-out fails at once.
    start_fixture healthy "alpha"
    make_config "$WORK/bad.yaml" "wrong-token" "alpha=up/alpha"
    export SPAWN_CONFIG="$WORK/bad.yaml"

    lens "hi" --alias alpha
    [ "$status" -eq 7 ]
    [ "$(echo "$output" | jq -s 'length')" = "1" ]
    [ "$(echo "$output" | jq -r '.error')" = "auth_rejected" ]
    [ "$(echo "$output" | jq -r '.exit_code')" = "7" ]
    [ "$(echo "$output" | jq 'has("text") and has("usage") and has("detail")')" = "true" ]
    # Nothing was lost in the rewrap: ensure's object is intact underneath.
    [ "$(echo "$output" | jq -r '.preflight.verb')" = "ensure" ]
    [ "$(echo "$output" | jq -r '.preflight.exit_code')" = "7" ]
}

@test "gateway down and unstartable: code 3, distinguishable from AE4's code 4" {
    start_fixture down "alpha"
    # Search root is empty and SPAWN_INSTALL_DIR is unset, so no start is
    # even possible — this is the "unreachable AND could not be started" class.

    lens "hi" --alias alpha
    [ "$status" -eq 3 ]
    [ "$(echo "$output" | jq -s 'length')" = "1" ]
    [ "$status" -ne 4 ]
}

@test "upstream 5xx: code 5 with the generic upstream error value" {
    start_fixture upstream-5xx "alpha"

    lens "hi" --alias alpha
    [ "$status" -eq 5 ]
    [ "$(echo "$output" | jq -s 'length')" = "1" ]
    [ "$(echo "$output" | jq -r '.error')" = "upstream_error" ]
    [ "$(echo "$output" | jq -r '.text')" = "null" ]
}

@test "upstream 429: same class as 5xx but the error field says rate_limited" {
    start_fixture throttle-429 "alpha"

    lens "hi" --alias alpha
    [ "$status" -eq 5 ]
    [ "$(echo "$output" | jq -r '.error')" = "rate_limited" ]
}

@test "context overflow: the error field is context_overflow, not a generic upstream error" {
    # Why this matters: the lens never applies a context window. Collapsed into
    # 'upstream_error', a review-sized diff on a small-window alias invites a
    # retry against a prompt that can NEVER fit.
    start_fixture context-length "alpha"

    lens "an enormous diff" --alias alpha
    [ "$status" -eq 5 ]
    [ "$(echo "$output" | jq -r '.error')" = "context_overflow" ]
    [ "$(echo "$output" | jq -r '.error')" != "upstream_error" ]
    [ "$(echo "$output" | jq -r '.error')" != "rate_limited" ]
}

@test "token rejected on the messages endpoint is code 7, not the unreachable class" {
    start_fixture healthy "alpha"

    # Sanity: with the config's real token this alias answers 0.
    lens "hi" --alias alpha
    [ "$status" -eq 0 ]

    # Now point at a config whose server.token is wrong. The fixture 401s
    # anything that is not --token, and a 401 must stay its own class: read as
    # 'down' it would send ensure into a start that collides with the running
    # gateway.
    make_config "$WORK/bad.yaml" "wrong-token" "alpha=up/alpha"
    export SPAWN_CONFIG="$WORK/bad.yaml"
    lens "hi" --alias alpha
    [ "$status" -eq 7 ]
    [ "$status" -ne 3 ]
    [ "$(echo "$output" | jq -s 'length')" = "1" ]
}

@test "timeout: the slow fixture past a short --timeout is code 6 and leaves no child alive" {
    start_fixture slow "alpha" --delay 10

    lens "hi" --alias alpha --timeout 1
    [ "$status" -eq 6 ]
    [ "$(echo "$output" | jq -s 'length')" = "1" ]
    [ "$(echo "$output" | jq -r '.error')" = "deadline_exceeded" ]

    # No orphan: the lens's curl carries a --config path under .../gwlens.*, so
    # any survivor is findable by that signature alone.
    sleep 0.3
    [ "$(pgrep -f 'gwlens' 2>/dev/null | wc -l | tr -d ' ')" -eq 0 ]
}

# --- stdout discipline regression (KTD2) -----------------------------------

@test "KTD2 regression: EVERY failure path prints exactly one JSON object on stdout" {
    # The captured bug this pins: a consuming agent misread a stream it should
    # have parsed as one object. One assertion per class, in one test, so a new
    # failure path cannot be added without landing here.
    # bats runs tests under `set -e`, so a capture that exits non-zero must be
    # guarded or the test aborts at the first failure class it is meant to
    # assert. && / || keeps the exit code without tripping the shell.
    local out rc
    cap() { out="$(printf hi | bash "$LENS" "$@" 2>/dev/null)" && rc=0 || rc=$?; }

    # 2 — usage
    cap
    [ "$rc" -eq 2 ]; [ "$(echo "$out" | jq -s 'length')" = "1" ]
    [ "$(echo "$out" | jq -r '.exit_code')" = "2" ]

    # 3 — unreachable
    start_fixture down "alpha"
    cap --alias alpha
    [ "$rc" -eq 3 ]; [ "$(echo "$out" | jq -s 'length')" = "1" ]
    kill "$GW_PID" 2>/dev/null || true; GW_PID=""

    # 4 — alias unknown
    start_fixture healthy "alpha"
    cap --alias nosuch
    [ "$rc" -eq 4 ]; [ "$(echo "$out" | jq -s 'length')" = "1" ]
    [ "$(echo "$out" | jq -r '.exit_code')" = "4" ]
    kill "$GW_PID" 2>/dev/null || true; GW_PID=""

    # 5 — upstream
    start_fixture upstream-5xx "alpha"
    cap --alias alpha
    [ "$rc" -eq 5 ]; [ "$(echo "$out" | jq -s 'length')" = "1" ]
    [ "$(echo "$out" | jq -r '.exit_code')" = "5" ]
    kill "$GW_PID" 2>/dev/null || true; GW_PID=""

    # 5 — context overflow
    start_fixture context-length "alpha"
    cap --alias alpha
    [ "$rc" -eq 5 ]; [ "$(echo "$out" | jq -s 'length')" = "1" ]
    [ "$(echo "$out" | jq -r '.error')" = "context_overflow" ]
    kill "$GW_PID" 2>/dev/null || true; GW_PID=""

    # 6 — deadline
    start_fixture slow "alpha" --delay 10
    cap --alias alpha --timeout 1
    [ "$rc" -eq 6 ]; [ "$(echo "$out" | jq -s 'length')" = "1" ]
    [ "$(echo "$out" | jq -r '.exit_code')" = "6" ]
    kill "$GW_PID" 2>/dev/null || true; GW_PID=""

    # 7 — token rejected
    start_fixture healthy "alpha"
    make_config "$WORK/bad.yaml" "wrong-token" "alpha=up/alpha"
    export SPAWN_CONFIG="$WORK/bad.yaml"
    cap --alias alpha
    [ "$rc" -eq 7 ]; [ "$(echo "$out" | jq -s 'length')" = "1" ]
}

# --- token discipline (KTD6) -----------------------------------------------

@test "KTD6: the token never appears in the lens's curl argv, nor on stdout or stderr" {
    make_curl_shim
    start_fixture healthy "alpha" --response-text "ok"

    run bash -c 'printf hi | bash "$1" --alias alpha >"$2/out" 2>"$2/err"' _ "$LENS" "$WORK"
    [ "$(jq -r '.text' < "$WORK/out")" = "ok" ]

    # Scope: the LENS's own curl invocations, identified by --config. (The
    # control layer's probe is U2's surface and passes its token by -H; that is
    # not this unit's argv to fix, and folding it in here would make this test
    # assert something U3 does not own.)
    grep -- '--config' "$WORK/curl-argv.log"
    grep -- '--config' "$WORK/curl-argv.log" | refute_stdin_match "$TOKEN"

    # And the mechanism is present, not just the absence of the literal.
    grep -q -- '--config' "$WORK/curl-argv.log"
    # The one file R12 allows is mode 0600.
    grep -q '^-rw-------' "$WORK/curl-cfgmode.log"

    refute_file_match "$TOKEN" "$WORK/out"
    refute_file_match "$TOKEN" "$WORK/err"
}

@test "KTD6: the token stays out of stdout and stderr on failure paths too" {
    start_fixture upstream-5xx "alpha"
    run bash -c 'printf hi | bash "$1" --alias alpha >"$2/out" 2>"$2/err"' _ "$LENS" "$WORK"
    [ "$status" -eq 5 ]
    refute_file_match "$TOKEN" "$WORK/out"
    refute_file_match "$TOKEN" "$WORK/err"
}

@test "KTD6: the ephemeral credential file does not survive the invocation" {
    start_fixture healthy "alpha"
    lens "hi" --alias alpha
    [ "$status" -eq 0 ]
    # No gwlens.* scratch dir is left behind anywhere in TMPDIR.
    [ -z "$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'gwlens.*' 2>/dev/null)" ]
}

# --- spill (KTD8) ----------------------------------------------------------

@test "KTD8 spill: a response above the threshold returns output_file, and the file holds the full body" {
    start_fixture healthy "alpha" --response-bytes 40000

    lens "hi" --alias alpha
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -s 'length')" = "1" ]
    [ "$(echo "$output" | jq -r '.text')" = "null" ]

    local f; f="$(echo "$output" | jq -r '.output_file')"
    SPILLS+=("$f")
    [ -n "$f" ] && [ "$f" != "null" ]
    [ -f "$f" ]
    # The whole body is there — a truncated spill is worse than no spill.
    local bytes; bytes="$(wc -c < "$f" | tr -d ' ')"
    [ "$bytes" -gt 16384 ]
    [ "$bytes" = "$(echo "$output" | jq -r '.bytes')" ]
    # text and output_file are mutually exclusive; both-set makes the
    # consumer's branch meaningless.
    [ "$(echo "$output" | jq -r 'select(.text != null and .output_file != null) | "BOTH"')" = "" ]
}

@test "KTD8 spill: a small response stays inline, and the threshold is overridable" {
    start_fixture healthy "alpha" --response-text "tiny"

    lens "hi" --alias alpha
    [ "$(echo "$output" | jq -r '.text')" = "tiny" ]
    [ "$(echo "$output" | jq -r '.output_file')" = "null" ]

    export SPAWN_SPILL_BYTES=1
    lens "hi" --alias alpha
    local f; f="$(echo "$output" | jq -r '.output_file')"
    SPILLS+=("$f")
    [ "$(echo "$output" | jq -r '.text')" = "null" ]
    [ "$(cat "$f")" = "tiny" ]
}

@test "--output-file forces the spill destination and gets the full body" {
    start_fixture healthy "alpha" --response-text "written to my path"

    lens "hi" --alias alpha --output-file "$WORK/answer.txt"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.output_file')" = "$WORK/answer.txt" ]
    [ "$(echo "$output" | jq -r '.text')" = "null" ]
    [ "$(cat "$WORK/answer.txt")" = "written to my path" ]
}

# --- AE5: no spend logic ---------------------------------------------------

@test "AE5: several concurrent calls to one alias all proceed, with no prompt, cap or warning" {
    start_fixture healthy "alpha" --response-text "unattended answer"

    local i
    local -a pids=()
    for i in $(seq 1 6); do
        printf 'call %s' "$i" | bash "$LENS" --alias alpha \
            > "$WORK/out.$i" 2> "$WORK/err.$i" &
        pids+=("$!")
    done
    # Wait on THESE pids, not a bare `wait`: the fixture server is also a child
    # of this shell and never exits, so a bare wait hangs the suite forever.
    for i in "${pids[@]}"; do wait "$i" || true; done

    for i in $(seq 1 6); do
        [ "$(jq -r '.exit_code' < "$WORK/out.$i")" = "0" ]
        [ "$(jq -r '.text' < "$WORK/out.$i")" = "unattended answer" ]
        [ "$(jq -s 'length' < "$WORK/out.$i")" = "1" ]
        # Nothing paused for a human and nothing warned about cost.
        refute_file_match 'cap|warn|confirm|budget|spend|proceed\?|\[y/n\]' "$WORK/err.$i"
    done
}

# allowlist_lint <readme> — prints every offending line and returns grep's
# sense: 0 means a violation WAS found, so the tests below assert non-zero.
# Same shape as launch.bats' config_write_lint, and a function rather than
# inline greps so the self-test below can run it against a planted copy.
#
# Every pattern is anchored on a RULE (`Bash(bash …`) or on an executable verb,
# never on bare prose. The README deliberately NAMES the wrong paths in order to
# warn about them, and a lint that cannot tell a warning from a recommendation
# would force the warning to be deleted.
allowlist_lint() {  # <readme>
    local readme="$1" found=0 hits
    # 1. VERIFIED ON A REAL INSTALL, 2026-08-07. The README used to tell people
    #    to allowlist ~/.claude/plugins/marketplaces/<mkt>/plugins/<plugin>/lib/
    #    lens.sh. That path does not exist — installs land under
    #    cache/<mkt>/<plugin>/<version>/ and marketplaces/<mkt>/ was EMPTY.
    #    Worst failure shape in the plugin: a rule that matches nothing does not
    #    error, it parks an unattended fan-out on a permission prompt forever —
    #    no exit code, no JSON, nothing to branch on.
    if hits="$(grep -n 'Bash(bash [^)]*plugins/marketplaces' "$readme")"; then
        printf 'LINT: allowlist rule names the marketplaces path, which does not exist:\n%s\n' "$hits"
        found=1
    fi
    # 2. THE CLASS, not just the allowlist instance. The same fictional path was
    #    ALSO in the foreign-consumer resolution recipe and survived the first
    #    fix because only the allowlist section was corrected. Any EXECUTABLE
    #    reference (a glob, a for-loop, a bash or install invocation) to a plugin
    #    path under marketplaces/ is wrong.
    if hits="$(grep -nE '(for |ls |bash |cp |install |\[ -f )[^#]*plugins/marketplaces/[^ ]*/plugins/' "$readme")"; then
        printf 'LINT: executable reference to a plugin path under marketplaces/:\n%s\n' "$hits"
        found=1
    fi
    # 3. R16: the rule must not be version-pinned. The version is a real path
    #    component of an install, so a rule carrying one stops matching on the
    #    next upgrade — silently, as a stalled fan-out.
    if hits="$(grep -nE 'Bash\(bash [^)]*/[0-9]+\.[0-9]+(\.[0-9]+)?/' "$readme")"; then
        printf 'LINT: allowlist rule is version-pinned and dies on the next upgrade:\n%s\n' "$hits"
        found=1
    fi
    # 4. R16 again, the other half: the fix for (3) is NOT a wildcarded cache
    #    path in permissions.allow — that authorizes whatever else ever lands
    #    under it. No rule may name the cache at all; the wildcard belongs
    #    inside bin/spawn-lens, behind one stable path the user owns.
    if hits="$(grep -nE 'Bash\(bash [^)]*plugins/cache' "$readme")"; then
        printf 'LINT: allowlist rule names a cache path; use the stable shim instead:\n%s\n' "$hits"
        found=1
    fi
    # 5. THE CLASS on the version axis, not just the rule instance. (3) guards
    #    what a reader is told to ALLOWLIST; this guards what a reader is told to
    #    RUN. The recipe this section used to open with was
    #    `ls -d ~/.claude/plugins/cache/*/<plugin>/*/lib/lens.sh`, and a copy of
    #    it with a real version pasted in is an executable reference that goes
    #    stale on the same upgrade. Anchored on plugins/cache/ so the contrast
    #    table's `DIR="$HOME/gateway-0.1.1"` warning stays legal, and verb-
    #    anchored so warning prose does too.
    if hits="$(grep -nE '(for |ls |bash |cp |install |\[ -f )[^#]*plugins/cache/[^ ]*/[0-9]+\.[0-9]+(\.[0-9]+)?/' "$readme")"; then
        printf 'LINT: executable reference to a version-pinned install path:\n%s\n' "$hits"
        found=1
    fi
    if [ "$found" -eq 1 ]; then return 0; fi
    return 1
}

@test "R15/R16: the README's allowlist rule is stable, narrow, and spelled like its invocation" {
    local readme="$BATS_TEST_DIRNAME/../../README.md"

    run allowlist_lint "$readme"
    if [ "$status" -eq 0 ]; then
        printf '%s\n' "$output" >&2
    fi
    [ "$status" -ne 0 ]

    # The rule the README actually tells people to add, and the ONE path it
    # names. Extracted rather than hardcoded: the lint above owns what the path
    # may not be, and this owns that rule and invocation agree.
    local rule path
    rule="$(grep -o 'Bash(bash [^:)]*:\*)' "$readme" | head -1)"
    [ -n "$rule" ]
    path="${rule#Bash(bash }"
    path="${path%:\*)}"
    [ -n "$path" ]

    # THE SILENT FAILURE THIS UNIT EXISTS FOR. The rule matches literal command
    # text, so a documented invocation spelled differently from the documented
    # rule is not a refusal — it is a fan-out parked on a prompt. Trailing space
    # so the rule line itself cannot satisfy this.
    grep -qF -- "bash $path " "$readme"

    # The shim the reader is told to copy has to be a file this plugin ships,
    # and executable — the README's install step uses install(1), not chmod.
    local shim="$BATS_TEST_DIRNAME/../../bin/spawn-lens"
    [ -f "$shim" ]
    [ -x "$shim" ]
    grep -qF 'bin/spawn-lens' "$readme"

    # And it must still tell a foreign consumer to derive the installed path from
    # its own box rather than copying one, since the version is a real path
    # component. Plugin name from plugin.json, never hardcoded: a hardcoded name
    # survives the next rename as a stale check (the gateway -> spawn rename left
    # exactly this assertion asserting the old name). -F because the pattern
    # contains literal asterisks.
    local pn
    pn="$(jq -r '.name // empty' "$BATS_TEST_DIRNAME/../../.claude-plugin/plugin.json")"
    [ -n "$pn" ]
    grep -qF "plugins/cache/*/$pn/*/lib/lens.sh" "$readme"
}

@test "R16 lint self-test: a reintroduced version-pinned, wildcarded-cache or marketplaces rule each turns the lint red" {
    # Baseline clean, plant one violation, assert red — the shape launch.bats'
    # config_write_lint self-test uses. A detector never seen firing is vacuous
    # green, and this particular detector guards the one failure in the plugin
    # that presents as a hang rather than an error.
    local readme="$BATS_TEST_DIRNAME/../../README.md"
    cp "$readme" "$WORK/readme-base.md"
    run allowlist_lint "$WORK/readme-base.md"
    [ "$status" -ne 0 ]

    local plant
    for plant in \
        '"Bash(bash ~/.claude/plugins/cache/shrimpshack/spawn/9.9.9/lib/lens.sh:*)"' \
        '"Bash(bash ~/.claude/plugins/cache/*/spawn/*/lib/lens.sh:*)"' \
        '"Bash(bash ~/.claude/plugins/marketplaces/shrimpshack/plugins/spawn/lib/lens.sh:*)"' \
        'for f in ~/.claude/plugins/marketplaces/*/plugins/spawn/lib/lens.sh; do :; done' \
        'ls -d ~/.claude/plugins/cache/shrimpshack/spawn/0.2.0/lib/lens.sh' ; do
        cp "$readme" "$WORK/readme-plant.md"
        printf '%s\n' "$plant" >> "$WORK/readme-plant.md"
        run allowlist_lint "$WORK/readme-plant.md"
        if [ "$status" -ne 0 ]; then
            printf 'allowlist_lint stayed green on plant: %s\n' "$plant" >&2
        fi
        [ "$status" -eq 0 ]
    done
}

@test "R16: the shim resolves the lens by version-free path, and refuses distinctly when nothing is installed" {
    # Coverage for bin/spawn-lens lives HERE, not in the lib/*.sh computed-scope
    # lints (escapes.bats' terminal-sink lint and launch.bats' config-write
    # lint), which glob lib/*.sh and cannot reach this directory. Those files
    # belong to other units in this change set; duplicating their scope was the
    # wrong trade against editing them.
    local shim="$BATS_TEST_DIRNAME/../../bin/spawn-lens"

    # No spend logic (R7) and nothing that writes the gateway config (R12),
    # asserted on the source with comments stripped.
    run bash -c "sed 's/#.*//' '$shim' | grep -inE 'spend|budget|cost|quota|dollar|usd|price'"
    [ "$status" -ne 0 ]
    run bash -c "sed 's/#.*//' '$shim' | grep -nE '(^|[^-A-Za-z0-9_])(cp|mv|tee|dd|truncate|sponge|install)[[:space:]]'"
    [ "$status" -ne 0 ]
    run bash -c "sed 's/#.*//' '$shim' | grep -nE '>[[:space:]]*[\"'\''\$/~A-Za-z]'"
    [ "$status" -ne 0 ]

    # Nothing installed: HOME points at an empty tree and the sibling lib/ is
    # absent, so resolution has nowhere to look. One JSON object, exit 3 — the
    # code the README's foreign-consumer recipe already uses for this condition —
    # and never a fall-through that could reach a prompt.
    mkdir -p "$WORK/emptyhome" "$WORK/lonely"
    cp "$shim" "$WORK/lonely/spawn-lens"
    run env HOME="$WORK/emptyhome" bash "$WORK/lonely/spawn-lens" --alias alpha
    [ "$status" -eq 3 ]
    [ "$(printf '%s' "$output" | jq -s 'length')" = "1" ]
    [ "$(printf '%s' "$output" | jq -r '.ok')" = "false" ]
    [ "$(printf '%s' "$output" | jq -r '.exit_code')" = "3" ]
    [ "$(printf '%s' "$output" | jq -r '.error')" = "not_installed" ]
    # R12: the error names its remedy, in the remedy field like every other
    # failure — not folded into the detail prose.
    [ -n "$(printf '%s' "$output" | jq -r '.detail')" ]
    [ "$(printf '%s' "$output" | jq -r '.remedy')" != "null" ]
    [ -n "$(printf '%s' "$output" | jq -r '.remedy')" ]
    # R23: this is the one response the shim writes itself — it cannot source
    # common.sh, because it is reached precisely when no lib/ was found. The
    # envelope is hand-inlined instead, and a consumer that branches on .schema
    # or .content_trust for every response must not hit a hole here.
    [ "$(printf '%s' "$output" | jq -r '.schema')" = "spawn.response/v1" ]
    [ "$(printf '%s' "$output" | jq -r '.content_trust')" = "plugin-authored" ]
    [ -n "$(printf '%s' "$output" | jq -r '.content_notice')" ]
    [ "$(printf '%s' "$output" | jq -r '.help_requested')" = "false" ]

    # Installed shape, stubbed: cache/<mkt>/<plugin>/<version>/lib/lens.sh. The
    # shim must find it with no version in its own configuration, hand over argv
    # as given, and leave stdin alone (KTD8 — the prompt never travels in argv).
    local pn stub
    pn="$(jq -r '.name // empty' "$BATS_TEST_DIRNAME/../../.claude-plugin/plugin.json")"
    stub="$WORK/emptyhome/.claude/plugins/cache/mkt/$pn/0.9.9/lib"
    mkdir -p "$stub"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'printf "argv:%%s\\n" "$*"\n'
        printf 'printf "stdin:%%s\\n" "$(cat)"\n'
    } > "$stub/lens.sh"
    run env HOME="$WORK/emptyhome" bash -c \
        "printf '%s' 'a prompt with \"quotes\" and --dashes' | bash '$WORK/lonely/spawn-lens' --alias alpha --max-tokens 16"
    [ "$status" -eq 0 ]
    [[ "$output" == *'argv:--alias alpha --max-tokens 16'* ]]
    [[ "$output" == *'stdin:a prompt with "quotes" and --dashes'* ]]

    # A NEWER install wins, which is the whole point: the resolution carries no
    # version, so an upgrade needs no change to the rule or to the shim.
    local newer="$WORK/emptyhome/.claude/plugins/cache/mkt/$pn/0.10.0/lib"
    mkdir -p "$newer"
    printf '#!/usr/bin/env bash\nprintf "newer\\n"\n' > "$newer/lens.sh"
    run env HOME="$WORK/emptyhome" bash "$WORK/lonely/spawn-lens" --alias alpha
    [ "$status" -eq 0 ]
    [ "$output" = "newer" ]
}

@test "R7: the lens source contains no spend logic at all" {
    # A grep over the source with comments stripped. R7 is a NEGATIVE
    # requirement, so the only way to hold it is to assert the absence.
    run bash -c "sed 's/#.*//' '$LENS' | grep -inE 'spend|budget|cost|quota|dollar|usd|price'"
    [ "$status" -ne 0 ]
}

# --- R27: the token fallback reaches THIS surface, not just spawnctl ---------
#
# R27 added env-then-Keychain resolution to spawnctl's probe and left lens.sh
# reading the config alone. Once setup retired the config token, `spawnctl
# status` authenticated and a real lens call 401'd — the exact split lens.sh's
# own comment calls undebuggable from the outside. These pin the chain here.

# seed_keychain <value> — fed the way secrets.sh feeds it: twice, on stdin, to
# a trailing bare -w.
seed_keychain() {
    printf '%s\n%s\n' "$1" "$1" \
        | "$SPAWN_SECURITY_BIN" add-generic-password \
            -a "$SPAWN_KEYCHAIN_ACCOUNT_TOKEN" -s "$SPAWN_KEYCHAIN_SERVICE" -U -w
}

@test "R27: a config whose token was retired still authenticates, from the Keychain" {
    start_fixture healthy "alpha" --response-text "keychain answer"
    # Exactly the state `setup` leaves behind after it retires the config token.
    make_config "$WORK/gateway.yaml" "" "alpha=up/alpha"
    export SPAWN_CONFIG="$WORK/gateway.yaml"
    seed_keychain "$TOKEN"

    lens "ping" --alias alpha
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.text')" = "keychain answer" ]
    [ "$(echo "$output" | jq -r '.error')" = "null" ]
}

@test "R27: GATEWAY_TOKEN outranks the Keychain, matching spawnctl's order" {
    start_fixture healthy "alpha" --response-text "env answer"
    make_config "$WORK/gateway.yaml" "" "alpha=up/alpha"
    export SPAWN_CONFIG="$WORK/gateway.yaml"
    # A WRONG value in the Keychain: if the order were reversed this 401s, so
    # the assertion is load-bearing rather than passing on either branch.
    seed_keychain "tok-wrong-should-not-be-used"
    export GATEWAY_TOKEN="$TOKEN"

    lens "ping" --alias alpha
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.text')" = "env answer" ]
}

@test "R27: the config token still wins over both, so a normal install is unchanged" {
    start_fixture healthy "alpha" --response-text "config answer"
    make_config "$WORK/gateway.yaml" "$TOKEN" "alpha=up/alpha"
    export SPAWN_CONFIG="$WORK/gateway.yaml"
    seed_keychain "tok-wrong-should-not-be-used"

    lens "ping" --alias alpha
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.text')" = "config answer" ]
}

@test "R27: no token anywhere is still a truthful 401, not an invented failure" {
    start_fixture healthy "alpha"
    make_config "$WORK/gateway.yaml" "" "alpha=up/alpha"
    export SPAWN_CONFIG="$WORK/gateway.yaml"
    # Keychain deliberately empty.

    lens "ping" --alias alpha
    [ "$status" -eq 7 ]
    [ "$(echo "$output" | jq -r '.error')" = "auth_rejected" ]
}
