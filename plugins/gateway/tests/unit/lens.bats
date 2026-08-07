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
    CTL="$LIB/gatewayctl.sh"
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/gw-lens.XXXXXX")"
    WORK="$(cd "$WORK" && pwd -P)"
    TOKEN="tok-lens-s3cr3t-9f2a"
    GW_PID=""
    SPILLS=()
    REAL_CURL="$(command -v curl)"

    # State and search root are redirected into $WORK so no test can touch
    # ~/.gateway.pid / .log / .lock or discover the real ~/gateway-* install.
    export GATEWAY_STATE_HOME="$WORK"
    export GATEWAY_SEARCH_ROOT="$WORK/searchroot"
    mkdir -p "$GATEWAY_SEARCH_ROOT"
    # Own TMPDIR per test. Scratch dirs and spill files are named by pattern,
    # so a leftover from an unrelated (or killed) run in a shared /tmp would
    # otherwise be indistinguishable from one this test just leaked.
    export TMPDIR="$WORK/tmp"
    mkdir -p "$TMPDIR"
    export GATEWAY_CONNECT_TIMEOUT=2
    export GATEWAY_PROBE_TIMEOUT=5
    export GATEWAY_START_TIMEOUT=10
    export GATEWAY_LOCK_TIMEOUT=30
    unset GATEWAY_INSTALL_DIR GATEWAY_CONFIG GATEWAY_MODELS_JSON
    unset GATEWAY_LENS_TIMEOUT GATEWAY_SPILL_BYTES GATEWAY_LENS_MAX_TOKENS
    # Default at a port nothing serves: a test that forgets to point somewhere
    # must not probe the REAL gateway on 4000.
    export GATEWAY_BASE_URL="http://127.0.0.1:1/anthropic"
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
# these tests never start a gateway, they point GATEWAY_BASE_URL at the fixture.
make_config() {
    local path="$1" token="$2"; shift 2
    {
        printf 'server:\n'
        printf '  bind: "127.0.0.1:4000"\n'
        printf '  token: %s        # Bearer or x-api-key\n' "$token"
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
    export GATEWAY_BASE_URL="http://127.0.0.1:$PORT/anthropic"

    local a
    local -a specs=() parts=()
    IFS=',' read -ra parts <<< "$aliases"
    for a in "${parts[@]}"; do specs+=("$a=up/$a"); done
    make_config "$WORK/gateway.yaml" "$TOKEN" "${specs[@]}"
    export GATEWAY_CONFIG="$WORK/gateway.yaml"
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

@test "config resolution: with GATEWAY_CONFIG unset the path comes out of ensure, and the call still succeeds" {
    # Every other test in this file exports GATEWAY_CONFIG, which short-circuits
    # lens.sh's config resolution entirely — so the branch that actually runs in
    # production (read `.config` out of ensure's JSON) was never exercised. It
    # was verified that replacing ensure's `config` field with null left the
    # whole suite green while breaking the lens at runtime: no config, no token,
    # 401, exit 7.
    start_fixture healthy "alpha" --response-text "resolved through ensure"

    # start_fixture exports GATEWAY_CONFIG. Production does not have it set.
    unset GATEWAY_CONFIG
    [ -z "${GATEWAY_CONFIG:-}" ]

    # A resolvable install: gateway.yaml beside a REGULAR, EXECUTABLE binary at
    # the canonical path. resolve_install_dir hard-fails a set-but-invalid
    # override even in soft mode, so the binary has to exist — it is never
    # executed here, because the fixture is already up and no start is attempted.
    mkdir -p "$WORK/install/target/release"
    printf '#!/bin/sh\nexit 1\n' > "$WORK/install/target/release/gateway"
    chmod +x "$WORK/install/target/release/gateway"
    make_config "$WORK/install/gateway.yaml" "$TOKEN" "alpha=up/alpha"
    export GATEWAY_INSTALL_DIR="$WORK/install"

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
    export GATEWAY_BASE_URL="http://127.0.0.1:1/anthropic"
    lens "hi"
    [ "$status" -eq 2 ]
    [ "$(echo "$output" | jq -r '.ok')" = "false" ]
}

@test "KTD5: an alias with a control byte is refused with code 2 before any network call" {
    # BASE_URL points at nothing, so a probe would return 3. Getting 2 proves
    # the grammar check ran FIRST.
    export GATEWAY_BASE_URL="http://127.0.0.1:1/anthropic"
    lens "hi" --alias "$(printf 'al\033[31mpha')"
    [ "$status" -eq 2 ]
    lens "hi" --alias 'alpha;rm -rf /'
    [ "$status" -eq 2 ]
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
    export GATEWAY_BASE_URL="http://127.0.0.1:1/anthropic"
    lens "hi" --alias kimi --timeout 0
    [ "$status" -eq 2 ]
    [ "$(echo "$output" | jq -s 'length')" = "1" ]
    [ "$(echo "$output" | jq -r '.error')" = "usage" ]

    # A fractional zero is the same hole spelled differently.
    lens "hi" --alias kimi --timeout 0.0
    [ "$status" -eq 2 ]

    # And the previously unvalidated connect timeout.
    export GATEWAY_CONNECT_TIMEOUT=0
    lens "hi" --alias kimi
    [ "$status" -eq 2 ]
    [ "$(echo "$output" | jq -r '.error')" = "usage" ]
    unset GATEWAY_CONNECT_TIMEOUT
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

@test "R3: a preflight auth failure reaches the consumer as the lens's own enum, not gatewayctl prose" {
    # Exit 7 out of the PREFLIGHT (ensure's probe is rejected before the lens
    # ever reaches the messages endpoint). ensure's object is {verb, error:
    # <prose>} — forwarding it verbatim put English where the enum belongs and
    # dropped text/usage, breaking `.error` branching exactly when every caller
    # in a fan-out fails at once.
    start_fixture healthy "alpha"
    make_config "$WORK/bad.yaml" "wrong-token" "alpha=up/alpha"
    export GATEWAY_CONFIG="$WORK/bad.yaml"

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
    # Search root is empty and GATEWAY_INSTALL_DIR is unset, so no start is
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
    export GATEWAY_CONFIG="$WORK/bad.yaml"
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
    export GATEWAY_CONFIG="$WORK/bad.yaml"
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

    export GATEWAY_SPILL_BYTES=1
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

@test "R7: the lens source contains no spend logic at all" {
    # A grep over the source with comments stripped. R7 is a NEGATIVE
    # requirement, so the only way to hold it is to assert the absence.
    run bash -c "sed 's/#.*//' '$LENS' | grep -inE 'spend|budget|cost|quota|dollar|usd|price'"
    [ "$status" -ne 0 ]
}
