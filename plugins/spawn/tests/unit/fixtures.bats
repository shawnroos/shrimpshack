#!/usr/bin/env bats
# U1 fixture tests — the fixtures are test infrastructure every later unit
# leans on, so they get asserted like production code. If fake-gateway.py
# stopped requiring auth, or stopped distinguishing a 429 from a 502, U2-U4
# would keep passing while the behaviour they claim to prove went dark.

setup() {
    FIX="$(cd "$BATS_TEST_DIRNAME/../fixtures" && pwd)"
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/gw-fixtures.XXXXXX")"
    WORK="$(cd "$WORK" && pwd -P)"
    TOKEN="tok-abc123"
    GW_PID=""
}

teardown() {
    if [ -n "${GW_PID:-}" ]; then
        kill "$GW_PID" 2>/dev/null || true
        wait "$GW_PID" 2>/dev/null || true
    fi
    rm -rf "$WORK"
}

# start_gateway <scenario> [extra args...] — sets $PORT and $GW_PID.
start_gateway() {
    local scenario="$1"; shift
    local portfile="$WORK/port.$$"
    python3 "$FIX/fake-gateway.py" \
        --token "$TOKEN" \
        --aliases "alpha,beta" \
        --scenario "$scenario" \
        --port-file "$portfile" \
        "$@" >"$WORK/gw.out" 2>"$WORK/gw.err" &
    GW_PID=$!
    local i
    for i in $(seq 1 100); do
        [ -s "$portfile" ] && break
        sleep 0.05
    done
    PORT="$(cat "$portfile")"
    [ -n "$PORT" ]
}

msg_body() {
    printf '{"model":"%s","max_tokens":16,"messages":[{"role":"user","content":"hi"}]}' "$1"
}

# --- auth ------------------------------------------------------------------

@test "models: an unauthenticated probe is rejected 401" {
    start_gateway healthy
    run curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/anthropic/v1/models"
    [ "$output" = "401" ]
}

@test "messages: an unauthenticated call is rejected 401" {
    start_gateway healthy
    run curl -s -o /dev/null -w '%{http_code}' -X POST \
        -H 'content-type: application/json' -d "$(msg_body alpha)" \
        "http://127.0.0.1:$PORT/anthropic/v1/messages"
    [ "$output" = "401" ]
}

@test "a wrong token is rejected 401, not served" {
    start_gateway healthy
    run curl -s -o /dev/null -w '%{http_code}' -H "x-api-key: wrong-token" \
        "http://127.0.0.1:$PORT/anthropic/v1/models"
    [ "$output" = "401" ]
}

@test "auth is checked BEFORE the scenario, so a failing server still 401s a bare probe" {
    # The whole point of the auth requirement: no scenario is an escape hatch
    # that would let the plugin drop the token and stay green.
    start_gateway upstream-5xx
    run curl -s -o /dev/null -w '%{http_code}' -X POST \
        -H 'content-type: application/json' -d "$(msg_body alpha)" \
        "http://127.0.0.1:$PORT/anthropic/v1/messages"
    [ "$output" = "401" ]
}

@test "health is open (no token) while the server is up" {
    start_gateway healthy
    run curl -s -w '\n%{http_code}' "http://127.0.0.1:$PORT/health"
    [ "${lines[1]}" = "200" ]
    echo "${lines[0]}" | grep -q '"status"'
}

# --- liveness / happy path -------------------------------------------------

@test "healthy: the model list contains the configured aliases" {
    start_gateway healthy
    run curl -s -H "x-api-key: $TOKEN" "http://127.0.0.1:$PORT/anthropic/v1/models"
    [ "$status" -eq 0 ]
    ids="$(echo "$output" | jq -r '.data[].id' | sort | tr '\n' ' ')"
    [ "$ids" = "alpha beta " ]
}

@test "healthy: a messages call round-trips the canned response" {
    start_gateway healthy --response-text "canned-answer-42"
    run curl -s -H "x-api-key: $TOKEN" -H 'content-type: application/json' \
        -d "$(msg_body alpha)" "http://127.0.0.1:$PORT/anthropic/v1/messages"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.content[0].text')" = "canned-answer-42" ]
    [ "$(echo "$output" | jq -r '.model')" = "alpha" ]
    [ "$(echo "$output" | jq -r '.usage.output_tokens')" = "7" ]
}

@test "the request log records the headers the client sent" {
    start_gateway healthy --request-log "$WORK/reqs.jsonl"
    curl -s -o /dev/null -H "x-api-key: $TOKEN" -H 'content-type: application/json' \
        -d "$(msg_body beta)" "http://127.0.0.1:$PORT/anthropic/v1/messages"
    [ -s "$WORK/reqs.jsonl" ]
    [ "$(jq -r '.headers["x-api-key"]' < "$WORK/reqs.jsonl")" = "$TOKEN" ]
    [ "$(jq -r '.body.model' < "$WORK/reqs.jsonl")" = "beta" ]
}

# --- failure modes ---------------------------------------------------------

@test "unknown alias: an unconfigured model is 404" {
    start_gateway healthy
    run curl -s -w '\n%{http_code}' -H "x-api-key: $TOKEN" \
        -H 'content-type: application/json' -d "$(msg_body nope)" \
        "http://127.0.0.1:$PORT/anthropic/v1/messages"
    [ "${lines[1]}" = "404" ]
    echo "${lines[0]}" | grep -q 'not_found_error'
}

@test "upstream-5xx: 502 with an api_error body" {
    start_gateway upstream-5xx
    run curl -s -w '\n%{http_code}' -H "x-api-key: $TOKEN" \
        -H 'content-type: application/json' -d "$(msg_body alpha)" \
        "http://127.0.0.1:$PORT/anthropic/v1/messages"
    [ "${lines[1]}" = "502" ]
    [ "$(echo "${lines[0]}" | jq -r '.error.type')" = "api_error" ]
}

@test "throttle-429: 429 with rate_limit_error and Retry-After" {
    start_gateway throttle-429
    run curl -s -D "$WORK/h" -w '\n%{http_code}' -H "x-api-key: $TOKEN" \
        -H 'content-type: application/json' -d "$(msg_body alpha)" \
        "http://127.0.0.1:$PORT/anthropic/v1/messages"
    [ "${lines[1]}" = "429" ]
    [ "$(echo "${lines[0]}" | jq -r '.error.type')" = "rate_limit_error" ]
    grep -qi 'retry-after' "$WORK/h"
}

@test "context-length: 400 whose message names the overflow" {
    start_gateway context-length
    run curl -s -w '\n%{http_code}' -H "x-api-key: $TOKEN" \
        -H 'content-type: application/json' -d "$(msg_body alpha)" \
        "http://127.0.0.1:$PORT/anthropic/v1/messages"
    [ "${lines[1]}" = "400" ]
    [ "$(echo "${lines[0]}" | jq -r '.error.type')" = "invalid_request_error" ]
    echo "${lines[0]}" | grep -q 'prompt is too long'
}

@test "slow: a client deadline shorter than the delay times out" {
    start_gateway slow --delay 3
    run curl -s --max-time 1 -o /dev/null -H "x-api-key: $TOKEN" \
        -H 'content-type: application/json' -d "$(msg_body alpha)" \
        "http://127.0.0.1:$PORT/anthropic/v1/messages"
    [ "$status" -ne 0 ]
}

@test "slow: the same call completes when given enough time" {
    start_gateway slow --delay 1
    run curl -s --max-time 20 -H "x-api-key: $TOKEN" \
        -H 'content-type: application/json' -d "$(msg_body alpha)" \
        "http://127.0.0.1:$PORT/anthropic/v1/messages"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.content[0].text')" = "fixture response text" ]
}

@test "down: the announced port refuses connections" {
    start_gateway down
    run curl -s --max-time 5 -o /dev/null "http://127.0.0.1:$PORT/health"
    [ "$status" -ne 0 ]
}

@test "response-bytes pads the body past a spill threshold" {
    start_gateway healthy --response-bytes 20000
    run bash -c "curl -s -H 'x-api-key: $TOKEN' -H 'content-type: application/json' \
        -d '$(msg_body alpha)' 'http://127.0.0.1:$PORT/anthropic/v1/messages' \
        | jq -r '.content[0].text' | wc -c"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | tr -d ' ')" -gt 20000 ]
}

# --- fake claude -----------------------------------------------------------

@test "fake-claude emits a result JSON carrying a session id" {
    run env FAKE_CLAUDE_RECORD_DIR="$WORK/rec" FAKE_CLAUDE_PROJECTS_ROOT="$WORK/projects" \
        FAKE_CLAUDE_SESSION_ID="sess-0001" \
        bash "$FIX/fake-claude.sh" --model alpha --output-format json -p "seed prompt"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.session_id')" = "sess-0001" ]
    [ "$(echo "$output" | jq -r '.is_error')" = "false" ]
}

@test "fake-claude writes a transcript under the test-controlled projects root" {
    cd "$WORK"
    run env FAKE_CLAUDE_RECORD_DIR="$WORK/rec" FAKE_CLAUDE_PROJECTS_ROOT="$WORK/projects" \
        FAKE_CLAUDE_SESSION_ID="sess-0002" \
        bash "$FIX/fake-claude.sh" --model alpha --output-format json -p "seed prompt"
    [ "$status" -eq 0 ]
    encoded="$(printf '%s' "$WORK" | sed 's/[^A-Za-z0-9]/-/g')"
    [ -s "$WORK/projects/$encoded/sess-0002.jsonl" ]
    [ "$(head -1 "$WORK/projects/$encoded/sess-0002.jsonl" | jq -r '.sessionId')" = "sess-0002" ]
}

@test "fake-claude records argv and env, and never leaks a token into argv" {
    run env FAKE_CLAUDE_RECORD_DIR="$WORK/rec" FAKE_CLAUDE_PROJECTS_ROOT="$WORK/projects" \
        ANTHROPIC_AUTH_TOKEN="$TOKEN" \
        bash "$FIX/fake-claude.sh" --model alpha --output-format json -p "seed"
    [ "$status" -eq 0 ]
    grep -q -- '--model' "$WORK/rec/argv"
    # NOT a `! grep` — bats runs under `set -e`, but POSIX exempts a pipeline
    # beginning with `!` from it, so `! grep ...` never fails the test. That form
    # silently passed while the token WAS in argv. Run it and assert the status.
    run grep -q "$TOKEN" "$WORK/rec/argv"
    [ "$status" -ne 0 ]
    grep -q "$TOKEN" "$WORK/rec/env"
}

@test "fake-claude records APPEND across invocations" {
    for i in 1 2; do
        env FAKE_CLAUDE_RECORD_DIR="$WORK/rec" FAKE_CLAUDE_PROJECTS_ROOT="$WORK/projects" \
            bash "$FIX/fake-claude.sh" --model alpha --output-format json -p "seed $i" >/dev/null
    done
    [ "$(grep -c -- '--- invocation' "$WORK/rec/argv")" -eq 2 ]
}

@test "fake-claude in fail mode exits non-zero with stderr and no result JSON" {
    run env FAKE_CLAUDE_MODE=fail FAKE_CLAUDE_RECORD_DIR="$WORK/rec" \
        FAKE_CLAUDE_PROJECTS_ROOT="$WORK/projects" \
        bash "$FIX/fake-claude.sh" --model alpha --output-format json -p "seed"
    [ "$status" -ne 0 ]
    echo "$output" | grep -q 'seed run failed'
    # Asserted via status, not `! ... |` — see the argv test above for why.
    run bash -c "printf '%s' \"\$1\" | jq -e '.session_id'" _ "$output"
    [ "$status" -ne 0 ]
}

@test "fake-claude in error mode exits 0 but reports is_error=true (R8's reachable shape)" {
    run env FAKE_CLAUDE_MODE=error FAKE_CLAUDE_RECORD_DIR="$WORK/rec" \
        FAKE_CLAUDE_PROJECTS_ROOT="$WORK/projects" FAKE_CLAUDE_SESSION_ID="sess-err" \
        bash "$FIX/fake-claude.sh" --model alpha --output-format json -p "seed"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.is_error')" = "true" ]
    [ "$(echo "$output" | jq -r '.session_id')" = "sess-err" ]
}

@test "fake-claude in hang mode records its pid and stays alive until signalled (R2's instrument)" {
    mkdir -p "$WORK/rec"
    env FAKE_CLAUDE_MODE=hang FAKE_CLAUDE_RECORD_DIR="$WORK/rec" \
        bash "$FIX/fake-claude.sh" --model alpha --output-format json -p "seed" &
    local fpid=$!
    local i
    for i in $(seq 1 100); do
        [ -s "$WORK/rec/pid" ] && break
        sleep 0.05
    done
    [ -s "$WORK/rec/pid" ]
    # The recorded pid IS the live process (exec, so no orphanable child sleep).
    kill -0 "$(head -1 "$WORK/rec/pid")"
    kill -TERM "$fpid" 2>/dev/null
    wait "$fpid" 2>/dev/null || true
    # And the TERM actually ended it.
    run kill -0 "$(head -1 "$WORK/rec/pid")"
    [ "$status" -ne 0 ]
}

@test "fake-claude --resume reuses the handed session id" {
    run env FAKE_CLAUDE_RECORD_DIR="$WORK/rec" FAKE_CLAUDE_PROJECTS_ROOT="$WORK/projects" \
        bash "$FIX/fake-claude.sh" --model alpha --output-format json --resume "sess-9999" -p "again"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.session_id')" = "sess-9999" ]
}

# --- fake claude: the two knobs U9's supervisor drives it with -------------
#
# U9 classifies a job by EFFECT and by the child's permission denials, so the
# fixture has to be able to produce both. Asserted here rather than only through
# the supervisor suite: a fixture knob that silently stopped working would leave
# supervisor.bats green while the behaviour it claims to prove went dark, which
# is the failure this whole file exists to close.

@test "fake-claude reports no permission denials by default" {
    run env FAKE_CLAUDE_RECORD_DIR="$WORK/rec" FAKE_CLAUDE_PROJECTS_ROOT="$WORK/projects" \
        bash "$FIX/fake-claude.sh" --model alpha --output-format json -p "seed"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -c '.permission_denials')" = "[]" ]
}

@test "fake-claude carries FAKE_CLAUDE_DENIALS through verbatim, with is_error still false" {
    # The shape U8 measured: a call that is present but NOT ALLOWED under
    # dontAsk is attempted, refused, and recorded — while the run still reports
    # a clean turn. That pairing is the hollow success R9 names.
    run env FAKE_CLAUDE_RECORD_DIR="$WORK/rec" FAKE_CLAUDE_PROJECTS_ROOT="$WORK/projects" \
        FAKE_CLAUDE_DENIALS='[{"tool_name":"Bash","tool_use_id":"tu_7","tool_input":{"command":"rm -rf /"}}]' \
        bash "$FIX/fake-claude.sh" --model alpha --output-format json -p "seed"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.is_error')" = "false" ]
    [ "$(echo "$output" | jq -r '.permission_denials | length')" = "1" ]
    [ "$(echo "$output" | jq -r '.permission_denials[0].tool_name')" = "Bash" ]
    [ "$(echo "$output" | jq -r '.permission_denials[0].tool_use_id')" = "tu_7" ]
    [ "$(echo "$output" | jq -r '.permission_denials[0].tool_input.command')" = "rm -rf /" ]
}

@test "fake-claude refuses a malformed FAKE_CLAUDE_DENIALS rather than emitting an unparseable result" {
    # A fixture bug must look like a fixture bug. Emitting a broken object here
    # would surface in a later unit as "the supervisor cannot read denials",
    # which is a day spent in the wrong file.
    run env FAKE_CLAUDE_RECORD_DIR="$WORK/rec" FAKE_CLAUDE_PROJECTS_ROOT="$WORK/projects" \
        FAKE_CLAUDE_DENIALS='not json' \
        bash "$FIX/fake-claude.sh" --model alpha --output-format json -p "seed"
    [ "$status" -eq 64 ]

    # A well-formed JSON value that is not an ARRAY is refused too.
    run env FAKE_CLAUDE_RECORD_DIR="$WORK/rec" FAKE_CLAUDE_PROJECTS_ROOT="$WORK/projects" \
        FAKE_CLAUDE_DENIALS='{"tool_name":"Bash"}' \
        bash "$FIX/fake-claude.sh" --model alpha --output-format json -p "seed"
    [ "$status" -eq 64 ]
}

@test "FAKE_CLAUDE_WRITE creates its paths under the child's cwd, making directories as needed" {
    mkdir -p "$WORK/proj"
    run env FAKE_CLAUDE_RECORD_DIR="$WORK/rec" FAKE_CLAUDE_PROJECTS_ROOT="$WORK/projects" \
        FAKE_CLAUDE_WRITE="out.txt nested/deeper/note.md" \
        bash -c 'cd "$1" && bash "$2" --model alpha --output-format json -p "seed"' \
        _ "$WORK/proj" "$FIX/fake-claude.sh"
    [ "$status" -eq 0 ]
    [ -s "$WORK/proj/out.txt" ]
    [ -s "$WORK/proj/nested/deeper/note.md" ]
}

@test "FAKE_CLAUDE_WRITE refuses an absolute path" {
    # It is the instrument for "the job produced this file IN THE WORKTREE". A
    # path that could land anywhere on the box would make a passing deliverable
    # test prove something else.
    run env FAKE_CLAUDE_RECORD_DIR="$WORK/rec" FAKE_CLAUDE_PROJECTS_ROOT="$WORK/projects" \
        FAKE_CLAUDE_WRITE="/tmp/escape.txt" \
        bash "$FIX/fake-claude.sh" --model alpha --output-format json -p "seed"
    [ "$status" -eq 64 ]
    run bash -c '[ -e /tmp/escape.txt ]'
    [ "$status" -ne 0 ]
}

@test "FAKE_CLAUDE_WRITE lands BEFORE the hang, so a reaped job can still have produced its file" {
    # Load-bearing ordering: U9's cancel and deadline tests need a job that has
    # done something and then does not finish. If the write moved below the hang
    # branch, those cases would silently become "produced nothing", and the
    # classification they exercise would be the wrong one.
    mkdir -p "$WORK/proj2" "$WORK/rec"
    env FAKE_CLAUDE_MODE=hang FAKE_CLAUDE_RECORD_DIR="$WORK/rec" \
        FAKE_CLAUDE_WRITE="early.txt" \
        bash -c 'cd "$1" && bash "$2" --model alpha --output-format json -p "seed"' \
        _ "$WORK/proj2" "$FIX/fake-claude.sh" &
    local fpid=$!
    local i
    for i in $(seq 1 100); do
        [ -s "$WORK/rec/pid" ] && break
        sleep 0.05
    done
    [ -s "$WORK/rec/pid" ]
    [ -s "$WORK/proj2/early.txt" ]
    kill -TERM "$fpid" 2>/dev/null
    wait "$fpid" 2>/dev/null || true
    run kill -0 "$(head -1 "$WORK/rec/pid")"
    [ "$status" -ne 0 ]
}
