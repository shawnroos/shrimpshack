#!/usr/bin/env bats
# U6 — terminal-escape audit (KTD5).
#
# The plugin's whole job is printing text produced by a non-Anthropic model,
# plus alias names and notes read from a user-editable gateway.yaml, straight to
# a terminal. ESC / CSI / OSC sequences and Unicode bidi overrides in that output
# can rewrite the statusline or spoof a consent prompt.
#
# The matrix these tests enforce lives in README.md. Every cell there is either
# closed by grammar or sanitized at the sink, and no cell is marked closed
# without a test in this file pointing at it. The last test is a LINT: it scans
# lib/*.sh for a stderr print that bypasses the sanitizing chokepoint, so the
# class stays closed for sinks nobody has written yet. That is the lesson of
# plugins/claude-modes/docs/solutions/terminal-escape-audit.md — the same bug
# class reopened at a new sibling sink in three consecutive review rounds, and
# what finally held it shut was a computed-scope lint, not vigilance.
#
# TWO FALSE-GREEN TRAPS THIS FILE IS WRITTEN AGAINST
#   1. `! grep ...` does NOT fail a bats test. bats runs under `set -e`, but
#      POSIX exempts a pipeline beginning with `!`. Three assertions in this
#      repo passed while the condition they guarded was false. Negative
#      assertions here go through refute_bytes, which fails as a plain command.
#   2. "no escape byte survives" is vacuously true when the escape byte was
#      never there. EVERY sanitization test below first asserts the poison is
#      present in the INPUT (assert_bytes on the fixture's own record) before
#      asserting it is absent from the output.

setup() {
    FIX="$(cd "$BATS_TEST_DIRNAME/../fixtures" && pwd)"
    LIB="$(cd "$BATS_TEST_DIRNAME/../../lib" && pwd)"
    CTL="$LIB/gatewayctl.sh"
    LENS="$LIB/lens.sh"
    LAUNCH="$LIB/launch.sh"
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/gw-esc.XXXXXX")"
    WORK="$(cd "$WORK" && pwd -P)"
    TOKEN="tok-esc-4c7d"
    GW_PID=""

    export GATEWAY_STATE_HOME="$WORK"
    export GATEWAY_SEARCH_ROOT="$WORK/searchroot"
    mkdir -p "$GATEWAY_SEARCH_ROOT"
    export TMPDIR="$WORK/tmp"
    mkdir -p "$TMPDIR"
    export GATEWAY_CONNECT_TIMEOUT=2
    export GATEWAY_PROBE_TIMEOUT=5
    export GATEWAY_START_TIMEOUT=10
    export GATEWAY_LOCK_TIMEOUT=30
    unset GATEWAY_INSTALL_DIR GATEWAY_CONFIG GATEWAY_MODELS_JSON GATEWAY_CLAUDE_BIN
    unset GATEWAY_LOG GATEWAY_LENS_TIMEOUT GATEWAY_SPILL_BYTES
    # Default at a port nothing serves: a test that forgets to point somewhere
    # must not probe the REAL gateway on 4000.
    export GATEWAY_BASE_URL="http://127.0.0.1:1/anthropic"

    export CLAUDE_CONFIG_DIR="$WORK/claude-home"
    mkdir -p "$CLAUDE_CONFIG_DIR"
    export FAKE_CLAUDE_RECORD_DIR="$WORK/rec"
    mkdir -p "$FAKE_CLAUDE_RECORD_DIR"
    unset FAKE_CLAUDE_MODE FAKE_CLAUDE_SESSION_ID FAKE_CLAUDE_RESULT_TEXT

    # The poison bytes, spelled as ANSI-C escapes so this file itself carries no
    # literal control byte (a file full of invisible bytes is unreviewable, and
    # an editor that eats one turns a real assertion into a vacuous one).
    ESC=$'\033'          # U+001B — the head of every CSI and OSC sequence
    BEL=$'\007'          # U+0007 — the OSC terminator
    CR=$'\r'             # U+000D — overwrite-the-line
    BIDI=$'\xe2\x80\xae' # U+202E RIGHT-TO-LEFT OVERRIDE, as UTF-8
    ZWSP=$'\xe2\x80\x8b' # U+200B ZERO WIDTH SPACE
    # A full spoof payload: retitle the terminal, erase the screen, reverse the
    # text that follows. MARKER is the ASCII carrier — its survival proves the
    # sanitizer stripped the controls instead of dropping the whole string.
    MARKER="ESCPOISONMARKER"
    POISON="${ESC}]0;pwned${BEL}${ESC}[2J${MARKER}${BIDI}tail${CR}${ZWSP}"

    OUT="$WORK/out.bin"
    ERR="$WORK/err.bin"
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

# --- assertions ------------------------------------------------------------
#
# Both fail as PLAIN commands (an explicit `return 1`), which `set -e` honours.
# Neither is written as `! grep`, which set -e does not honour.

assert_bytes() {   # <bytes> <file...> — the poison IS in the input
    local pat="$1"; shift
    if grep -qF -- "$pat" "$@"; then
        return 0
    fi
    printf 'assert_bytes: expected bytes MISSING from %s — the test would have passed vacuously\n' "$*" >&2
    return 1
}

refute_bytes() {   # <bytes> <file...> — the poison is NOT in the output
    local pat="$1"; shift
    if grep -qF -- "$pat" "$@"; then
        printf 'refute_bytes: poison survived into %s\n' "$*" >&2
        od -c "$@" | head -20 >&2
        return 1
    fi
    return 0
}

# Run a command with stdout and stderr captured to SEPARATE files. bats' own
# `run` MERGES them into $output, which would make "the JSON keeps the bytes as
# data, the terminal output does not" impossible to assert — the single most
# likely way this suite goes subtly and silently wrong.
#
# Stdin comes from $SPLIT_STDIN (a FILE), never from a pipe into this function:
# `printf ... | split_run ...` runs the function in a SUBSHELL, so SPLIT_RC
# would be set there and read as 0 here, and every exit-code assertion below
# would be asserting a constant.
SPLIT_RC=0
SPLIT_STDIN=/dev/null
split_run() {
    rm -f "$OUT" "$ERR"
    SPLIT_RC=0
    "$@" <"$SPLIT_STDIN" >"$OUT" 2>"$ERR" || SPLIT_RC=$?
    return 0
}

# stdin_file <text> — a prompt on disk for split_run to feed the script.
stdin_file() {
    printf '%s' "$1" > "$WORK/stdin.txt"
    SPLIT_STDIN="$WORK/stdin.txt"
}

# --- helpers ---------------------------------------------------------------

make_config() {  # <path> <token> [alias=model ...]
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

# ===========================================================================
# 1. The primitive itself (lib/sanitize.sh)
# ===========================================================================

@test "sanitizer strips ESC, BEL, CR and DEL while keeping tab, newline and prose" {
    printf '%s' "$POISON" > "$WORK/in.bin"
    assert_bytes "$ESC" "$WORK/in.bin"
    assert_bytes "$BEL" "$WORK/in.bin"
    assert_bytes "$CR" "$WORK/in.bin"

    run bash -c '. "$1"; gateway::sanitize_for_display "$2"' _ "$LIB/sanitize.sh" "$POISON"
    [ "$status" -eq 0 ]
    printf '%s' "$output" > "$WORK/got.bin"
    refute_bytes "$ESC" "$WORK/got.bin"
    refute_bytes "$BEL" "$WORK/got.bin"
    refute_bytes "$CR" "$WORK/got.bin"
    # The ASCII carrier survives: this strips controls, it does not blank the
    # string, and a blanked string would make every later assertion vacuous.
    assert_bytes "$MARKER" "$WORK/got.bin"

    # Tab and newline are KEPT — a stripped newline runs a multi-line diagnostic
    # into one unreadable line, which is a legibility regression, not a defence.
    run bash -c '. "$1"; gateway::sanitize_for_display "$2" | od -c | tr -d "\n"' _ \
        "$LIB/sanitize.sh" $'a\tb\nc'
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '\\t'
    echo "$output" | grep -q '\\n'
}

@test "sanitizer strips Unicode bidi overrides and zero-width characters" {
    printf '%s' "$POISON" > "$WORK/in.bin"
    assert_bytes "$BIDI" "$WORK/in.bin"
    assert_bytes "$ZWSP" "$WORK/in.bin"

    run bash -c '. "$1"; gateway::sanitize_for_display "$2"' _ "$LIB/sanitize.sh" "$POISON"
    printf '%s' "$output" > "$WORK/got.bin"
    refute_bytes "$BIDI" "$WORK/got.bin"
    refute_bytes "$ZWSP" "$WORK/got.bin"
    assert_bytes "$MARKER" "$WORK/got.bin"

    # Legitimate non-ASCII prose is untouched — a sanitizer that ate accented
    # text would be quietly corrupting every model answer it was pointed at.
    PROSE=$'caf\xc3\xa9 \xe2\x96\xb8 ok'
    run bash -c '. "$1"; gateway::sanitize_for_display "$2"' _ "$LIB/sanitize.sh" "$PROSE"
    [ "$output" = "$PROSE" ]
}

@test "sanitizer stream form strips per line and preserves line structure" {
    printf 'one%s[2Jx\ntwo%sy\nthree\n' "$ESC" "$BIDI" > "$WORK/in.bin"
    assert_bytes "$ESC" "$WORK/in.bin"
    assert_bytes "$BIDI" "$WORK/in.bin"

    bash -c '. "$1"; gateway::sanitize_stream < "$2" > "$3"' _ "$LIB/sanitize.sh" "$WORK/in.bin" "$WORK/got.bin"
    refute_bytes "$ESC" "$WORK/got.bin"
    refute_bytes "$BIDI" "$WORK/got.bin"
    [ "$(wc -l < "$WORK/got.bin" | tr -d ' ')" -eq 3 ]
    assert_bytes "three" "$WORK/got.bin"
}

# ===========================================================================
# 2. Identifiers are closed by CONSTRUCTION — one scenario per entry point
# ===========================================================================

@test "KTD5 grammar: gatewayctl ensure refuses an escape-laden alias, code 2, output clean" {
    BAD="al${ESC}[31mias"
    printf '%s' "$BAD" > "$WORK/alias.bin"
    assert_bytes "$ESC" "$WORK/alias.bin"

    split_run bash "$CTL" ensure "$BAD"
    [ "$SPLIT_RC" -eq 2 ]
    refute_bytes "$ESC" "$OUT" "$ERR"
    [ "$(jq -s 'length' < "$OUT")" -eq 1 ]
    [ "$(jq -r '.exit_code' < "$OUT")" = "2" ]
}

@test "KTD5 grammar: lens refuses an escape-laden alias, code 2, output clean" {
    BAD="al${BIDI}ias"
    printf '%s' "$BAD" > "$WORK/alias.bin"
    assert_bytes "$BIDI" "$WORK/alias.bin"

    stdin_file 'question'
    split_run bash "$LENS" --alias "$BAD"
    [ "$SPLIT_RC" -eq 2 ]
    refute_bytes "$BIDI" "$OUT" "$ERR"
    [ "$(jq -s 'length' < "$OUT")" -eq 1 ]
    [ "$(jq -r '.exit_code' < "$OUT")" = "2" ]
}

@test "KTD5 grammar: launch refuses an escape-laden alias, code 2, output clean" {
    BAD="ali${ESC}]0;x${BEL}as"
    printf '%s' "$BAD" > "$WORK/alias.bin"
    assert_bytes "$ESC" "$WORK/alias.bin"

    stdin_file 'seed'
    split_run bash "$LAUNCH" --alias "$BAD"
    [ "$SPLIT_RC" -eq 2 ]
    refute_bytes "$ESC" "$OUT" "$ERR"
    refute_bytes "$BEL" "$OUT" "$ERR"
    [ "$(jq -s 'length' < "$OUT")" -eq 1 ]
}

@test "KTD5 grammar: a session id that fails the grammar is refused, no handle is printed" {
    start_fixture healthy "alpha"
    export GATEWAY_CLAUDE_BIN="$FIX/fake-claude.sh"
    export FAKE_CLAUDE_SESSION_ID="sess${ESC}[2J-0001"

    printf '%s' "$FAKE_CLAUDE_SESSION_ID" > "$WORK/sid.bin"
    assert_bytes "$ESC" "$WORK/sid.bin"

    cd "$WORK"
    stdin_file 'seed'
    split_run bash "$LAUNCH" --alias alpha --cwd "$WORK"
    # Same class as a missing session id — the CLI's shape has drifted — so it
    # reuses code 5 rather than inventing a new one.
    [ "$SPLIT_RC" -eq 5 ]
    refute_bytes "$ESC" "$OUT" "$ERR"
    [ "$(jq -s 'length' < "$OUT")" -eq 1 ]
    [ "$(jq -r '.attach_command' < "$OUT")" = "null" ]
    [ "$(jq -r '.error' < "$OUT")" = "no_session_id" ]
}

# ===========================================================================
# 3. Free-form text is sanitized AT THE SINK
# ===========================================================================

@test "model prose: the JSON text field keeps the bytes as data, the terminal output does not" {
    start_fixture healthy "alpha" --response-text "$POISON"

    stdin_file 'question'
    split_run bash "$LENS" --alias alpha
    [ "$SPLIT_RC" -eq 0 ]

    # RAW BY DESIGN (KTD5): the model's prose is data. JSON encoding escapes the
    # control bytes in transit, and a consumer gets them back on parse — that is
    # the documented contract, and stripping here would corrupt legitimate code
    # blocks in a review answer. So the bytes MUST still be there after parsing.
    jq -r '.text' < "$OUT" > "$WORK/text.bin"
    assert_bytes "$ESC" "$WORK/text.bin"
    assert_bytes "$BIDI" "$WORK/text.bin"

    # ...and the raw byte is NOT on the wire, because jq encoded it.
    refute_bytes "$ESC" "$OUT"
    # Nothing the lens printed for a HUMAN carries it either.
    refute_bytes "$ESC" "$ERR"
    refute_bytes "$BIDI" "$ERR"
}

@test "gateway error body: the upstream message is sanitized before it is quoted back" {
    # fake-gateway.py has no knob for a poisoned error message and fixtures are
    # not this unit's to change, so this test brings its own 400-responder. It
    # is the only way to exercise the real path — an upstream body reaching the
    # terminal through die() — rather than asserting the chokepoint by proxy.
    cat > "$WORK/poison-gateway.py" <<'PYEOF'
import json, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MSG = sys.argv[1]
ALIAS = sys.argv[2]


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _send(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self._send(200, {"data": [{"type": "model", "id": ALIAS,
                                   "display_name": ALIAS}], "has_more": False})

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        self.rfile.read(n)
        self._send(400, {"type": "error",
                         "error": {"type": "invalid_request_error", "message": MSG}})


srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
sys.stdout.write("PORT=%d\n" % srv.server_address[1])
sys.stdout.flush()
srv.serve_forever()
PYEOF
    python3 "$WORK/poison-gateway.py" "$POISON" alpha > "$WORK/pg.out" 2>"$WORK/pg.err" &
    GW_PID=$!
    local i
    for i in $(seq 1 100); do
        grep -q '^PORT=' "$WORK/pg.out" 2>/dev/null && break
        sleep 0.05
    done
    PORT="$(sed -n 's/^PORT=//p' "$WORK/pg.out")"
    [ -n "$PORT" ]
    export GATEWAY_BASE_URL="http://127.0.0.1:$PORT/anthropic"
    make_config "$WORK/gateway.yaml" "$TOKEN" "alpha=up/alpha"
    export GATEWAY_CONFIG="$WORK/gateway.yaml"

    # The poison really is in the error body this responder was handed.
    printf '%s' "$POISON" > "$WORK/msg.bin"
    assert_bytes "$ESC" "$WORK/msg.bin"
    assert_bytes "$BIDI" "$WORK/msg.bin"

    stdin_file 'question'
    split_run bash "$LENS" --alias alpha
    [ "$SPLIT_RC" -eq 5 ]
    # The message reached us — the detail quotes its ASCII carrier — but the
    # control bytes did not survive either sink.
    assert_bytes "$MARKER" "$ERR"
    refute_bytes "$ESC" "$ERR"
    refute_bytes "$BIDI" "$ERR"
    refute_bytes "$BEL" "$ERR"
    [ "$(jq -s 'length' < "$OUT")" -eq 1 ]
    jq -r '.detail' < "$OUT" > "$WORK/detail.bin"
    assert_bytes "$MARKER" "$WORK/detail.bin"
    refute_bytes "$ESC" "$WORK/detail.bin"
    refute_bytes "$BIDI" "$WORK/detail.bin"
}

@test "served alias list: escape bytes off the wire are stripped from status output" {
    start_fixture healthy "alpha,po${ESC}[2Jison"

    split_run bash "$CTL" status
    [ "$SPLIT_RC" -eq 0 ]
    # The fixture really was told to serve a poisoned id.
    printf '%s' "$GATEWAY_BASE_URL" > /dev/null
    curl -s -H "x-api-key: $TOKEN" "$GATEWAY_BASE_URL/v1/models" > "$WORK/models.raw"
    assert_bytes '\u001b' "$WORK/models.raw"

    refute_bytes "$ESC" "$OUT" "$ERR"
    # And it is not merely dropped: the surviving id still names the alias.
    jq -r '.served_aliases | join(",")' < "$OUT" > "$WORK/aliases.bin"
    assert_bytes "ison" "$WORK/aliases.bin"
    # A grammar-valid alias is byte-identical through the sanitizer, so the
    # served-list membership check that exit 4 depends on is unaffected.
    assert_bytes "alpha" "$WORK/aliases.bin"
}

@test "config-derived display text: a poisoned model note and a poisoned drift value print sanitized" {
    start_fixture healthy "alpha"
    # The plugin's own table, with the poison in `source` — the free-form note
    # explaining where the window number came from. This is the "poisoned model
    # note" cell of the matrix.
    printf '{"version":1,"aliases":{"alpha":{"context_window":1000,"source":%s,"model":"up/alpha","chain":false}}}\n' \
        "$(printf '%s' "$POISON" | jq -Rs .)" > "$WORK/models.json"
    export GATEWAY_MODELS_JSON="$WORK/models.json"
    # And gateway.yaml repointed to a poisoned model string — the model_drift
    # `current` value, which is read from the config rather than the probe.
    make_config "$WORK/gateway.yaml" "$TOKEN" "alpha=up/${MARKER}${ESC}[2Jnew"

    assert_bytes '\u001b' "$WORK/models.json"
    assert_bytes "$ESC" "$WORK/gateway.yaml"

    split_run bash "$CTL" status
    [ "$SPLIT_RC" -eq 0 ]
    refute_bytes "$ESC" "$OUT" "$ERR"
    refute_bytes "$BIDI" "$OUT" "$ERR"

    jq -r '.models[0].source' < "$OUT" > "$WORK/source.bin"
    assert_bytes "$MARKER" "$WORK/source.bin"
    refute_bytes "$ESC" "$WORK/source.bin"
    refute_bytes "$BIDI" "$WORK/source.bin"

    jq -r '.drift.model_drift[0].current' < "$OUT" > "$WORK/current.bin"
    assert_bytes "$MARKER" "$WORK/current.bin"
    refute_bytes "$ESC" "$WORK/current.bin"
}

@test "gateway log tail: a poisoned log line is sanitized before it reaches the terminal" {
    # A start that never serves: the control layer waits out the timeout and
    # then tails the log to stderr. The log is the sink under test — the real
    # gateway writes upstream error bodies there, so those bytes are as
    # untrusted as a model response.
    export GATEWAY_LOG="$WORK/gateway.log"
    printf 'boot line one\n%s\n' "$POISON" > "$GATEWAY_LOG"
    assert_bytes "$ESC" "$GATEWAY_LOG"
    assert_bytes "$BIDI" "$GATEWAY_LOG"

    mkdir -p "$WORK/searchroot/gateway-0.1.0/target/release"
    printf '#!/bin/sh\nexit 0\n' > "$WORK/searchroot/gateway-0.1.0/target/release/gateway"
    chmod +x "$WORK/searchroot/gateway-0.1.0/target/release/gateway"
    make_config "$WORK/gateway.yaml" "$TOKEN" "alpha=up/alpha"
    export GATEWAY_CONFIG="$WORK/gateway.yaml"
    export GATEWAY_START_TIMEOUT=1
    export GATEWAY_BASE_URL="http://127.0.0.1:1/anthropic"

    split_run bash "$CTL" start
    [ "$SPLIT_RC" -eq 3 ]
    # The tail actually fired — otherwise "no escape survived" would be vacuous.
    assert_bytes "$MARKER" "$ERR"
    refute_bytes "$ESC" "$ERR"
    refute_bytes "$BIDI" "$ERR"
    refute_bytes "$ESC" "$OUT"
}

@test "seed-run stderr tail: a poisoned child stderr is sanitized before it reaches the terminal" {
    start_fixture healthy "alpha"
    cat > "$WORK/bad-claude.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "$POISON" >&2
exit 3
EOF
    chmod +x "$WORK/bad-claude.sh"
    export GATEWAY_CLAUDE_BIN="$WORK/bad-claude.sh"
    assert_bytes "$ESC" "$WORK/bad-claude.sh"

    stdin_file 'seed'
    split_run bash "$LAUNCH" --alias alpha --cwd "$WORK"
    [ "$SPLIT_RC" -eq 5 ]
    assert_bytes "$MARKER" "$ERR"
    refute_bytes "$ESC" "$ERR"
    refute_bytes "$BIDI" "$ERR"
    refute_bytes "$BEL" "$ERR"
    [ "$(jq -s 'length' < "$OUT")" -eq 1 ]
}

@test "argv: an escape-laden unexpected argument is echoed back sanitized by every script" {
    BADARG="--wat${ESC}[2J${MARKER}"
    printf '%s' "$BADARG" > "$WORK/arg.bin"
    assert_bytes "$ESC" "$WORK/arg.bin"

    split_run bash "$CTL" "$BADARG"
    [ "$SPLIT_RC" -eq 2 ]
    refute_bytes "$ESC" "$OUT" "$ERR"
    assert_bytes "$MARKER" "$ERR"

    stdin_file 'q'
    split_run bash "$LENS" --alias alpha "$BADARG"
    [ "$SPLIT_RC" -eq 2 ]
    refute_bytes "$ESC" "$OUT" "$ERR"
    assert_bytes "$MARKER" "$ERR"

    split_run bash "$LAUNCH" --alias alpha "$BADARG"
    [ "$SPLIT_RC" -eq 2 ]
    refute_bytes "$ESC" "$OUT" "$ERR"
    assert_bytes "$MARKER" "$ERR"
}

# ===========================================================================
# 4. models.json is a FILE, so its values are a source, not a constant
# ===========================================================================

@test "a non-numeric context_window still yields exactly one JSON object and a launched session" {
    # Regression for a defect this audit turned up in U4's file: a non-numeric
    # window reached `$win|tonumber` in the final emit, jq errored, and the
    # script printed an EMPTY line and exited 0 — no JSON object at all, which
    # is the one thing KTD2 forbids on every path.
    start_fixture healthy "alpha"
    printf '{"version":1,"aliases":{"alpha":{"context_window":"1e6 tokens","model":"up/alpha","chain":false}}}\n' > "$WORK/models.json"
    export GATEWAY_MODELS_JSON="$WORK/models.json"
    export GATEWAY_CLAUDE_BIN="$FIX/fake-claude.sh"

    stdin_file 'seed'
    split_run bash "$LAUNCH" --alias alpha --cwd "$WORK"
    [ "$SPLIT_RC" -eq 0 ]
    [ "$(jq -s 'length' < "$OUT")" -eq 1 ]
    [ "$(jq -r '.ok' < "$OUT")" = "true" ]
    # Treated exactly as an absent entry: launch anyway, name the drift (KTD7).
    [ "$(jq -r '.context_window' < "$OUT")" = "null" ]
    grep -q 'non-numeric context_window' "$ERR"
    # And the bad value never reaches the attach command's env assignment.
    jq -r '.attach_command' < "$OUT" > "$WORK/attach.bin"
    refute_bytes "CLAUDE_CODE_MAX_CONTEXT_TOKENS" "$WORK/attach.bin"
}

# ===========================================================================
# 5. The lint that keeps the class closed after this unit ships
# ===========================================================================
#
# Computed scope, not a hand-maintained file list. The precedent's round-6
# regression happened precisely because a new script was not in the old
# hand-listed set: a find-based scope moves the failure mode from "forgot to
# add" (silent gap) to "forgot to exclude" (loud red).

# terminal_sink_lint <lib-dir> — prints every offending line, returns 1 if any.
terminal_sink_lint() {
    local dir="$1" f base line found=0
    for f in "$dir"/*.sh; do
        [ -f "$f" ] || continue
        base="$(basename "$f")"
        # sanitize.sh is the DEFENCE; it is excluded because it is the one file
        # allowed to print without calling itself. Every exclusion carries a
        # reason — an unannotated one re-opens the silent-gap hole.
        [ "$base" = "sanitize.sh" ] && continue

        # common.sh is a pure-helper library: no diagnostics, no say(), no
        # terminal sink of any kind. The three STRUCTURAL checks below ask a
        # script to own the chokepoints it prints through, and a file that
        # prints nothing has none to own — demanding a say() there would be
        # satisfied by dead code, which is worse than not asking. The SINK SCAN
        # below is deliberately NOT skipped: it still runs on common.sh, so the
        # moment a helper grows a `>&2` print of an interpolated value this
        # lint goes red. That is the property the test is named for, and it
        # stays whole. (The self-test plants exactly that sink to prove it.)
        if [ "$base" != "common.sh" ]; then
            # Every script must source the shared sanitizer rather than grow its own.
            if ! grep -q '\. "\$SCRIPT_DIR/sanitize.sh"' "$f"; then
                printf 'LINT %s: does not source sanitize.sh\n' "$base"
                found=1
            fi
            # ...and its two chokepoints must actually sanitize.
            grep -q 'say() { printf .* "\$(gateway::sanitize_for_display "\$\*")" >&2; }' "$f" \
                || { printf 'LINT %s: say() does not sanitize\n' "$base"; found=1; }
            grep -q 'gateway::sanitize_for_display' "$f" \
                || { printf 'LINT %s: no sanitize call at all\n' "$base"; found=1; }
        fi

        # The sink scan: any line that writes to stderr (or a tty) AND
        # interpolates a shell variable must go through a defence — either it IS
        # a chokepoint definition (it calls sanitize_for_display) or it pipes
        # through the stream filter.
        #
        # NOT line-scoped (R6). The original grep pipeline demanded the print,
        # the `$` and the `>&2` on ONE line, so two real shapes slipped past:
        #   * a multi-line block redirect — `{ printf ... "$X" ... } >&2`,
        #     where the print line has no sink and the sink line has no print;
        #   * `> /dev/stderr`, the same terminal by another name.
        # awk holds the whole file: it records every { ... } group whose
        # CLOSING line carries a terminal redirect, then flags any undefended
        # interpolated print that either carries its own terminal redirect or
        # sits inside such a group. Brace tracking is a trimmed-line heuristic
        # (push on trailing `{`, pop on leading `}`), which is exact for the
        # shell-level groups these scripts use; awk/jq program text inside
        # quotes can transiently unbalance it, but a recorded range only exists
        # where a closing line REDIRECTS TO A TERMINAL, and the self-test
        # plants prove both directions.
        while IFS= read -r line; do
            printf 'LINT %s: raw interpolated stderr sink: %s\n' "$base" "$line"
            found=1
        done < <(awk '
            function is_sink(s)  { return s ~ /(>&2|>>?[ \t]*\/dev\/(stderr|tty))/ }
            function is_print(s) { return s ~ /(printf|echo|cat|tail|head|sed|awk)/ }
            function defended(s) { return s ~ /gateway::sanitize_(for_display|stream)/ }
            { lines[NR] = $0 }
            END {
                sp = 0; nblk = 0
                for (i = 1; i <= NR; i++) {
                    t = lines[i]
                    sub(/^[ \t]+/, "", t); sub(/[ \t]+$/, "", t)
                    if (t ~ /^\}/) {
                        if (sp > 0) {
                            if (is_sink(t)) { nblk++; bs[nblk] = open[sp]; be[nblk] = i }
                            sp--
                        }
                    }
                    if (t ~ /\{$/) { sp++; open[sp] = i }
                }
                for (i = 1; i <= NR; i++) {
                    l = lines[i]
                    if (!is_print(l) || index(l, "$") == 0 || defended(l)) continue
                    hit = is_sink(l)
                    if (!hit) {
                        for (j = 1; j <= nblk; j++) {
                            if (i > bs[j] && i < be[j]) { hit = 1; break }
                        }
                    }
                    if (hit) print i ": " l
                }
            }' "$f")
    done
    return $found
}

@test "lint: no shipped script prints an interpolated value to a terminal without a defence" {
    run terminal_sink_lint "$LIB"
    if [ "$status" -ne 0 ]; then
        printf '%s\n' "$output" >&2
    fi
    [ "$status" -eq 0 ]
}

@test "lint self-test: the lint FAILS on a planted raw sink (a detector never seen failing is vacuous)" {
    mkdir -p "$WORK/liblint"
    cp "$LIB"/*.sh "$WORK/liblint/"

    # Baseline: the copy is clean, so a later red is attributable to the plant.
    run terminal_sink_lint "$WORK/liblint"
    [ "$status" -eq 0 ]

    printf 'printf "leak: %%s\\n" "$SOME_UNTRUSTED_VALUE" >&2\n' >> "$WORK/liblint/gatewayctl.sh"
    run terminal_sink_lint "$WORK/liblint"
    [ "$status" -ne 0 ]
    echo "$output" | grep -q 'raw interpolated stderr sink'

    # A second plant: a script that drops the shared sanitizer entirely.
    cp "$LIB/lens.sh" "$WORK/liblint/lens.sh"
    grep -v 'sanitize' "$LIB/lens.sh" > "$WORK/liblint/lens.sh"
    run terminal_sink_lint "$WORK/liblint"
    [ "$status" -ne 0 ]
    echo "$output" | grep -q 'does not source sanitize.sh'

    # A third plant, on the ONE file the structural checks skip: common.sh is
    # exempt from "must own a say()", NOT from the sink scan. If that carve-out
    # ever widened into a full exclusion this assertion goes green-when-broken,
    # which is precisely the silent gap the computed scope exists to prevent.
    mkdir -p "$WORK/liblint2"
    cp "$LIB"/*.sh "$WORK/liblint2/"
    run terminal_sink_lint "$WORK/liblint2"
    [ "$status" -eq 0 ]
    printf 'printf "helper leak: %%s\\n" "$SOME_UNTRUSTED_VALUE" >&2\n' >> "$WORK/liblint2/common.sh"
    run terminal_sink_lint "$WORK/liblint2"
    [ "$status" -ne 0 ]
    echo "$output" | grep -q 'LINT common.sh: raw interpolated stderr sink'

    # Fourth plant (R6): a MULTI-LINE block redirect. The print line carries no
    # sink and the sink line carries no print, which is exactly what the old
    # line-scoped scan could not see — verified slipping past it.
    mkdir -p "$WORK/liblint3"
    cp "$LIB"/*.sh "$WORK/liblint3/"
    run terminal_sink_lint "$WORK/liblint3"
    [ "$status" -eq 0 ]
    printf '{\n    printf "block leak: %%s\\n" "$SOME_UNTRUSTED_VALUE"\n} >&2\n' >> "$WORK/liblint3/gatewayctl.sh"
    run terminal_sink_lint "$WORK/liblint3"
    [ "$status" -ne 0 ]
    echo "$output" | grep -q 'raw interpolated stderr sink'

    # Fifth plant (R6): /dev/stderr is the same terminal by another name.
    mkdir -p "$WORK/liblint4"
    cp "$LIB"/*.sh "$WORK/liblint4/"
    run terminal_sink_lint "$WORK/liblint4"
    [ "$status" -eq 0 ]
    printf 'printf "dev leak: %%s\\n" "$SOME_UNTRUSTED_VALUE" > /dev/stderr\n' >> "$WORK/liblint4/lens.sh"
    run terminal_sink_lint "$WORK/liblint4"
    [ "$status" -ne 0 ]
    echo "$output" | grep -q 'raw interpolated stderr sink'

    # And the block scan does not fire on a block redirected to a plain FILE —
    # a lint that cries wolf on every curlrc heredoc gets deleted, not fixed.
    mkdir -p "$WORK/liblint5"
    cp "$LIB"/*.sh "$WORK/liblint5/"
    printf '{\n    printf "file write: %%s\\n" "$SOME_VALUE"\n} > "$WORK/somefile"\n' >> "$WORK/liblint5/common.sh"
    run terminal_sink_lint "$WORK/liblint5"
    [ "$status" -eq 0 ]
}
