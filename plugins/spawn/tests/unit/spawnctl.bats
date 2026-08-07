#!/usr/bin/env bats
# U2 — gateway control layer.
#
# Everything here runs against fixtures. The real gateway on port 4000 is out
# of the test path by decision, and a suite that touched it would either fight
# the running process or be quietly skipped — both of which turn green into
# noise.
#
# Two fixtures are in play:
#   * tests/fixtures/fake-gateway.py (U1) — the SERVER the plugin probes. It
#     requires x-api-key on /anthropic/*, which is what keeps the KTD3
#     "probe with the token" requirement from regressing green.
#   * a fake gateway BINARY generated per test below — a real executable file
#     the control layer can resolve, spawn, log, and verify by argv. The U1
#     fixture binds an ephemeral port it chooses itself, so it cannot serve as
#     the thing `start` launches: `start` has to know the URL before the
#     process exists. The generated binary reads its bind address out of the
#     --config file it is handed, exactly as the real gateway does.

setup() {
    FIX="$(cd "$BATS_TEST_DIRNAME/../fixtures" && pwd)"
    LIB="$(cd "$BATS_TEST_DIRNAME/../../lib" && pwd)"
    CTL="$LIB/spawnctl.sh"
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/gw-ctl.XXXXXX")"
    WORK="$(cd "$WORK" && pwd -P)"
    TOKEN="tok-ctl-123"
    GW_PID=""
    HELPER_PIDS=()

    # State and search root are redirected into $WORK so no test can touch
    # ~/.gateway.pid, ~/.gateway.log or ~/.gateway.lock — the real control
    # surface's state — or discover the real ~/gateway-0.1.1 install.
    export SPAWN_STATE_HOME="$WORK"
    export SPAWN_SEARCH_ROOT="$WORK/searchroot"
    mkdir -p "$SPAWN_SEARCH_ROOT"
    export SPAWN_CONNECT_TIMEOUT=2
    export SPAWN_PROBE_TIMEOUT=5
    export SPAWN_START_TIMEOUT=10
    export SPAWN_LOCK_TIMEOUT=30
    unset SPAWN_INSTALL_DIR SPAWN_CONFIG SPAWN_MODELS_JSON
    # Default the base URL at a port nothing serves. Without this a test that
    # forgets to point somewhere would probe the REAL gateway on 4000.
    export SPAWN_BASE_URL="http://127.0.0.1:1/anthropic"
}

teardown() {
    if [ -n "${GW_PID:-}" ]; then
        kill "$GW_PID" 2>/dev/null || true
        wait "$GW_PID" 2>/dev/null || true
    fi
    local p
    for p in "${HELPER_PIDS[@]:-}"; do
        [ -n "$p" ] && kill "$p" 2>/dev/null
    done
    # Any gateway this test spawned lives under $WORK, so its argv carries the
    # path; nothing outside the test can match.
    for p in $(pgrep -f "$WORK" 2>/dev/null); do
        [ "$p" = "$$" ] && continue
        kill -9 "$p" 2>/dev/null
    done
    rm -rf "$WORK"
}

# --- helpers ---------------------------------------------------------------

free_port() {
    python3 -c 'import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}

# make_config <path> <port> <token> [alias=model ...]
make_config() {
    local path="$1" port="$2" token="$3"; shift 3
    {
        printf 'server:\n'
        printf '  bind: "127.0.0.1:%s"\n' "$port"
        printf '  token: %s        # Bearer or x-api-key\n' "$token"
        printf '\n'
        printf 'models:\n'
        local spec alias model
        for spec in "$@"; do
            alias="${spec%%=*}"
            model="${spec#*=}"
            printf '  %s:\n' "$alias"
            printf '    model: %s\n' "$model"
            printf '    display_name: "%s"\n' "$alias"
        done
    } > "$path"
}

# make_install <dir> — a resolvable install: a REGULAR, EXECUTABLE binary at
# the canonical target/release/gateway path.
make_install() {
    local dir="$1"
    mkdir -p "$dir/target/release"
    cat > "$dir/target/release/gateway" <<'PYEOF'
#!/usr/bin/env python3
"""Fake gateway binary. Reads its bind address, token and alias list out of the
--config file it is handed, exactly as the real gateway does, so the control
layer can resolve it, spawn it, and verify its argv without a second channel."""
import json
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

cfg_path = sys.argv[sys.argv.index("--config") + 1]
text = open(cfg_path, encoding="utf-8").read()
PORT = int(re.search(r'bind:\s*"?[^"\s:]+:(\d+)', text).group(1))
TOKEN = re.search(r"token:\s*(\S+)", text).group(1)
ALIASES = re.findall(r"^  ([A-Za-z0-9._-]+):\s*$", text, re.M)

print("fake gateway binary serving on 127.0.0.1:%d" % PORT, flush=True)


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
        path = self.path.split("?", 1)[0]
        if path == "/health":
            self._send(200, {"status": "ok"})
            return
        if path == "/anthropic/v1/models":
            presented = self.headers.get("x-api-key") or ""
            if not presented:
                auth = self.headers.get("authorization") or ""
                if auth.lower().startswith("bearer "):
                    presented = auth[7:]
            if presented != TOKEN:
                self._send(401, {"type": "error",
                                 "error": {"type": "authentication_error",
                                           "message": "invalid x-api-key"}})
                return
            self._send(200, {"data": [{"type": "model", "id": a, "display_name": a}
                                      for a in ALIASES], "has_more": False})
            return
        self._send(404, {"type": "error",
                         "error": {"type": "not_found_error", "message": "no route"}})


ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
PYEOF
    chmod +x "$dir/target/release/gateway"
}

# start_fixture <scenario> <aliases> — the U1 server; sets $PORT and $GW_PID.
start_fixture() {
    local scenario="$1" aliases="$2"
    local portfile="$WORK/port"
    python3 "$FIX/fake-gateway.py" \
        --token "$TOKEN" --aliases "$aliases" --scenario "$scenario" \
        --port-file "$portfile" >"$WORK/gw.out" 2>"$WORK/gw.err" &
    GW_PID=$!
    local i
    for i in $(seq 1 100); do
        [ -s "$portfile" ] && break
        sleep 0.05
    done
    PORT="$(cat "$portfile")"
    [ -n "$PORT" ]
    export SPAWN_BASE_URL="http://127.0.0.1:$PORT/anthropic"
}

# A pid that is guaranteed dead: spawn, reap, reuse the number.
dead_pid() {
    local p
    sleep 0.05 &
    p=$!
    wait "$p" 2>/dev/null
    printf '%s' "$p"
}

# A live process that is definitively NOT the gateway. Sets $DECOY_PID rather
# than printing it: a $(...) capture runs in a subshell, so the bookkeeping
# teardown needs would be lost and the decoy would outlive the run.
DECOY_PID=""
live_decoy_pid() {
    sleep 300 &
    DECOY_PID=$!
    HELPER_PIDS+=("$DECOY_PID")
}

# Run the control script capturing STDOUT ONLY. Every JSON assertion below goes
# through this, so a diagnostic that leaked onto stdout breaks the parse — the
# KTD2 "never both on stdout" rule is enforced by the shape of the harness.
ctl() {
    run bash -c 'bash "$1" "${@:2}" 2>/dev/null' _ "$CTL" "$@"
}

count_gateway_procs() {
    pgrep -f "$1" 2>/dev/null | wc -l | tr -d ' '
}

# --- AE1 / AE2: liveness never reads the pidfile ----------------------------

@test "AE1 stale pidfile: gateway serving, pidfile names a dead pid -> up, no second start" {
    start_fixture healthy "alpha,beta"
    make_config "$WORK/gateway.yaml" 4000 "$TOKEN" "alpha=up/alpha" "beta=up/beta"
    export SPAWN_CONFIG="$WORK/gateway.yaml"
    printf '%s\n' "$(dead_pid)" > "$WORK/.gateway.pid"

    # SPAWN_INSTALL_DIR is unset and the search root is EMPTY, so any attempt
    # to start would fail resolution and exit 3. Exit 0 is therefore proof that
    # no start was attempted, not just that none succeeded.
    ctl ensure
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.running')" = "true" ]
    [ "$(echo "$output" | jq -r '.started')" = "false" ]

    ctl status
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.running')" = "true" ]
    [ "$(echo "$output" | jq -r '.pid_verified')" = "false" ]
}

@test "AE2 recycled pid: gateway down, pidfile names a live unrelated process -> down" {
    start_fixture down "alpha"
    make_config "$WORK/gateway.yaml" 4000 "$TOKEN" "alpha=up/alpha"
    export SPAWN_CONFIG="$WORK/gateway.yaml"
    make_install "$WORK/install"
    export SPAWN_INSTALL_DIR="$WORK/install"

    live_decoy_pid
    printf '%s\n' "$DECOY_PID" > "$WORK/.gateway.pid"
    kill -0 "$DECOY_PID"

    ctl status
    [ "$status" -eq 3 ]
    [ "$(echo "$output" | jq -r '.running')" = "false" ]
    [ "$(echo "$output" | jq -r '.pid_verified')" = "false" ]
    [ "$(echo "$output" | jq -r '.pid')" = "$DECOY_PID" ]
}

# --- stop safety -----------------------------------------------------------

@test "stop refuses to signal a recycled pid whose argv is not the gateway binary" {
    start_fixture down "alpha"
    make_config "$WORK/gateway.yaml" 4000 "$TOKEN" "alpha=up/alpha"
    export SPAWN_CONFIG="$WORK/gateway.yaml"
    make_install "$WORK/install"
    export SPAWN_INSTALL_DIR="$WORK/install"

    live_decoy_pid
    printf '%s\n' "$DECOY_PID" > "$WORK/.gateway.pid"

    ctl stop
    [ "$status" -eq 2 ]
    [ "$(echo "$output" | jq -r '.result')" = "pid_mismatch" ]
    # The decoy is still alive: refused, not killed.
    kill -0 "$DECOY_PID"
}

@test "stop clears a stale pidfile without signalling anything" {
    start_fixture down "alpha"
    make_config "$WORK/gateway.yaml" 4000 "$TOKEN" "alpha=up/alpha"
    export SPAWN_CONFIG="$WORK/gateway.yaml"
    make_install "$WORK/install"
    export SPAWN_INSTALL_DIR="$WORK/install"
    printf '%s\n' "$(dead_pid)" > "$WORK/.gateway.pid"

    ctl stop
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.result')" = "stale_pidfile" ]
    [ ! -f "$WORK/.gateway.pid" ]
}

# --- start / ensure against a real spawned binary --------------------------

@test "start brings a down gateway up and stop takes it back down" {
    local port; port="$(free_port)"
    make_config "$WORK/gateway.yaml" "$port" "$TOKEN" "alpha=up/alpha" "beta=up/beta"
    export SPAWN_CONFIG="$WORK/gateway.yaml"
    export SPAWN_BASE_URL="http://127.0.0.1:$port/anthropic"
    make_install "$WORK/install"
    export SPAWN_INSTALL_DIR="$WORK/install"

    ctl start
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.started')" = "true" ]
    [ "$(echo "$output" | jq -r '.served_aliases|sort|join(",")')" = "alpha,beta" ]

    ctl stop
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.result')" = "stopped" ]

    ctl status
    [ "$status" -eq 3 ]
}

@test "start is a no-op when the gateway is already up" {
    local port; port="$(free_port)"
    make_config "$WORK/gateway.yaml" "$port" "$TOKEN" "alpha=up/alpha"
    export SPAWN_CONFIG="$WORK/gateway.yaml"
    export SPAWN_BASE_URL="http://127.0.0.1:$port/anthropic"
    make_install "$WORK/install"
    export SPAWN_INSTALL_DIR="$WORK/install"

    bash "$CTL" start >/dev/null
    ctl start
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.started')" = "false" ]
    [ "$(count_gateway_procs "$WORK/install")" -eq 1 ]
}

@test "N concurrent ensure calls against a down gateway yield exactly one process" {
    local port; port="$(free_port)"
    make_config "$WORK/gateway.yaml" "$port" "$TOKEN" "alpha=up/alpha"
    export SPAWN_CONFIG="$WORK/gateway.yaml"
    export SPAWN_BASE_URL="http://127.0.0.1:$port/anthropic"
    make_install "$WORK/install"
    export SPAWN_INSTALL_DIR="$WORK/install"

    local i
    for i in $(seq 1 8); do
        bash "$CTL" ensure alpha > "$WORK/out.$i" 2> "$WORK/err.$i" &
    done
    wait

    for i in $(seq 1 8); do
        run jq -r '.exit_code' < "$WORK/out.$i"
        [ "$output" = "0" ]
        [ "$(jq -r '.running' < "$WORK/out.$i")" = "true" ]
    done

    # The assertion the lock exists for: a fan-out of reviewers against a down
    # gateway must not produce a pile of AddrInUse corpses.
    [ "$(count_gateway_procs "$WORK/install")" -eq 1 ]
    # Exactly one of the eight can have been the starter.
    local starters
    starters="$(cat "$WORK"/out.* | jq -s '[.[] | select(.started == true)] | length')"
    [ "$starters" -eq 1 ]
}

@test "R5: a live listener answering non-200 refuses a start instead of spawning against the held port" {
    # Something IS on the port — it just answers wrongly. Point the plugin at
    # the fixture's port under a route prefix it does not serve: every probe
    # gets a 404 from a live process, which is the moved-route / mid-startup
    # shape. curl rc=0 with an HTTP status proves the port is held, so a spawn
    # can only die on AddrInUse and clobber the pidfile with the corpse's pid.
    start_fixture healthy "alpha"
    local port2; port2="$(free_port)"
    # The config binds a FREE port so that, if the guard is ever removed, the
    # spawned decoy binds successfully and survives — making the process-count
    # assertion below go red instead of racing a fast AddrInUse corpse.
    make_config "$WORK/gateway.yaml" "$port2" "$TOKEN" "alpha=up/alpha"
    export SPAWN_CONFIG="$WORK/gateway.yaml"
    make_install "$WORK/install"
    export SPAWN_INSTALL_DIR="$WORK/install"
    export SPAWN_START_TIMEOUT=2
    export SPAWN_BASE_URL="http://127.0.0.1:$PORT/wrong-prefix"

    ctl ensure alpha
    [ "$status" -eq 3 ]
    [ "$(echo "$output" | jq -s 'length')" = "1" ]
    # The refusal is named, and nothing was spawned. Since U3's envelope (R23)
    # `error` carries the ENUM a caller switches on and the prose lives in
    # `detail` — this script used to put English in `error` while lens.sh and
    # launch.sh put an enum there, which is what made forwarding a preflight
    # object unsafe. Both halves are asserted: the enum a machine reads, and
    # the sentence a human reads.
    [ "$(echo "$output" | jq -r '.error')" = "unreachable" ]
    echo "$output" | jq -r '.detail' | grep -q 'refusing to start'
    [ "$(count_gateway_procs "$WORK/install")" -eq 0 ]
}

@test "R3: the log is appended, never truncated, across restarts" {
    local port; port="$(free_port)"
    make_config "$WORK/gateway.yaml" "$port" "$TOKEN" "alpha=up/alpha"
    export SPAWN_CONFIG="$WORK/gateway.yaml"
    export SPAWN_BASE_URL="http://127.0.0.1:$port/anthropic"
    make_install "$WORK/install"
    export SPAWN_INSTALL_DIR="$WORK/install"

    printf 'PRE-EXISTING EVIDENCE LINE\n' > "$WORK/.gateway.log"
    bash "$CTL" start >/dev/null
    bash "$CTL" stop >/dev/null
    bash "$CTL" start >/dev/null

    grep -q 'PRE-EXISTING EVIDENCE LINE' "$WORK/.gateway.log"
    [ "$(grep -c 'spawnctl start' "$WORK/.gateway.log")" -eq 2 ]
    [ "$(grep -c 'fake gateway binary serving' "$WORK/.gateway.log")" -eq 2 ]
}

@test "restart stops the running gateway and brings a fresh one up" {
    local port; port="$(free_port)"
    make_config "$WORK/gateway.yaml" "$port" "$TOKEN" "alpha=up/alpha"
    export SPAWN_CONFIG="$WORK/gateway.yaml"
    export SPAWN_BASE_URL="http://127.0.0.1:$port/anthropic"
    make_install "$WORK/install"
    export SPAWN_INSTALL_DIR="$WORK/install"

    bash "$CTL" start >/dev/null
    local first; first="$(cat "$WORK/.gateway.pid")"

    ctl restart
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.running')" = "true" ]
    [ "$(cat "$WORK/.gateway.pid")" != "$first" ]
    [ "$(count_gateway_procs "$WORK/install")" -eq 1 ]
}

# --- install-dir resolution (KTD4) -----------------------------------------

@test "install dir: an explicit env override is honoured and reported by status" {
    start_fixture healthy "alpha"
    make_config "$WORK/gateway.yaml" 4000 "$TOKEN" "alpha=up/alpha"
    export SPAWN_CONFIG="$WORK/gateway.yaml"
    make_install "$WORK/custom-install"
    export SPAWN_INSTALL_DIR="$WORK/custom-install"

    ctl status
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.install_dir')" = "$WORK/custom-install" ]
    [ "$(echo "$output" | jq -r '.binary')" = "$WORK/custom-install/target/release/gateway" ]
}

@test "install dir: an override naming a missing directory fails hard, never falls through" {
    make_install "$SPAWN_SEARCH_ROOT/gateway-9.9.9"
    export SPAWN_INSTALL_DIR="$WORK/does-not-exist"

    ctl status
    [ "$status" -eq 2 ]
    echo "$output" | grep -q 'not a directory'
    # The fall-through it must NOT have taken. Asserted via status: `! ... |` is
    # exempt from `set -e` under POSIX, so that form never fails a bats test.
    run bash -c "printf '%s' \"\$1\" | grep -q 'gateway-9.9.9'" _ "$output"
    [ "$status" -ne 0 ]
}

@test "install dir: an override with no gateway binary fails hard" {
    mkdir -p "$WORK/empty-install"
    export SPAWN_INSTALL_DIR="$WORK/empty-install"

    ctl status
    [ "$status" -eq 2 ]
    echo "$output" | grep -q 'no executable regular-file gateway binary'
}

@test "install dir: a DIRECTORY named gateway is not accepted as the binary" {
    # -x alone is true of a directory. Without the regular-file check this
    # resolves and the start dies with a bare 'permission denied'.
    mkdir -p "$WORK/dirbin/gateway"
    chmod +x "$WORK/dirbin/gateway"
    export SPAWN_INSTALL_DIR="$WORK/dirbin"

    ctl status
    [ "$status" -eq 2 ]
    echo "$output" | grep -q 'no executable regular-file gateway binary'
}

@test "install dir: with no override the NEWEST versioned dir wins, numerically" {
    # 0.1.10 must beat 0.1.9 — a lexical sort gets this backwards, and mtime
    # gets it backwards the first time someone touches an old directory.
    make_install "$SPAWN_SEARCH_ROOT/gateway-0.1.9"
    make_install "$SPAWN_SEARCH_ROOT/gateway-0.1.10"
    make_install "$SPAWN_SEARCH_ROOT/gateway-0.1.2"
    touch "$SPAWN_SEARCH_ROOT/gateway-0.1.9/target/release/gateway"

    ctl status
    [ "$(echo "$output" | jq -r '.install_dir')" = "$SPAWN_SEARCH_ROOT/gateway-0.1.10" ]
}

@test "install dir: no candidate at all is the unreachable class with a clear stderr message" {
    start_fixture down "alpha"
    make_config "$WORK/gateway.yaml" 4000 "$TOKEN" "alpha=up/alpha"
    export SPAWN_CONFIG="$WORK/gateway.yaml"

    ctl start
    [ "$status" -eq 3 ]
    [ "$(echo "$output" | jq -s 'length')" = "1" ]
    echo "$output" | grep -q 'no gateway install found'

    # ...and the same message reaches a human on STDERR, which is where the
    # diagnostic belongs.
    run bash -c 'bash "$1" start 2>&1 1>/dev/null' _ "$CTL"
    echo "$output" | grep -q 'no gateway install found'
    echo "$output" | grep -q "$SPAWN_SEARCH_ROOT"
}

# --- alias grammar (KTD5) --------------------------------------------------

@test "alias grammar: a shell metacharacter is refused with code 2 before any network call" {
    # BASE_URL points at nothing. A probe would return 3; getting 2 proves the
    # grammar check ran first.
    export SPAWN_BASE_URL="http://127.0.0.1:1/anthropic"
    ctl ensure 'alpha;rm -rf /'
    [ "$status" -eq 2 ]
    [ "$(echo "$output" | jq -r '.ok')" = "false" ]
}

@test "alias grammar: a control byte in the alias is refused with code 2" {
    export SPAWN_BASE_URL="http://127.0.0.1:1/anthropic"
    ctl ensure "$(printf 'al\033[31mpha')"
    [ "$status" -eq 2 ]
}

@test "alias grammar: a legal alias with dots, dashes and underscores passes" {
    start_fixture healthy "gpt-sol-pro,a.b_c"
    make_config "$WORK/gateway.yaml" 4000 "$TOKEN" "gpt-sol-pro=up/x"
    export SPAWN_CONFIG="$WORK/gateway.yaml"
    ctl ensure "a.b_c"
    [ "$status" -eq 0 ]
}

# --- authenticated probe (KTD3) --------------------------------------------

@test "the probe carries the gateway token: ensure and status succeed against an auth-requiring fixture" {
    # This is the assertion that stops KTD3 regressing. The fixture 401s an
    # unauthenticated probe, so if the script stopped sending the header this
    # test would go from 0 to 7.
    start_fixture healthy "alpha,beta"
    make_config "$WORK/gateway.yaml" 4000 "$TOKEN" "alpha=up/alpha" "beta=up/beta"
    export SPAWN_CONFIG="$WORK/gateway.yaml"

    ctl ensure
    [ "$status" -eq 0 ]
    ctl status
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.served_aliases|sort|join(",")')" = "alpha,beta" ]
}

@test "the probe expands \${VAR} in server.token, as the gateway does" {
    start_fixture healthy "alpha"
    make_config "$WORK/gateway.yaml" 4000 '${GW_TEST_TOKEN}' "alpha=up/alpha"
    export SPAWN_CONFIG="$WORK/gateway.yaml"
    export GW_TEST_TOKEN="$TOKEN"

    ctl ensure alpha
    [ "$status" -eq 0 ]
}

@test "auth rejection is code 7, NOT down, and no start is attempted" {
    # The P0 this exists to prevent: reading a 401 as 'down' sends ensure into
    # a start that collides with the running gateway.
    start_fixture healthy "alpha"
    make_config "$WORK/gateway.yaml" 4000 "wrong-token" "alpha=up/alpha"
    export SPAWN_CONFIG="$WORK/gateway.yaml"
    make_install "$WORK/install"
    export SPAWN_INSTALL_DIR="$WORK/install"

    ctl ensure alpha
    [ "$status" -eq 7 ]
    [ "$(echo "$output" | jq -r '.ok')" = "false" ]
    [ "$(count_gateway_procs "$WORK/install")" -eq 0 ]

    ctl status
    [ "$status" -eq 7 ]
    [ "$(count_gateway_procs "$WORK/install")" -eq 0 ]
}

# --- served-list gate (KTD3) -----------------------------------------------

@test "served-list gate: ensure with a listed alias returns 0" {
    start_fixture healthy "alpha,beta"
    make_config "$WORK/gateway.yaml" 4000 "$TOKEN" "alpha=up/alpha" "beta=up/beta"
    export SPAWN_CONFIG="$WORK/gateway.yaml"
    ctl ensure beta
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.alias')" = "beta" ]
}

@test "served-list gate: ensure with an alias the gateway does not serve returns 4" {
    start_fixture healthy "alpha,beta"
    make_config "$WORK/gateway.yaml" 4000 "$TOKEN" "alpha=up/alpha" "beta=up/beta"
    export SPAWN_CONFIG="$WORK/gateway.yaml"
    ctl ensure gamma
    [ "$status" -eq 4 ]
    [ "$(echo "$output" | jq -r '.error')" = "alias_unknown" ]
    [ "$(echo "$output" | jq -r '.alias')" = "gamma" ]
    # 4 is distinguishable from 3: the gateway was reachable.
    [ "$(echo "$output" | jq -r '.served_aliases|sort|join(",")')" = "alpha,beta" ]
}

# --- drift (KTD7) ----------------------------------------------------------

write_table() {
    printf '%s\n' "$1" > "$WORK/models.json"
    export SPAWN_MODELS_JSON="$WORK/models.json"
}

@test "drift 1: a served alias missing from models.json is flagged" {
    start_fixture healthy "alpha,beta"
    make_config "$WORK/gateway.yaml" 4000 "$TOKEN" "alpha=up/alpha" "beta=up/beta"
    export SPAWN_CONFIG="$WORK/gateway.yaml"
    write_table '{"aliases":{"alpha":{"context_window":1000,"source":"test","model":"up/alpha","chain":false}}}'

    ctl status
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.drift.missing_from_table|join(",")')" = "beta" ]
}

@test "drift 2: a table entry with no declared window is flagged" {
    start_fixture healthy "alpha"
    make_config "$WORK/gateway.yaml" 4000 "$TOKEN" "alpha=up/alpha"
    export SPAWN_CONFIG="$WORK/gateway.yaml"
    write_table '{"aliases":{"alpha":{"source":"test","model":"up/alpha","chain":false}}}'

    ctl status
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.drift.missing_window|join(",")')" = "alpha" ]
}

@test "drift 3: an alias whose upstream model string was repointed is flagged" {
    # The alias keeps its NAME, so the models endpoint (id + display_name only)
    # cannot see this. It is caught by reading gateway.yaml.
    start_fixture healthy "alpha"
    make_config "$WORK/gateway.yaml" 4000 "$TOKEN" "alpha=openrouter/vendor/NEW-model"
    export SPAWN_CONFIG="$WORK/gateway.yaml"
    write_table '{"aliases":{"alpha":{"context_window":1000,"source":"test","model":"openrouter/vendor/OLD-model","chain":false}}}'

    ctl status
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.drift.model_drift|length')" = "1" ]
    [ "$(echo "$output" | jq -r '.drift.model_drift[0].alias')" = "alpha" ]
    [ "$(echo "$output" | jq -r '.drift.model_drift[0].recorded')" = "openrouter/vendor/OLD-model" ]
    [ "$(echo "$output" | jq -r '.drift.model_drift[0].current')" = "openrouter/vendor/NEW-model" ]
}

# --- R17: equivalence comes from what the gateway resolves to (KD8) ---------
#
# The gateway serves every model twice — once under its configured name and
# once under a `claude-` prefixed name for the Anthropic-shaped route. Treating
# each prefixed twin as a missing table entry made drift 100% false alarms on
# the live gateway, and a surface that cries wolf gets ignored. Stripping the
# prefix would be the other error: a genuinely NEW model served as
# `claude-<new>` would vanish. So equivalence is read off the gateway.

@test "drift 4 (AE7): two aliases resolving to the same model are not drift" {
    start_fixture healthy "alpha,alpha-mirror,claude-alpha"
    make_config "$WORK/gateway.yaml" 4000 "$TOKEN" \
        "alpha=up/alpha" "alpha-mirror=up/alpha" "claude-alpha=up/alpha"
    export SPAWN_CONFIG="$WORK/gateway.yaml"
    write_table '{"aliases":{"alpha":{"context_window":1000,"source":"test","model":"up/alpha","chain":false}}}'

    ctl status
    [ "$status" -eq 0 ]
    # Neither the differently-spelled twin nor the prefixed one is drift: the
    # config says all three are up/alpha, which the table already carries.
    [ "$(echo "$output" | jq -r '.drift.missing_from_table|length')" = "0" ]
    [ "$(echo "$output" | jq -r '.drift.unknown_resolution|length')" = "0" ]
}

@test "drift 4b (AE7): a prefixed alias resolving to a DIFFERENT model is reported" {
    start_fixture healthy "alpha,claude-alpha"
    make_config "$WORK/gateway.yaml" 4000 "$TOKEN" \
        "alpha=up/alpha" "claude-alpha=up/something-else"
    export SPAWN_CONFIG="$WORK/gateway.yaml"
    write_table '{"aliases":{"alpha":{"context_window":1000,"source":"test","model":"up/alpha","chain":false}}}'

    ctl status
    [ "$status" -eq 0 ]
    # The name is prefixed, the model is new — that is real drift, and hiding it
    # is worse than the false alarm this rule replaced.
    [ "$(echo "$output" | jq -r '.drift.missing_from_table|join(",")')" = "claude-alpha" ]
    [ "$(echo "$output" | jq -r '.drift.unknown_resolution|length')" = "0" ]
}

@test "drift 5: a served alias whose resolution is unavailable is reported unknown" {
    # `mystery` is served but absent from the config's models: block, and the
    # model list gives it a display name matching nothing the table carries. So
    # the gateway states nothing about what it resolves to. Reporting it as a
    # twin would be the same wrong-suppression the prefix rule would have been.
    start_fixture healthy "alpha,mystery"
    make_config "$WORK/gateway.yaml" 4000 "$TOKEN" "alpha=up/alpha"
    export SPAWN_CONFIG="$WORK/gateway.yaml"
    write_table '{"aliases":{"alpha":{"context_window":1000,"source":"test","model":"up/alpha","chain":false}}}'

    ctl status
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.drift.unknown_resolution|join(",")')" = "mystery" ]
    # Not silently equivalent, and not asserted to be new either.
    [ "$(echo "$output" | jq -r '.drift.missing_from_table|length')" = "0" ]
}

@test "drift: the prose rendering still has one machine-readable object under it" {
    # R18. The command body renders prose FROM this object; a Bash-only consumer
    # still parses the object itself, so the response stays one JSON object with
    # the envelope and every drift class present.
    start_fixture healthy "alpha,claude-alpha,mystery"
    make_config "$WORK/gateway.yaml" 4000 "$TOKEN" \
        "alpha=up/alpha" "claude-alpha=up/alpha"
    export SPAWN_CONFIG="$WORK/gateway.yaml"
    write_table '{"aliases":{"alpha":{"context_window":1000,"source":"test","model":"up/alpha","chain":false}}}'

    ctl status
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -s 'length')" = "1" ]
    [ "$(echo "$output" | jq -r '[.schema,.ok,.error,.exit_code]|length')" = "4" ]
    [ "$(echo "$output" | jq -r '.exit_code')" = "0" ]
    [ "$(echo "$output" | jq -r '.drift|keys|sort|join(",")')" \
        = "missing_from_table,missing_window,model_drift,unknown_resolution" ]
    [ "$(echo "$output" | jq -r '.served_aliases|length')" = "3" ]
}

@test "no drift: the shipped models.json matches the config it was seeded from" {
    start_fixture healthy "alpha"
    make_config "$WORK/gateway.yaml" 4000 "$TOKEN" \
        "kimi=openrouter/moonshotai/kimi-k2.7-code" \
        "k3=openrouter/moonshotai/kimi-k3" \
        "glm=openrouter/z-ai/glm-5.2" \
        "gpt-luna=openrouter/openai/gpt-5.6-luna" \
        "gpt-terra=openrouter/openai/gpt-5.6-terra" \
        "gpt-sol=openrouter/openai/gpt-5.6-sol" \
        "gpt-sol-pro=openrouter/openai/gpt-5.6-sol-pro" \
        "gpt=openrouter/openai/gpt-5.6-sol" \
        "default=[openrouter/moonshotai/kimi-k2.7-code, openrouter/z-ai/glm-5.2]"
    export SPAWN_CONFIG="$WORK/gateway.yaml"

    ctl status
    [ "$(echo "$output" | jq -r '.drift.model_drift|length')" = "0" ]
    [ "$(echo "$output" | jq -r '.drift.missing_window|length')" = "0" ]
}

@test "chain alias: status labels it a chain and reports the smallest member window" {
    start_fixture healthy "default"
    make_config "$WORK/gateway.yaml" 4000 "$TOKEN" \
        "default=[openrouter/moonshotai/kimi-k2.7-code, openrouter/z-ai/glm-5.2]"
    export SPAWN_CONFIG="$WORK/gateway.yaml"

    ctl status
    [ "$status" -eq 0 ]
    local entry
    entry="$(echo "$output" | jq -c '.models[] | select(.alias == "default")')"
    [ "$(echo "$entry" | jq -r '.chain')" = "true" ]
    [ "$(echo "$entry" | jq -r '.model|length')" = "2" ]
    # kimi (262144) is smaller than glm (1048576); the table must carry the
    # smaller number so a mid-session fallback under-declares rather than
    # overflowing.
    [ "$(echo "$entry" | jq -r '.context_window')" = "262144" ]
    [ "$(echo "$entry" | jq -r '.context_window')" -lt 1048576 ]
    [ "$(echo "$output" | jq -r '.drift.model_drift|length')" = "0" ]
}

# --- KTD2 output shape -----------------------------------------------------

@test "KTD2: an unknown verb prints one JSON object on stdout and exits 2" {
    ctl bogus-verb
    [ "$status" -eq 2 ]
    [ "$(echo "$output" | jq -s 'length')" = "1" ]
    [ "$(echo "$output" | jq -r '.exit_code')" = "2" ]
}

@test "KTD2: diagnostics never land on stdout — the unreachable path still parses whole" {
    start_fixture down "alpha"
    make_config "$WORK/gateway.yaml" 4000 "$TOKEN" "alpha=up/alpha"
    export SPAWN_CONFIG="$WORK/gateway.yaml"

    ctl status
    [ "$status" -eq 3 ]
    [ "$(echo "$output" | jq -s 'length')" = "1" ]
    [ "$(echo "$output" | jq -r '.running')" = "false" ]
    [ "$(echo "$output" | jq -r '.exit_code')" = "3" ]
}

@test "KTD2: stderr carries the diagnostic for a refusal" {
    export SPAWN_BASE_URL="http://127.0.0.1:1/anthropic"
    run bash -c "bash '$CTL' ensure 'bad alias' 2>&1 1>/dev/null"
    echo "$output" | grep -q 'grammar'
}

# --- no liveness from the pidfile ------------------------------------------

@test "liveness never reads the pidfile: a serving gateway with NO pidfile reads up" {
    start_fixture healthy "alpha"
    make_config "$WORK/gateway.yaml" 4000 "$TOKEN" "alpha=up/alpha"
    export SPAWN_CONFIG="$WORK/gateway.yaml"
    [ ! -f "$WORK/.gateway.pid" ]

    ctl status
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.running')" = "true" ]
    [ "$(echo "$output" | jq -r '.pid')" = "null" ]
}

@test "KTD6: the probe never puts the token in curl's argv" {
    # Regression guard for a real defect. The first implementation passed the
    # token as -H "x-api-key: $TOK", which is readable from the process table by
    # anything on the box — and lens.sh spawns this probe as a child on EVERY
    # call, so the leak rode the lens path too. The fix delivers it through a
    # mode-0600 curl --config file instead.
    #
    # Asserted at runtime rather than by grepping the source, so a future
    # rewrite that reintroduces an argv token in some other shape still fails.
    # A resolvable config is load-bearing for this test, not scaffolding: with
    # no config the token resolves EMPTY, an argv leak has nothing to leak, and
    # the assertion passes against broken code. That false green was observed.
    make_config "$WORK/gw.yaml" 4321 "$TOKEN" alpha=m1
    export SPAWN_CONFIG="$WORK/gw.yaml"

    local shim="$WORK/shim"
    mkdir -p "$shim"
    cat > "$shim/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$WORK/curl-argv.txt"
printf '000'
exit 7
EOF
    chmod +x "$shim/curl"
    : > "$WORK/curl-argv.txt"

    PATH="$shim:$PATH" run bash "$CTL" status
    [ -s "$WORK/curl-argv.txt" ]        # the shim was actually reached
    # Guard the guard: the token must actually be in play, or the leak
    # assertion below is vacuous.
    grep -q "$TOKEN" "$WORK/gw.yaml"

    run grep -q "$TOKEN" "$WORK/curl-argv.txt"
    [ "$status" -ne 0 ]
    run grep -q -- '--config' "$WORK/curl-argv.txt"
    [ "$status" -eq 0 ]
}

# --- stop: a listener that answers ANYTHING is a listener --------------------
#
# Both branches below used to key on the probe returning EX_OK, so a gateway
# that answered 401 — proving it is alive, just not with our token — read as
# "nothing is running". The empty-pidfile branch then reported a clean stop
# that never happened, and the dead-pid branch deleted the ownership record
# while a gateway served: the unstoppable-through-this-surface state the probe
# was added to prevent. Both now key on PROBE_LISTENING.

@test "stop: an AUTH-rejecting listener with an empty pidfile is refused, not reported stopped" {
    start_fixture healthy "alpha"
    # The fixture serves on $TOKEN; the config carries a different one, so the
    # probe gets 401 (EX_AUTH) rather than EX_OK. A listener is still there.
    make_config "$WORK/gateway.yaml" 4000 "wrong-token-entirely" "alpha=up/alpha"
    export SPAWN_CONFIG="$WORK/gateway.yaml"
    make_install "$WORK/install"
    export SPAWN_INSTALL_DIR="$WORK/install"

    : > "$WORK/.gateway.pid"

    ctl stop
    [ "$status" -eq 2 ]
    [ "$(echo "$output" | jq -r '.result')" = "unmanaged" ]
    [ "$(echo "$output" | jq -r '.ok')" = "false" ]
}

@test "stop: an AUTH-rejecting listener does not get the pidfile deleted under it" {
    start_fixture healthy "alpha"
    make_config "$WORK/gateway.yaml" 4000 "wrong-token-entirely" "alpha=up/alpha"
    export SPAWN_CONFIG="$WORK/gateway.yaml"
    make_install "$WORK/install"
    export SPAWN_INSTALL_DIR="$WORK/install"

    # A pid that is dead: the branch that used to rm -f the pidfile.
    local dead; dead=$(bash -c 'echo $$')
    while kill -0 "$dead" 2>/dev/null; do dead=$((dead + 1)); done
    printf '%s\n' "$dead" > "$WORK/.gateway.pid"

    ctl stop
    [ "$status" -eq 2 ]
    [ "$(echo "$output" | jq -r '.result')" = "unmanaged" ]
    # The record survives: deleting it while a gateway serves is the bug.
    [ -s "$WORK/.gateway.pid" ]
}
