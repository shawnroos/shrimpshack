#!/usr/bin/env bats
# U4 — interactive launch and resume handle.
#
# The gateway side runs against tests/fixtures/fake-gateway.py and the `claude`
# side against tests/fixtures/fake-claude.sh on PATH. Neither the real gateway
# on port 4000 nor the real CLI is ever in the path: one would fight a live
# process, the other would spend real money and open a real session, and both
# turn green into noise.
#
# Failure classes are asserted on EXIT CODES, not messages (plan, Verification
# Contract): a caller branches on the number, so the number is what is pinned.

setup() {
    FIX="$(cd "$BATS_TEST_DIRNAME/../fixtures" && pwd)"
    LIB="$(cd "$BATS_TEST_DIRNAME/../../lib" && pwd)"
    LAUNCH="$LIB/launch.sh"
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/gw-launch.XXXXXX")"
    # PHYSICAL path. On macOS /tmp is a symlink to /private/tmp, and the whole
    # unit turns on an encoded cwd matching what the child recorded as $PWD — a
    # logical path here would encode differently and fail for a reason that has
    # nothing to do with the code.
    WORK="$(cd "$WORK" && pwd -P)"
    TOKEN="tok-launch-s3cr3t-7b1e"
    GW_PID=""

    export SPAWN_STATE_HOME="$WORK"
    export SPAWN_SEARCH_ROOT="$WORK/searchroot"
    mkdir -p "$SPAWN_SEARCH_ROOT"
    export TMPDIR="$WORK/tmp"
    mkdir -p "$TMPDIR"
    # launch.sh now sources secrets.sh for the env/Keychain token fallback, and
    # the attach command it prints embeds the same chain. Both have to run
    # against the fixture `security`, or a tokenless-config test would query the
    # REAL login Keychain of whoever runs the suite.
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
    unset SPAWN_INSTALL_DIR SPAWN_CONFIG SPAWN_MODELS_JSON SPAWN_CLAUDE_BIN SPAWN_LAUNCH_TIMEOUT
    # Default at a port nothing serves: a test that forgets to point somewhere
    # must not probe the REAL gateway on 4000.
    export SPAWN_BASE_URL="http://127.0.0.1:1/anthropic"

    # Claude Code's own knob. launch.sh derives the transcript root from it and
    # fake-claude.sh writes under it, so both sides agree without either one
    # being told the answer.
    export CLAUDE_CONFIG_DIR="$WORK/claude-home"
    mkdir -p "$CLAUDE_CONFIG_DIR"
    export FAKE_CLAUDE_RECORD_DIR="$WORK/rec"
    mkdir -p "$FAKE_CLAUDE_RECORD_DIR"
    unset FAKE_CLAUDE_MODE FAKE_CLAUDE_SESSION_ID FAKE_CLAUDE_PROJECTS_ROOT

    # `claude` on PATH is the fixture. The attach command invokes a bare
    # `claude`, so the same shim serves the second invocation too.
    mkdir -p "$WORK/bin"
    ln -sf "$FIX/fake-claude.sh" "$WORK/bin/claude"
    export PATH="$WORK/bin:$PATH"

    # The launch directory and a DIFFERENT directory to attach from (AE3).
    PROJ="$WORK/proj"; mkdir -p "$PROJ"; PROJ="$(cd "$PROJ" && pwd -P)"
    ELSEWHERE="$WORK/elsewhere"; mkdir -p "$ELSEWHERE"

    CFG_SHA=""
}

teardown() {
    if [ -n "${GW_PID:-}" ]; then
        kill "$GW_PID" 2>/dev/null || true
        wait "$GW_PID" 2>/dev/null || true
    fi
    for p in $(pgrep -f "$WORK" 2>/dev/null); do
        [ "$p" = "$$" ] && continue
        kill -9 "$p" 2>/dev/null
    done
    rm -rf "$WORK"
}

# --- helpers ---------------------------------------------------------------

# NEGATIVE ASSERTIONS. bats runs under `set -e`, but POSIX exempts a pipeline
# beginning with `!` from it — so `! grep -q "$TOKEN" file` NEVER fails a test,
# it just evaluates and moves on. In this repo that shape already let a
# token-leak assertion pass against code that genuinely leaked. These helpers
# fail as PLAIN commands, which set -e does honour.
refute_file_match() {   # <pattern> <file...>
    local pat="$1"; shift
    if grep -qF -- "$pat" "$@"; then
        printf 'refute_file_match: unexpected match for %s in %s\n' "$pat" "$*" >&2
        grep -nF -- "$pat" "$@" >&2
        return 1
    fi
    return 0
}
refute_stdin_match() {  # <pattern>, reads stdin; use as the LAST pipeline stage
    local pat="$1" buf
    buf="$(cat)"
    if printf '%s' "$buf" | grep -qF -- "$pat"; then
        printf 'refute_stdin_match: unexpected match for %s in:\n%s\n' "$pat" "$buf" >&2
        return 1
    fi
    return 0
}

make_config() {
    local path="$1" token="$2"; shift 2
    {
        printf 'server:\n'
        printf '  bind: "127.0.0.1:4000"\n'
        # An EMPTY token omits the line entirely: that is what `setup` leaves
        # behind when it retires the config token — it removes the key rather
        # than blanking it, and a blanked key with its comment still attached
        # parses as the literal comment text, not as absent.
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
    # R12 / U4 verification: gateway.yaml is byte-identical before and after.
    CFG_SHA="$(shasum "$WORK/gateway.yaml" | awk '{print $1}')"
}

assert_config_untouched() {
    [ -n "$CFG_SHA" ]
    [ "$(shasum "$WORK/gateway.yaml" | awk '{print $1}')" = "$CFG_SHA" ]
}

# A models.json holding only the aliases named, so drift is a property of the
# table this test controls rather than of the shipped one.
make_table() {  # <alias:window> ...
    local spec
    local body=""
    for spec in "$@"; do
        [ -n "$body" ] && body+=","
        body+="$(jq -nc --arg a "${spec%%:*}" --argjson w "${spec#*:}" \
            '{key:$a, value:{context_window:$w, source:"test", model:("up/"+$a), chain:false}}')"
    done
    jq -n --argjson e "[$body]" '{version:1, aliases: ($e | from_entries)}' > "$WORK/models.json"
    export SPAWN_MODELS_JSON="$WORK/models.json"
}

# Run launch capturing STDOUT ONLY, seed prompt on stdin, cwd pinned to $PROJ.
launch() {
    run bash -c 'cd "$3" && printf "%s" "$1" | bash "$2" --cwd "$3" "${@:4}" 2>/dev/null' \
        _ "seed me" "$LAUNCH" "$PROJ" "$@"
}

# Split the fixture's append-only records into per-invocation chunks.
# $1 = record file, $2 = 1-based invocation number.
invocation() {
    awk -v want="$2" '/^--- invocation /{n++; next} n==want' "$1"
}

# R12 no-write lint (R7): prints every line that could WRITE the gateway config
# and returns grep's status (0 = found = violation). The original matched
# redirection syntax only, so cp/tee/sed -i/yq -i against \$CONFIG_PATH all
# passed. Comments are stripped first. Reads stay legal — awk/cat/grep with the
# config as an argument are how the token is resolved — so only write-capable
# commands co-occurring with the config variable are flagged. Over-flagging a
# hypothetical read-only `cp "\$CONFIG_PATH" elsewhere` is accepted: the
# baseline-clean assertion keeps the lint honest against the shipped source.
#
# SCOPE (KTD3): the RUNTIME scripts — launch.sh, lens.sh, spawnctl.sh. It is no
# longer stated as repo-wide, because lib/setup.sh is now the SANCTIONED writer
# of gateway.yaml: the gateway pushes GATEWAY_TOKEN onto its auth list rather
# than substituting it, so the literal token in a live config stays valid until
# it is deleted from the file, and R23 is unreachable without a config edit.
# setup.sh is exempted BY NAME, here and in the self-test below, never by
# accident — and note that the exemption is a statement of sanction rather than
# a mechanical bypass: this lint keys on $CONFIG_PATH/$SPAWN_CONFIG, and
# setup.sh writes through "$staging/$CONFIG_NAME", which those patterns cannot
# match anyway. Widening the patterns to cover setup.sh's own variables would
# be re-litigating KTD3, not fixing a gap.
config_write_lint() {   # <script>
    sed 's/#.*//' "$1" | grep -nE \
        -e '>[ ]*"?\$\{?(CONFIG_PATH|SPAWN_CONFIG)' \
        -e '(^|[^A-Za-z0-9_])(cp|mv|tee|dd|install|truncate|sponge)[^|;&]*\$\{?(CONFIG_PATH|SPAWN_CONFIG)' \
        -e '(^|[^A-Za-z0-9_])(sed|perl|yq|gawk)[^|;&]*[ ]-i[^|;&]*\$\{?(CONFIG_PATH|SPAWN_CONFIG)' \
        -e '(^|[^A-Za-z0-9_])(sed|perl|yq|gawk)[^|;&]*\$\{?(CONFIG_PATH|SPAWN_CONFIG)[^|;&]*[ ]-i'
}

# --- happy path ------------------------------------------------------------

@test "happy path: exit 0, one JSON handle, and the session id matches the transcript on disk" {
    start_fixture healthy "alpha"
    make_table "alpha:262144"

    launch --alias alpha
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -s 'length')" = "1" ]
    [ "$(echo "$output" | jq -r '.ok')" = "true" ]
    [ "$(echo "$output" | jq -r '.alias')" = "alpha" ]
    [ "$(echo "$output" | jq -r '.error')" = "null" ]

    local sid tr
    sid="$(echo "$output" | jq -r '.session_id')"
    tr="$(echo "$output" | jq -r '.transcript_path')"
    [ -n "$sid" ] && [ "$sid" != "null" ]
    # The promise is not "a path" but "the file the run actually wrote".
    [ -f "$tr" ]
    [ "$(basename "$tr")" = "$sid.jsonl" ]
    [ "$(jq -r -s '.[0].sessionId' < "$tr")" = "$sid" ]

    # Every field the handle promises is present and consistent.
    [ "$(echo "$output" | jq -r '.cwd')" = "$PROJ" ]
    [ "$(echo "$output" | jq -r '.base_url')" = "$SPAWN_BASE_URL" ]
    [ "$(echo "$output" | jq -r '.context_window')" = "262144" ]
    [ "$(echo "$output" | jq -r '.exit_code')" = "0" ]

    assert_config_untouched
}

@test "the transcript path is derived from the PINNED cwd, not from where launch ran" {
    start_fixture healthy "alpha"
    make_table "alpha:262144"

    # Run from a third directory entirely; --cwd still decides.
    run bash -c 'cd "$4" && printf hi | bash "$2" --cwd "$3" --alias alpha 2>/dev/null' \
        _ x "$LAUNCH" "$PROJ" "$ELSEWHERE"
    [ "$status" -eq 0 ]

    local encoded expected
    encoded="$(printf '%s' "$PROJ" | sed 's/[^A-Za-z0-9]/-/g')"
    expected="$CLAUDE_CONFIG_DIR/projects/$encoded/$(echo "$output" | jq -r '.session_id').jsonl"
    [ "$(echo "$output" | jq -r '.transcript_path')" = "$expected" ]
    [ "$(echo "$output" | jq -r '.cwd')" = "$PROJ" ]
    # And the child really ran there.
    [ "$(head -1 "$FAKE_CLAUDE_RECORD_DIR/cwd")" = "$PROJ" ]
}

@test "config resolution: with SPAWN_CONFIG unset the path comes out of ensure, and the resolved token reaches the child" {
    # Every other test in this file exports SPAWN_CONFIG, which short-circuits
    # launch.sh's config resolution entirely — so the branch that actually runs
    # in production (read `.config` out of ensure's JSON) was never exercised.
    start_fixture healthy "alpha"
    make_table "alpha:262144"

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

    # PRECONDITION: ensure really emits the install dir's config path.
    run bash -c 'bash "$1" ensure alpha 2>/dev/null' _ "$LIB/spawnctl.sh"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.config')" = "$WORK/install/gateway.yaml" ]

    launch --alias alpha
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.ok')" = "true" ]

    # THE load-bearing assertion. launch.sh treats an EMPTY token as non-fatal
    # (ensure already proved the gateway accepts us), so exit 0 on its own stays
    # green with no config resolved at all. What proves resolution happened is
    # that the child was handed the token that only gateway.yaml holds.
    [ -n "$TOKEN" ]
    grep -qx -- "ANTHROPIC_AUTH_TOKEN=$TOKEN" "$FAKE_CLAUDE_RECORD_DIR/env"
    grep -qx -- "ANTHROPIC_API_KEY=$TOKEN" "$FAKE_CLAUDE_RECORD_DIR/env"

    # And the handle reads the token back from the SAME resolved path, so a
    # later attach does not depend on SPAWN_CONFIG either.
    echo "$output" | jq -r '.attach_command' | grep -qF -- "$WORK/install/gateway.yaml"
    echo "$output" | jq -r '.attach_command' | refute_stdin_match "$TOKEN"
}

# --- AE3 -------------------------------------------------------------------

@test "AE3: the printed attach command, run from a different directory, resumes on the same alias and endpoint" {
    start_fixture healthy "alpha,beta"
    make_table "alpha:262144" "beta:1048576"

    launch --alias beta
    [ "$status" -eq 0 ]
    # Captured BEFORE the attach run: `run` overwrites $output, and reading the
    # handle back out of it afterwards would parse the attach run's output.
    local attach sid tr
    attach="$(echo "$output" | jq -r '.attach_command')"
    sid="$(echo "$output" | jq -r '.session_id')"
    tr="$(echo "$output" | jq -r '.transcript_path')"
    [ -n "$attach" ] && [ "$attach" != "null" ]

    # The handle itself carries the endpoint, the alias and a resume reference,
    # and NOT the token literal (R9 + KTD6).
    echo "$attach" | grep -qF -- "$SPAWN_BASE_URL"
    echo "$attach" | grep -qF -- "--model 'beta'"
    echo "$attach" | grep -qF -- "--resume '$sid'"
    echo "$attach" | refute_stdin_match "$TOKEN"

    # Execute it from ELSEWHERE. This is AE3's real demand: the handle has to
    # work from anywhere, which is only true if it pins the cwd itself.
    run bash -c 'cd "$1" && eval "$2"' _ "$ELSEWHERE" "$attach"
    [ "$status" -eq 0 ]

    # Invocation 2 is the attach. The child saw:
    local argv2 env2
    argv2="$(invocation "$FAKE_CLAUDE_RECORD_DIR/argv" 2)"
    env2="$(invocation "$FAKE_CLAUDE_RECORD_DIR/env" 2)"
    [ -n "$argv2" ]
    #   ...the same alias and the session to resume,
    printf '%s\n' "$argv2" | grep -qx -- "--model"
    printf '%s\n' "$argv2" | grep -qx -- "beta"
    printf '%s\n' "$argv2" | grep -qx -- "--resume"
    printf '%s\n' "$argv2" | grep -qx -- "$sid"
    #   ...the gateway base URL,
    printf '%s\n' "$env2" | grep -qx -- "ANTHROPIC_BASE_URL=$SPAWN_BASE_URL"
    #   ...the RESOLVED token (by reference, so it had to read the config),
    printf '%s\n' "$env2" | grep -qx -- "ANTHROPIC_AUTH_TOKEN=$TOKEN"
    #   ...and the pinned cwd.
    [ "$(sed -n '2p' "$FAKE_CLAUDE_RECORD_DIR/cwd")" = "$PROJ" ]

    # The session resolved: the resumed run appended to the SAME transcript
    # (two lines per invocation, so four after the launch plus the attach).
    [ "$(wc -l < "$tr" | tr -d ' ')" -eq 4 ]
    [ "$(jq -r -s '[.[].sessionId] | unique | join(",")' < "$tr")" = "$sid" ]

    assert_config_untouched
}

@test "AE3: a token written as \${VAR} in the config still resolves at attach time" {
    start_fixture healthy "alpha"
    make_table "alpha:262144"
    # The gateway expands env references in server.token; a handle that handed
    # `claude` the literal "${GW_ENV_TOKEN}" would 401 on attach.
    make_config "$WORK/gateway.yaml" '${GW_ENV_TOKEN}' "alpha=up/alpha"
    CFG_SHA="$(shasum "$WORK/gateway.yaml" | awk '{print $1}')"
    export GW_ENV_TOKEN="$TOKEN"

    launch --alias alpha
    [ "$status" -eq 0 ]
    local attach; attach="$(echo "$output" | jq -r '.attach_command')"
    echo "$attach" | refute_stdin_match "$TOKEN"

    run bash -c 'cd "$1" && eval "$2"' _ "$ELSEWHERE" "$attach"
    [ "$status" -eq 0 ]
    invocation "$FAKE_CLAUDE_RECORD_DIR/env" 2 | grep -qx -- "ANTHROPIC_AUTH_TOKEN=$TOKEN"
    assert_config_untouched
}

# --- token discipline (KTD6) -----------------------------------------------

@test "KTD6: the token reaches the child through the environment and appears in NO argv, stdout or stderr" {
    start_fixture healthy "alpha"
    make_table "alpha:262144"

    run bash -c 'cd "$3" && printf hi | bash "$2" --cwd "$3" --alias alpha >"$4/out" 2>"$4/err"' \
        _ x "$LAUNCH" "$PROJ" "$WORK"
    [ "$status" -eq 0 ]

    # FIRST: the thing under test is in play. A token that resolved EMPTY would
    # make every "absent" assertion below pass against code that leaks — that
    # exact false green has already happened in this plugin's tests.
    [ -n "$TOKEN" ]
    grep -qx -- "ANTHROPIC_AUTH_TOKEN=$TOKEN" "$FAKE_CLAUDE_RECORD_DIR/env"
    grep -qx -- "ANTHROPIC_API_KEY=$TOKEN" "$FAKE_CLAUDE_RECORD_DIR/env"
    grep -qx -- "ANTHROPIC_BASE_URL=$SPAWN_BASE_URL" "$FAKE_CLAUDE_RECORD_DIR/env"

    # THEN: it is nowhere it must not be.
    refute_file_match "$TOKEN" "$FAKE_CLAUDE_RECORD_DIR/argv"
    refute_file_match "$TOKEN" "$WORK/out"
    refute_file_match "$TOKEN" "$WORK/err"
    # Including inside the handle we just printed.
    jq -r '.attach_command' < "$WORK/out" | refute_stdin_match "$TOKEN"
}

@test "KTD6: the token stays out of stdout and stderr on failure paths too" {
    start_fixture healthy "alpha"
    make_table "alpha:262144"
    export FAKE_CLAUDE_MODE=fail

    run bash -c 'cd "$3" && printf hi | bash "$2" --cwd "$3" --alias alpha >"$4/out" 2>"$4/err"' \
        _ x "$LAUNCH" "$PROJ" "$WORK"
    [ "$status" -ne 0 ]
    refute_file_match "$TOKEN" "$WORK/out"
    refute_file_match "$TOKEN" "$WORK/err"
}

# --- context window (KTD7 / R10) -------------------------------------------

@test "KTD7: a table-listed alias passes its window to the child" {
    start_fixture healthy "alpha"
    make_table "alpha:262144"

    launch --alias alpha
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.context_window')" = "262144" ]
    grep -qx -- "CLAUDE_CODE_MAX_CONTEXT_TOKENS=262144" "$FAKE_CLAUDE_RECORD_DIR/env"
    # And the attach command carries it forward, so the resumed session does not
    # silently revert to the default window.
    echo "$output" | jq -r '.attach_command' | grep -qF -- "CLAUDE_CODE_MAX_CONTEXT_TOKENS='262144'"
}

@test "KTD7 drift: an alias the gateway serves but the table does not still launches, with a warning naming it" {
    start_fixture healthy "alpha,orphan"
    make_table "alpha:262144"

    # stdout only — the launch must succeed.
    launch --alias orphan
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.context_window')" = "null" ]

    # stderr only — the drift is named, and the alias is named in it.
    run bash -c 'cd "$3" && printf hi | bash "$2" --cwd "$3" --alias orphan 2>&1 1>/dev/null' \
        _ x "$LAUNCH" "$PROJ"
    [ "$status" -eq 0 ]
    echo "$output" | grep -qF -- "orphan"
    echo "$output" | grep -qiF -- "drift"

    # No window var was invented for an alias we have no number for.
    run grep -q "CLAUDE_CODE_MAX_CONTEXT_TOKENS" "$FAKE_CLAUDE_RECORD_DIR/env"
    [ "$status" -ne 0 ]
}

# --- failure classes (KTD2) ------------------------------------------------

@test "seed failure: non-zero exit, no handle, and the JSON says so" {
    start_fixture healthy "alpha"
    make_table "alpha:262144"
    export FAKE_CLAUDE_MODE=fail

    launch --alias alpha
    [ "$status" -ne 0 ]
    [ "$status" -eq 5 ]
    [ "$(echo "$output" | jq -s 'length')" = "1" ]
    [ "$(echo "$output" | jq -r '.ok')" = "false" ]
    # A handle to a session that does not exist is worse than a failure.
    [ "$(echo "$output" | jq -r '.session_id')" = "null" ]
    [ "$(echo "$output" | jq -r '.attach_command')" = "null" ]
    [ "$(echo "$output" | jq -r '.error')" = "seed_failed" ]
}

@test "R8: a seed run that exits 0 but reports is_error=true is code 5, seed_failed, and no handle" {
    # The CLI can exit 0 while its result object says the turn FAILED. Before
    # this branch was reachable in tests, deleting it left the suite green
    # while launch handed back handles to failed sessions.
    start_fixture healthy "alpha"
    make_table "alpha:262144"
    export FAKE_CLAUDE_MODE=error

    launch --alias alpha
    [ "$status" -eq 5 ]
    [ "$(echo "$output" | jq -s 'length')" = "1" ]
    [ "$(echo "$output" | jq -r '.error')" = "seed_failed" ]
    [ "$(echo "$output" | jq -r '.attach_command')" = "null" ]
    [ "$(echo "$output" | jq -r '.session_id')" = "null" ]
}

@test "R2: a hung seed run hits the deadline — exit 6, one object, and the child is dead and reaped" {
    start_fixture healthy "alpha"
    make_table "alpha:262144"
    export FAKE_CLAUDE_MODE=hang
    export SPAWN_LAUNCH_TIMEOUT=1

    launch --alias alpha
    [ "$status" -eq 6 ]
    [ "$(echo "$output" | jq -s 'length')" = "1" ]
    [ "$(echo "$output" | jq -r '.error')" = "deadline_exceeded" ]
    [ "$(echo "$output" | jq -r '.attach_command')" = "null" ]

    # The child was stopped, not orphaned holding the token in its environment.
    local cpid
    cpid="$(head -1 "$FAKE_CLAUDE_RECORD_DIR/pid")"
    [ -n "$cpid" ]
    run kill -0 "$cpid"
    [ "$status" -ne 0 ]
}

@test "R2: TERMing launch mid-seed kills the claude child instead of orphaning it" {
    # The finding's actual scenario: a caller-imposed timeout TERMs launch.sh
    # while the seed runs. Before the fix the child pid was never retained, so
    # `claude` was re-parented to init still holding the token in its env.
    start_fixture healthy "alpha"
    make_table "alpha:262144"
    export FAKE_CLAUDE_MODE=hang
    printf 'seed me' > "$WORK/seed.txt"

    # No pipeline wrapper: $! must be launch.sh's own bash so the TERM lands on
    # the process whose trap and cleanup are under test. All three fds are
    # redirected so the hung child cannot hold bats' output pipe open.
    bash "$LAUNCH" --cwd "$PROJ" --prompt-file "$WORK/seed.txt" --alias alpha \
        < /dev/null > "$WORK/out" 2> "$WORK/err" &
    local lpid=$!

    local i cpid=""
    for i in $(seq 1 200); do
        [ -s "$FAKE_CLAUDE_RECORD_DIR/pid" ] && break
        sleep 0.05
    done
    cpid="$(head -1 "$FAKE_CLAUDE_RECORD_DIR/pid")"
    [ -n "$cpid" ]
    kill -0 "$cpid"

    kill -TERM "$lpid"
    # BOUNDED poll for launch's exit, then reap. Not `run wait` — run captures
    # in a subshell, where $lpid is not a child and wait returns instantly.
    # And not a bare `wait` first — if the trap ever regressed, that would hang
    # the whole suite instead of failing this test.
    for i in $(seq 1 100); do
        kill -0 "$lpid" 2>/dev/null || break
        sleep 0.1
    done
    run kill -0 "$lpid"
    [ "$status" -ne 0 ]
    local rc=0
    wait "$lpid" || rc=$?
    [ "$rc" -eq 143 ]

    # The child is gone (cleanup escalates TERM → KILL and reaps)...
    run kill -0 "$cpid"
    [ "$status" -ne 0 ]
    # ...and so is the scratch dir the trap owns.
    [ -z "$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'gwlaunch.*' 2>/dev/null)" ]
}

@test "a seed run that reports a session with no transcript on disk is a failure, not a handle" {
    start_fixture healthy "alpha"
    make_table "alpha:262144"
    # The fixture writes its transcript under FAKE_CLAUDE_PROJECTS_ROOT; point
    # it somewhere launch.sh does not look, which is exactly the shape of a real
    # CLI whose session did not land where we derived.
    export FAKE_CLAUDE_PROJECTS_ROOT="$WORK/nowhere"

    launch --alias alpha
    [ "$status" -eq 5 ]
    [ "$(echo "$output" | jq -r '.error')" = "transcript_missing" ]
    [ "$(echo "$output" | jq -r '.attach_command')" = "null" ]
}

@test "gateway down and unstartable: code 3 propagates from the preflight, and claude never ran" {
    start_fixture down "alpha"
    make_table "alpha:262144"

    launch --alias alpha
    [ "$status" -eq 3 ]
    [ "$(echo "$output" | jq -s 'length')" = "1" ]
    [ "$status" -ne 4 ]
    # No seed run was attempted against a gateway that is not there.
    [ ! -f "$FAKE_CLAUDE_RECORD_DIR/argv" ]
}

@test "unknown alias: code 4 from the preflight, distinct from gateway-down" {
    start_fixture healthy "alpha,beta"
    make_table "alpha:262144"

    launch --alias gamma
    [ "$status" -eq 4 ]
    [ "$status" -ne 3 ]
    [ "$(echo "$output" | jq -s 'length')" = "1" ]
    [ "$(echo "$output" | jq -r '.error')" = "alias_unknown" ]
    [ "$(echo "$output" | jq -r '.alias')" = "gamma" ]
    # R3: launch vocabulary even on a preflight failure — the handle fields a
    # consumer branches on exist (null), and ensure's object is whole underneath.
    [ "$(echo "$output" | jq 'has("attach_command") and has("session_id") and has("detail")')" = "true" ]
    [ "$(echo "$output" | jq -r '.preflight.served_aliases|sort|join(",")')" = "alpha,beta" ]
    [ ! -f "$FAKE_CLAUDE_RECORD_DIR/argv" ]
}

@test "token rejected: code 7 propagates, never collapsed into unreachable" {
    start_fixture healthy "alpha"
    make_table "alpha:262144"
    make_config "$WORK/bad.yaml" "wrong-token" "alpha=up/alpha"
    export SPAWN_CONFIG="$WORK/bad.yaml"

    launch --alias alpha
    [ "$status" -eq 7 ]
    [ "$status" -ne 3 ]
    [ "$(echo "$output" | jq -s 'length')" = "1" ]
    # R3: the enum where the enum belongs; ensure's prose is in detail/preflight.
    [ "$(echo "$output" | jq -r '.error')" = "auth_rejected" ]
    [ "$(echo "$output" | jq -r '.attach_command')" = "null" ]
    [ "$(echo "$output" | jq -r '.preflight.verb')" = "ensure" ]
    [ ! -f "$FAKE_CLAUDE_RECORD_DIR/argv" ]
}

@test "KTD5: an alias with a control byte or a shell metacharacter is code 2 before any network call" {
    export SPAWN_BASE_URL="http://127.0.0.1:1/anthropic"
    launch --alias "$(printf 'al\033[31mpha')"
    [ "$status" -eq 2 ]
    launch --alias 'alpha;rm -rf /'
    [ "$status" -eq 2 ]
    [ ! -f "$FAKE_CLAUDE_RECORD_DIR/argv" ]
}

@test "usage: no alias, an empty prompt, and a stray argv token are each code 2 with one JSON object" {
    export SPAWN_BASE_URL="http://127.0.0.1:1/anthropic"
    local out rc
    cap() { out="$(cd "$PROJ" && printf "%s" "$1" | bash "$LAUNCH" --cwd "$PROJ" "${@:2}" 2>/dev/null)" && rc=0 || rc=$?; }

    cap "seed"                                  # no --alias
    [ "$rc" -eq 2 ]; [ "$(echo "$out" | jq -s 'length')" = "1" ]
    [ "$(echo "$out" | jq -r '.exit_code')" = "2" ]

    cap "" --alias alpha                        # empty prompt
    [ "$rc" -eq 2 ]; [ "$(echo "$out" | jq -s 'length')" = "1" ]

    cap "seed" --alias alpha "a prompt in argv"  # stray positional
    [ "$rc" -eq 2 ]; [ "$(echo "$out" | jq -s 'length')" = "1" ]

    cap "seed" --alias alpha --cwd "$WORK/no-such-dir"
    [ "$rc" -eq 2 ]; [ "$(echo "$out" | jq -s 'length')" = "1" ]
}

@test "SPAWN_LAUNCH_TIMEOUT=0 is refused with code 2, not accepted as 'no deadline'" {
    # Same class as the lens's --timeout 0 (R1): zero reads as "no artificial
    # limit" and would mean an unbounded seed run — the R2 deadline silently
    # gone. Refused before any network call, so no fixture is needed.
    export SPAWN_BASE_URL="http://127.0.0.1:1/anthropic"
    export SPAWN_LAUNCH_TIMEOUT=0
    launch --alias alpha
    [ "$status" -eq 2 ]
    [ "$(echo "$output" | jq -s 'length')" = "1" ]
    [ "$(echo "$output" | jq -r '.error')" = "usage" ]

    export SPAWN_LAUNCH_TIMEOUT="ten"
    launch --alias alpha
    [ "$status" -eq 2 ]
}

# --- R12 -------------------------------------------------------------------

@test "R12: launch.sh never writes gateway.yaml, on the happy path or a failing one" {
    start_fixture healthy "alpha"
    make_table "alpha:262144"

    launch --alias alpha
    [ "$status" -eq 0 ]
    assert_config_untouched

    export FAKE_CLAUDE_MODE=fail
    launch --alias alpha
    [ "$status" -eq 5 ]
    assert_config_untouched

    # And the source contains no write to it at all — by redirect, copy,
    # tee, or in-place edit (R7 broadened this beyond redirection syntax).
    run config_write_lint "$LAUNCH"
    if [ "$status" -eq 0 ]; then
        printf 'config_write_lint flagged:\n%s\n' "$output" >&2
    fi
    [ "$status" -ne 0 ]
    # The same holds for the other two scripts that read the config: the
    # finding cites launch.sh, but the invariant is R12's, which covers every
    # RUNTIME script (KTD3 narrowed the stated scope from repo-wide to these
    # three when setup.sh became the sanctioned writer).
    run config_write_lint "$LIB/lens.sh"
    [ "$status" -ne 0 ]
    run config_write_lint "$LIB/spawnctl.sh"
    [ "$status" -ne 0 ]
}

@test "KTD3: the no-write invariant covers the three runtime scripts, and the setup family is exempt BY NAME" {
    # The scope change is worth a test of its own, because "the lint passes" is
    # equally true of a lint that stopped being applied. Both halves are stated
    # here: the runtime list is exactly these three files, and the one file
    # outside it is named rather than discovered.
    local script
    for script in "$LAUNCH" "$LIB/lens.sh" "$LIB/spawnctl.sh"; do
        [ -f "$script" ]
        run config_write_lint "$script"
        [ "$status" -ne 0 ]
    done

    # The setup family (setup.sh and the setup-*.sh scripts it execs) exists,
    # is not in that list, and DOES write a gateway.yaml — asserting the write
    # is real is what stops this from being a vacuous exemption for files that
    # never write anything. Family-scoped rather than pinned to one filename,
    # so the next code move cannot silently point these greps at the wrong file.
    [ -f "$LIB/setup.sh" ]
    grep -q 'strip_server_token' "$LIB"/setup*.sh
    grep -q 'staging/\$CONFIG_NAME' "$LIB"/setup*.sh
}

@test "R12 lint self-test: planted cp, tee, sed -i, yq -i and redirect writes each turn the lint red" {
    # Shape follows escapes.bats' lint self-test: baseline clean, plant one
    # violation, assert red. A detector never seen firing is vacuous green.
    cp "$LAUNCH" "$WORK/launch-lint.sh"
    run config_write_lint "$WORK/launch-lint.sh"
    [ "$status" -ne 0 ]

    local plant
    for plant in \
        'cp "$WORK/evil.yaml" "$CONFIG_PATH"' \
        'printf x | tee "$CONFIG_PATH" >/dev/null' \
        'sed -i.bak "s/token:.*/token: x/" "$CONFIG_PATH"' \
        'yq -i ".server.token = \"x\"" "$CONFIG_PATH"' \
        'sed "s/a/b/" "$CONFIG_PATH" -i' \
        'printf x > "$CONFIG_PATH"' \
        'mv "$WORK/evil.yaml" "${SPAWN_CONFIG}"' ; do
        cp "$LAUNCH" "$WORK/launch-plant.sh"
        printf '%s\n' "$plant" >> "$WORK/launch-plant.sh"
        run config_write_lint "$WORK/launch-plant.sh"
        if [ "$status" -ne 0 ]; then
            printf 'lint stayed green on plant: %s\n' "$plant" >&2
        fi
        [ "$status" -eq 0 ]
    done
}

@test "KTD6: no scratch dir survives the invocation" {
    start_fixture healthy "alpha"
    make_table "alpha:262144"
    launch --alias alpha
    [ "$status" -eq 0 ]
    [ -z "$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'gwlaunch.*' 2>/dev/null)" ]
}

# --- R27: the token fallback reaches BOTH of launch's consumers --------------
#
# launch has two: the in-process TOKEN it exports into the seed run, and the
# attach command, which re-resolves at ATTACH time in the user's shell. R27
# originally covered neither — it landed in spawnctl's probe alone, so once
# setup retired the config token the probe authenticated and both of these
# 401'd. The attach one is the nastier half: a handle printed today would stop
# working hours later with nothing on screen explaining why.

seed_keychain() {
    printf '%s\n%s\n' "$1" "$1" \
        | "$SPAWN_SECURITY_BIN" add-generic-password \
            -a "$SPAWN_KEYCHAIN_ACCOUNT_TOKEN" -s "$SPAWN_KEYCHAIN_SERVICE" -U -w
}

# Rewrite the config start_fixture wrote, dropping the token, and re-pin the
# sha the R12 no-write assertions compare against.
retire_config_token() {
    local -a specs=() parts=()
    local a
    IFS=',' read -ra parts <<< "$1"
    for a in "${parts[@]}"; do specs+=("$a=up/$a"); done
    make_config "$WORK/gateway.yaml" "" "${specs[@]}"
    CFG_SHA="$(shasum "$WORK/gateway.yaml" | awk '{print $1}')"
}

@test "R27: a retired config token still launches, resolved from the Keychain" {
    start_fixture healthy "alpha"
    retire_config_token "alpha"
    seed_keychain "$TOKEN"

    launch --alias alpha
    [ "$status" -eq 0 ]
    # The seed run received the Keychain token through the environment.
    grep -qx -- "ANTHROPIC_AUTH_TOKEN=$TOKEN" "$FAKE_CLAUDE_RECORD_DIR/env"
    # And the handle still carries no literal (R9 + KTD6).
    echo "$output" | jq -r '.attach_command' | refute_stdin_match "$TOKEN"
}

@test "R27: the printed attach command re-resolves from the Keychain when EXECUTED" {
    start_fixture healthy "alpha"
    retire_config_token "alpha"
    seed_keychain "$TOKEN"

    launch --alias alpha
    [ "$status" -eq 0 ]
    local attach
    attach="$(echo "$output" | jq -r '.attach_command')"
    [ -n "$attach" ] && [ "$attach" != "null" ]
    echo "$attach" | refute_stdin_match "$TOKEN"

    # RUN it, from elsewhere. Asserting the fallback text merely APPEARS in the
    # command would pass against a snippet that cannot resolve anything — the
    # silent-pass class this branch exists to close. Only executing it proves
    # the embedded chain reaches the Keychain.
    run bash -c 'cd "$1" && eval "$2"' _ "$ELSEWHERE" "$attach"
    [ "$status" -eq 0 ]
    invocation "$FAKE_CLAUDE_RECORD_DIR/env" 2 | grep -qx -- "ANTHROPIC_AUTH_TOKEN=$TOKEN"
}

@test "R27: an attach command whose config still has its token does not consult the Keychain" {
    start_fixture healthy "alpha"
    # Config token intact; a WRONG value stored, so a wrong precedence 401s
    # rather than passing on either branch.
    seed_keychain "tok-wrong-should-not-be-used"

    launch --alias alpha
    [ "$status" -eq 0 ]
    local attach; attach="$(echo "$output" | jq -r '.attach_command')"

    run bash -c 'cd "$1" && eval "$2"' _ "$ELSEWHERE" "$attach"
    [ "$status" -eq 0 ]
    invocation "$FAKE_CLAUDE_RECORD_DIR/env" 2 | grep -qx -- "ANTHROPIC_AUTH_TOKEN=$TOKEN"
}
