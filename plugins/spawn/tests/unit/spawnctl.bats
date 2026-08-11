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

    # --- U3 isolation ------------------------------------------------------
    # The start path now reads the Keychain, so EVERY test in this file needs a
    # fake one — including the ones that predate U3, which would otherwise
    # query this machine's login keychain the moment they call `start`. Same
    # env-override discipline as the state and search roots above.
    export SPAWN_SECURITY_BIN="$FIX/fake-security.sh"
    export FAKE_SECURITY_STORE_DIR="$WORK/kc-store"
    export FAKE_SECURITY_RECORD_DIR="$WORK/kc-record"
    mkdir -p "$FAKE_SECURITY_STORE_DIR" "$FAKE_SECURITY_RECORD_DIR"
    # The fixture's own defaults are shared $TMPDIR paths that survive between
    # tests and between runs; pointing them under $WORK is what stops a seeded
    # item leaking into the "empty Keychain" test.
    export SPAWN_KEYCHAIN_SERVICE="spawn-gateway-test"
    export FAKE_GATEWAY_RECORD_DIR="$WORK/gwbin-record"
    # An operator running this suite with their own key exported would other-
    # wise decide the AE9 assertions for it.
    unset OPENROUTER_API_KEY GATEWAY_TOKEN
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

# make_config_tokenless <path> <port> [alias=model ...] — a config carrying NO
# server.token entry at all. This is the shape R9 is about: without a delivered
# GATEWAY_TOKEN the gateway's auth list would be empty, and an empty list makes
# its auth check pass everything.
make_config_tokenless() {
    local path="$1" port="$2"; shift 2
    {
        printf 'server:\n'
        printf '  bind: "127.0.0.1:%s"\n' "$port"
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

# make_stub_install <dir> — an install whose binary is the U3 stub: it records
# its exec-time environment and what the delivery file looked like at exec,
# then serves like the generated fixture above.
make_stub_install() {
    local dir="$1"
    mkdir -p "$dir/target/release"
    cp "$FIX/fake-gateway-bin.sh" "$dir/target/release/gateway"
    chmod +x "$dir/target/release/gateway"
}

# seed_keychain <account> <value> — through the fake `security` binary, fed the
# same way secrets.sh feeds it (twice, on stdin, to a trailing bare -w).
seed_keychain() {
    printf '%s\n%s\n' "$2" "$2" \
        | "$SPAWN_SECURITY_BIN" add-generic-password -a "$1" -s "$SPAWN_KEYCHAIN_SERVICE" -U -w
}

sha_of() { printf '%s' "$1" | shasum | cut -d' ' -f1; }

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

# --- the pidfile is a CLAIM, and this is not its only writer -----------------
#
# Reproduces the live 2026-08-10 failure on a supervised machine: the launchd
# launcher claimed the pidfile, a later `start` stamped its own pid over that
# claim, and when THAT process died `status` reported running:true /
# pid_verified:false against a corpse while the real gateway ran unmanaged —
# stop and restart both refused, so the machine was uncontrollable through the
# plugin. The launcher declines to claim in the mirror-image situation
# (spawn-launch.sh); this pins the reciprocal guard in spawnctl.

# start_claimed_gateway — a LIVE gateway process, argv-identical to one this
# script would spawn, holding the pidfile claim, but NOT answering at
# SPAWN_BASE_URL. That gap is the real shape: a supervised gateway that is
# still binding, wedged, or bound elsewhere is alive without being probeable.
# Sets $CLAIMED_PID.
CLAIMED_PID=""
start_claimed_gateway() {
    local port; port="$(free_port)"
    make_config "$WORK/gateway.yaml" "$port" "$TOKEN" "alpha=up/alpha"
    export SPAWN_CONFIG="$WORK/gateway.yaml"
    make_install "$WORK/install"
    export SPAWN_INSTALL_DIR="$WORK/install"

    "$WORK/install/target/release/gateway" --config "$WORK/gateway.yaml" \
        >"$WORK/claimed.out" 2>&1 &
    CLAIMED_PID=$!
    HELPER_PIDS+=("$CLAIMED_PID")
    local i
    for i in $(seq 1 100); do
        grep -q 'fake gateway binary serving' "$WORK/claimed.out" 2>/dev/null && break
        sleep 0.05
    done
    kill -0 "$CLAIMED_PID"

    printf '%s\n' "$CLAIMED_PID" > "$WORK/.gateway.pid"
    printf '%s\n' "$WORK/install/target/release/gateway" > "$WORK/.gateway.pid.bin"
    # Nothing serves here, so the probe fails on CONNECT (PROBE_LISTENING=0)
    # and reaches the start path. Without the guard, that start overwrites the
    # claim above.
    export SPAWN_BASE_URL="http://127.0.0.1:1/anthropic"
    export SPAWN_START_TIMEOUT=2
}

@test "start refuses to overwrite a pidfile claim held by a LIVE gateway process" {
    start_claimed_gateway

    ctl start

    # BEHAVIOUR FIRST, prose second. Deleting the guard still yields exit 3
    # here (the competing spawn dies on AddrInUse against the claimed
    # gateway's port, and the probe URL serves nothing either way), so the
    # exit code is NOT what distinguishes fixed from broken — the surviving
    # claim is. Asserted before the message so a mutation run fails on the
    # defect itself rather than on a sentence.
    [ "$(cat "$WORK/.gateway.pid")" = "$CLAIMED_PID" ]
    kill -0 "$CLAIMED_PID"
    [ "$(count_gateway_procs "$WORK/install")" -eq 1 ]

    [ "$status" -eq 3 ]
    [ "$(echo "$output" | jq -s 'length')" = "1" ]
    [ "$(echo "$output" | jq -r '.error')" = "unreachable" ]
    echo "$output" | jq -r '.detail' | grep -q 'already claims pid'
}

@test "the claim guard is not blanket: a live NON-gateway pid does not block a start" {
    # Negative control for the pid_is_gateway half. A recycled pid belonging to
    # some unrelated process is not a claim, and must not wedge the start path
    # shut — a guard that refused here would be worse than the bug it fixes.
    local port; port="$(free_port)"
    make_config "$WORK/gateway.yaml" "$port" "$TOKEN" "alpha=up/alpha"
    export SPAWN_CONFIG="$WORK/gateway.yaml"
    export SPAWN_BASE_URL="http://127.0.0.1:$port/anthropic"
    make_install "$WORK/install"
    export SPAWN_INSTALL_DIR="$WORK/install"

    live_decoy_pid
    printf '%s\n' "$DECOY_PID" > "$WORK/.gateway.pid"

    ctl start
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.running')" = "true" ]
    [ "$(cat "$WORK/.gateway.pid")" != "$DECOY_PID" ]
    [ "$(count_gateway_procs "$WORK/install")" -eq 1 ]
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

# --- U3: start-time secret delivery (KTD1; R7, R9) --------------------------
#
# Every assertion below is made from the CHILD's point of view, through the
# stub binary's records, because that is the only place the claims are
# observable: what was in its environment at exec, and what the delivery file
# looked like in its CWD at exec. Asserting from the parent would prove only
# what the start path intended.

@test "R7/AE2: the key reaches the gateway through a mode-0600 delivery file, never its exec-time environment" {
    local port; port="$(free_port)"
    make_config "$WORK/gateway.yaml" "$port" "$TOKEN" "alpha=up/alpha"
    export SPAWN_CONFIG="$WORK/gateway.yaml"
    export SPAWN_BASE_URL="http://127.0.0.1:$port/anthropic"
    make_stub_install "$WORK/install"
    export SPAWN_INSTALL_DIR="$WORK/install"

    local key="sk-or-v1-fixture-key-not-real"
    seed_keychain openrouter-api-key "$key"
    seed_keychain gateway-token "delivered-tok-abc"

    ctl start
    [ "$status" -eq 0 ]

    local rec="$WORK/gwbin-record"
    # The delivery file existed AT EXEC, in the CWD the gateway reads from,
    # mode 0600, carrying both names.
    grep -q '^delivery_present=yes$' "$rec/delivery"
    grep -q '^delivery_mode=600$' "$rec/delivery"
    grep -q '^delivery_vars=OPENROUTER_API_KEY,GATEWAY_TOKEN,$' "$rec/delivery"
    grep -q "^cwd=$WORK/install\$" "$rec/delivery"

    # ...and the key was NOT in the environment the child was exec'd with,
    # which is the copy `ps -Eww` would print.
    run grep -q '^OPENROUTER_API_KEY=' "$rec/env"
    [ "$status" -ne 0 ]
    run grep -q "$key" "$rec/env"
    [ "$status" -ne 0 ]

    # The child ended up holding the delivered value, and it came from the file.
    grep -q '^openrouter_source=file$' "$rec/effective"
    grep -q "^openrouter_sha=$(sha_of "$key")\$" "$rec/effective"
}

@test "the delivery file is gone after a healthy start" {
    local port; port="$(free_port)"
    make_config "$WORK/gateway.yaml" "$port" "$TOKEN" "alpha=up/alpha"
    export SPAWN_CONFIG="$WORK/gateway.yaml"
    export SPAWN_BASE_URL="http://127.0.0.1:$port/anthropic"
    make_stub_install "$WORK/install"
    export SPAWN_INSTALL_DIR="$WORK/install"
    seed_keychain openrouter-api-key "sk-or-v1-gone-after"
    seed_keychain gateway-token "delivered-tok-abc"

    ctl start
    [ "$status" -eq 0 ]
    # It was really delivered — otherwise "it is gone" is vacuous.
    grep -q '^delivery_present=yes$' "$WORK/gwbin-record/delivery"
    [ ! -f "$WORK/install/.env.local" ]
}

@test "the delivery file is gone after a FAILED start too" {
    local port; port="$(free_port)"
    make_config "$WORK/gateway.yaml" "$port" "$TOKEN" "alpha=up/alpha"
    export SPAWN_CONFIG="$WORK/gateway.yaml"
    export SPAWN_BASE_URL="http://127.0.0.1:$port/anthropic"
    make_stub_install "$WORK/install"
    export SPAWN_INSTALL_DIR="$WORK/install"
    seed_keychain openrouter-api-key "sk-or-v1-failed-start"
    seed_keychain gateway-token "delivered-tok-abc"
    # The stub records, then exits 1 without serving.
    export FAKE_GATEWAY_FAIL=1
    export SPAWN_START_TIMEOUT=2

    ctl start
    [ "$status" -eq 3 ]
    # The child did exec and did see the file, so this is the failure path and
    # not a start that never happened.
    grep -q '^delivery_present=yes$' "$WORK/gwbin-record/delivery"
    # A failure that leaves a key on disk is the state KTD1 says cannot exist.
    [ ! -f "$WORK/install/.env.local" ]
}

@test "AE1/R9: a config with no token and an empty Keychain refuses to start, and nothing is exec'd" {
    local port; port="$(free_port)"
    make_config_tokenless "$WORK/gateway.yaml" "$port" "alpha=up/alpha"
    export SPAWN_CONFIG="$WORK/gateway.yaml"
    export SPAWN_BASE_URL="http://127.0.0.1:$port/anthropic"
    make_stub_install "$WORK/install"
    export SPAWN_INSTALL_DIR="$WORK/install"
    # Keychain deliberately empty.

    ctl start
    [ "$status" -eq 2 ]
    [ "$(echo "$output" | jq -s 'length')" = "1" ]
    # R23 (the envelope from the surfaces work): `error` carries the ENUM and
    # the prose moved to `detail`. Assert BOTH — the enum is what a fan-out
    # caller switches on, and the prose is what tells a human which refusal
    # this was. Checking only one of them passes while the other rots.
    [ "$(echo "$output" | jq -r '.error')" = "usage" ]
    echo "$output" | jq -r '.detail' | grep -q 'open proxy'
    # The refusal is BEFORE the spawn: the stub records every exec, and there
    # is no record at all.
    [ ! -f "$WORK/gwbin-record/execs" ]
    [ ! -f "$WORK/install/.env.local" ]
    [ "$(count_gateway_procs "$WORK/install")" -eq 0 ]
}

@test "R9: a config with no token starts when the Keychain supplies one, and the probe authenticates with it" {
    local port; port="$(free_port)"
    make_config_tokenless "$WORK/gateway.yaml" "$port" "alpha=up/alpha"
    export SPAWN_CONFIG="$WORK/gateway.yaml"
    export SPAWN_BASE_URL="http://127.0.0.1:$port/anthropic"
    make_stub_install "$WORK/install"
    export SPAWN_INSTALL_DIR="$WORK/install"

    local tok="delivered-only-token-777"
    seed_keychain openrouter-api-key "sk-or-v1-with-token"
    seed_keychain gateway-token "$tok"

    # The stub rejects any presented token that is not on its list, and its
    # list here can only come from the delivery file — the config carries none.
    # So exit 0 IS the proof that the probe authenticated with the delivered
    # token; a start that silently dropped it would come back 7.
    ctl start
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.started')" = "true" ]
    [ "$(echo "$output" | jq -r '.served_aliases|join(",")')" = "alpha" ]
    grep -q '^gateway_token_source=file$' "$WORK/gwbin-record/effective"
    grep -q "^gateway_token_sha=$(sha_of "$tok")\$" "$WORK/gwbin-record/effective"
    run grep -q "$tok" "$WORK/gwbin-record/env"
    [ "$status" -ne 0 ]
}

@test "a stale delivery file from a crashed start is REPLACED, never appended to" {
    local port; port="$(free_port)"
    make_config "$WORK/gateway.yaml" "$port" "$TOKEN" "alpha=up/alpha"
    export SPAWN_CONFIG="$WORK/gateway.yaml"
    export SPAWN_BASE_URL="http://127.0.0.1:$port/anthropic"
    make_stub_install "$WORK/install"
    export SPAWN_INSTALL_DIR="$WORK/install"

    local fresh="sk-or-v1-fresh-value"
    seed_keychain openrouter-api-key "$fresh"
    seed_keychain gateway-token "delivered-tok-abc"

    # What a crash leaves behind: a stale key, a stray name, and a mode the
    # replace has to fix rather than inherit.
    printf 'OPENROUTER_API_KEY=sk-or-v1-STALE-value\nJUNK_FROM_A_CRASH=1\n' > "$WORK/install/.env.local"
    chmod 644 "$WORK/install/.env.local"

    ctl start
    [ "$status" -eq 0 ]

    local rec="$WORK/gwbin-record"
    # Two lines, two names, no survivor of the stale file. An APPEND would show
    # three or four lines here and JUNK_FROM_A_CRASH among the names — and
    # because dotenv takes the FIRST value it sees for a name, the gateway
    # would have read the stale key.
    grep -q '^delivery_lines=2$' "$rec/delivery"
    grep -q '^delivery_vars=OPENROUTER_API_KEY,GATEWAY_TOKEN,$' "$rec/delivery"
    grep -q '^delivery_mode=600$' "$rec/delivery"
    grep -q "^openrouter_sha=$(sha_of "$fresh")\$" "$rec/effective"
}

@test "AE9: an inherited OPENROUTER_API_KEY is cleared from the child, not merely warned about" {
    local port; port="$(free_port)"
    make_config "$WORK/gateway.yaml" "$port" "$TOKEN" "alpha=up/alpha"
    export SPAWN_CONFIG="$WORK/gateway.yaml"
    export SPAWN_BASE_URL="http://127.0.0.1:$port/anthropic"
    make_stub_install "$WORK/install"
    export SPAWN_INSTALL_DIR="$WORK/install"

    local delivered="sk-or-v1-the-delivered-one"
    local canary="canary-inherited-value-9f3a"
    seed_keychain openrouter-api-key "$delivered"
    seed_keychain gateway-token "delivered-tok-abc"
    export OPENROUTER_API_KEY="$canary"

    # stdout is dropped so the capture is the STDERR notice; the exit status is
    # still the start's own.
    run bash -c 'bash "$1" start 2>&1 1>/dev/null' _ "$CTL"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'IGNORED'
    echo "$output" | grep -q 'OPENROUTER_API_KEY'
    # The notice must not carry either value.
    run bash -c "printf '%s' \"\$1\" | grep -q -e '$canary' -e '$delivered'" _ "$output"
    [ "$status" -ne 0 ]

    local rec="$WORK/gwbin-record"
    # The point of AE9: the canary is not in the child's exec-time environment,
    # under its own name or any other.
    run grep -q "$canary" "$rec/env"
    [ "$status" -ne 0 ]
    run grep -q '^OPENROUTER_API_KEY=' "$rec/env"
    [ "$status" -ne 0 ]
    # ...and the value the gateway actually ended up holding is the delivered
    # one, read from the file. Without the clearing step the inherited value
    # would win, because the dotenv load only sets UNSET variables.
    grep -q '^openrouter_source=file$' "$rec/effective"
    grep -q "^openrouter_sha=$(sha_of "$delivered")\$" "$rec/effective"
    run grep -q "^openrouter_sha=$(sha_of "$canary")\$" "$rec/effective"
    [ "$status" -ne 0 ]
}

@test "a stale delivery file that is a SYMLINK does not carry the key outside the install dir" {
    local port; port="$(free_port)"
    make_config "$WORK/gateway.yaml" "$port" "$TOKEN" "alpha=up/alpha"
    export SPAWN_CONFIG="$WORK/gateway.yaml"
    export SPAWN_BASE_URL="http://127.0.0.1:$port/anthropic"
    make_stub_install "$WORK/install"
    export SPAWN_INSTALL_DIR="$WORK/install"

    local key="sk-or-v1-must-not-escape"
    seed_keychain openrouter-api-key "$key"
    seed_keychain gateway-token "delivered-tok-abc"

    # The shape a truncating write cannot defend against: an existing name that
    # is a link somewhere else, at a mode the delivery would inherit. `: >`
    # follows it and writes the key through; only removing the name first does
    # not.
    printf 'pre-existing\n' > "$WORK/outside.txt"
    chmod 644 "$WORK/outside.txt"
    ln -s "$WORK/outside.txt" "$WORK/install/.env.local"

    ctl start
    [ "$status" -eq 0 ]

    run grep -q "$key" "$WORK/outside.txt"
    [ "$status" -ne 0 ]
    grep -q 'pre-existing' "$WORK/outside.txt"
    grep -q '^delivery_mode=600$' "$WORK/gwbin-record/delivery"
}

# --- stop must not report a stop that KeepAlive undoes ----------------------
#
# On an adopted machine `stop` was a ~10s RESTART: it killed the gateway, the
# launcher's `wait` returned, the launcher exited, and KeepAlive respawned
# everything. result:"stopped" was true for about a second. The plugin already
# says this elsewhere — the open-proxy path unloads the agent first "because
# stopping the process only triggers a respawn" — it just never applied it to
# the everyday verb.
#
# The fixture models `launchctl list`'s real TAB-separated "PID Status Label"
# output, because the pid is read from column 1 and that is the one thing that
# must not drift.

# wire_fake_launchd <pid-to-declare-supervised> — a launchctl stand-in whose
# job list claims that pid. Passing the gateway's PARENT is the real shape
# (setup's launcher is the job; the gateway is its child); passing the gateway
# pid itself models a plist pointed straight at the binary.
wire_fake_launchd() {
    export SPAWN_LAUNCHCTL_BIN="$FIX/fake-launchctl.sh"
    export FAKE_LAUNCHCTL_RECORD="$WORK/launchctl-argv"
    export FAKE_LAUNCHCTL_LIST="$WORK/launchctl-list"
    printf '%s\t0\tcom.test.gateway\n' "$1" > "$FAKE_LAUNCHCTL_LIST"
}

@test "stop REFUSES on a supervised gateway instead of reporting a stop KeepAlive undoes" {
    local port; port="$(free_port)"
    make_config "$WORK/gateway.yaml" "$port" "$TOKEN" "alpha=up/alpha"
    export SPAWN_CONFIG="$WORK/gateway.yaml"
    export SPAWN_BASE_URL="http://127.0.0.1:$port/anthropic"
    make_install "$WORK/install"
    export SPAWN_INSTALL_DIR="$WORK/install"

    bash "$CTL" start >/dev/null
    local pid; pid="$(cat "$WORK/.gateway.pid")"
    kill -0 "$pid"
    wire_fake_launchd "$pid"

    ctl stop

    # NOTHING WAS SIGNALLED, asserted FIRST. This is what separates "refuses"
    # from "kills and then admits it will come back", so a mutation run must
    # fail HERE rather than on an exit code — the same reordering the pidfile-
    # claim guard needed. The gateway is still alive, the pidfile still names
    # it, and no state changed.
    kill -0 "$pid"
    [ "$(cat "$WORK/.gateway.pid")" = "$pid" ]
    [ "$(count_gateway_procs "$WORK/install")" -eq 1 ]

    [ "$status" -eq 2 ]
    [ "$(echo "$output" | jq -s 'length')" = "1" ]
    [ "$(echo "$output" | jq -r '.result')" = "supervised" ]
    [ "$(echo "$output" | jq -r '.supervisor_label')" = "com.test.gateway" ]
    # The remedy names the operation that actually stops it.
    echo "$output" | jq -r '.remedy' | grep -q 'launchctl unload'
}

@test "restart on a supervised gateway aborts and names the supervisor operation" {
    local port; port="$(free_port)"
    make_config "$WORK/gateway.yaml" "$port" "$TOKEN" "alpha=up/alpha"
    export SPAWN_CONFIG="$WORK/gateway.yaml"
    export SPAWN_BASE_URL="http://127.0.0.1:$port/anthropic"
    make_install "$WORK/install"
    export SPAWN_INSTALL_DIR="$WORK/install"

    bash "$CTL" start >/dev/null
    local pid; pid="$(cat "$WORK/.gateway.pid")"
    wire_fake_launchd "$pid"

    ctl restart
    [ "$status" -eq 2 ]
    # Before this, restart "worked" by accident on an adopted machine: the kill
    # triggered a respawn and start_if_down reported success for a restart it
    # had not performed.
    echo "$output" | jq -r '.detail' | grep -q 'kickstart'
    echo "$output" | jq -r '.detail' | grep -q 'com.test.gateway'
    kill -0 "$pid"
    [ "$(count_gateway_procs "$WORK/install")" -eq 1 ]
}

@test "an UNSUPERVISED gateway still stops normally" {
    # Negative control, and the one that matters most: a guard that read every
    # gateway as supervised would make stop refuse to stop anything it started.
    local port; port="$(free_port)"
    make_config "$WORK/gateway.yaml" "$port" "$TOKEN" "alpha=up/alpha"
    export SPAWN_CONFIG="$WORK/gateway.yaml"
    export SPAWN_BASE_URL="http://127.0.0.1:$port/anthropic"
    make_install "$WORK/install"
    export SPAWN_INSTALL_DIR="$WORK/install"

    bash "$CTL" start >/dev/null
    local pid; pid="$(cat "$WORK/.gateway.pid")"
    # A job list that names OTHER pids — launchd is present, this gateway is
    # simply not one of its jobs.
    export SPAWN_LAUNCHCTL_BIN="$FIX/fake-launchctl.sh"
    export FAKE_LAUNCHCTL_RECORD="$WORK/launchctl-argv"
    export FAKE_LAUNCHCTL_LIST="$WORK/launchctl-list"
    printf '99998\t0\tcom.other.thing\n99999\t0\tcom.other.two\n' > "$FAKE_LAUNCHCTL_LIST"

    ctl stop
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.result')" = "stopped" ]
    ! kill -0 "$pid" 2>/dev/null
    [ "$(count_gateway_procs "$WORK/install")" -eq 0 ]
}

@test "a gateway reparented to pid 1 is NOT read as supervised" {
    # do_start_locked backgrounds the gateway in a subshell that exits, so an
    # unsupervised gateway ends up with ppid 1 — launchd itself. If pid 1 were
    # matched against the job list, every orphan on the box would read as
    # supervised and stop would refuse to stop anything it started.
    local port; port="$(free_port)"
    make_config "$WORK/gateway.yaml" "$port" "$TOKEN" "alpha=up/alpha"
    export SPAWN_CONFIG="$WORK/gateway.yaml"
    export SPAWN_BASE_URL="http://127.0.0.1:$port/anthropic"
    make_install "$WORK/install"
    export SPAWN_INSTALL_DIR="$WORK/install"

    bash "$CTL" start >/dev/null
    local pid; pid="$(cat "$WORK/.gateway.pid")"
    # Confirm the premise rather than assuming it: this really is an orphan.
    [ "$(ps -o ppid= -p "$pid" | tr -d ' ')" = "1" ]

    # A job list that claims PID 1. Nothing may match it.
    export SPAWN_LAUNCHCTL_BIN="$FIX/fake-launchctl.sh"
    export FAKE_LAUNCHCTL_RECORD="$WORK/launchctl-argv"
    export FAKE_LAUNCHCTL_LIST="$WORK/launchctl-list"
    printf '1\t0\tcom.apple.launchd\n' > "$FAKE_LAUNCHCTL_LIST"

    ctl stop
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.result')" = "stopped" ]
    ! kill -0 "$pid" 2>/dev/null
}

@test "stop refuses to report success when the process survives SIGKILL" {
    # The wrong-success the other two stop branches were already hardened
    # against, in the one branch that actually signals. SIGKILL is not delivered
    # to a task in uninterruptible sleep, so a gateway wedged on a hung mount
    # survives it — and the old code broke out of the wait loop unconditionally,
    # deleted BOTH pidfile records, and reported ok:true / result:"stopped".
    # Deleting the ownership record is the compounding part: the next stop then
    # lands in the empty-pidfile branch and the gateway is unmanageable.
    #
    # D-state cannot be produced in a test, so the equivalent is used: a process
    # that survives both signals. `kill` is shadowed for the script only, so the
    # signals are genuinely issued and genuinely have no effect — the same
    # observable state, without needing a wedged filesystem.
    local port; port="$(free_port)"
    make_config "$WORK/gateway.yaml" "$port" "$TOKEN" "alpha=up/alpha"
    export SPAWN_CONFIG="$WORK/gateway.yaml"
    export SPAWN_BASE_URL="http://127.0.0.1:$port/anthropic"
    make_install "$WORK/install"
    export SPAWN_INSTALL_DIR="$WORK/install"

    bash "$CTL" start >/dev/null
    local pid; pid="$(cat "$WORK/.gateway.pid")"
    kill -0 "$pid"

    # `kill` is a bash BUILTIN, so a shim on PATH is never consulted — the
    # first version of this test put one there and the gateway simply died,
    # proving nothing. BASH_ENV is sourced by every non-interactive bash at
    # startup, which is exactly what `bash spawnctl.sh` is, so a FUNCTION
    # defined there does shadow the builtin inside the script under test.
    #
    # `kill -0` still answers truthfully via the real builtin: without that the
    # test could not tell "survived" from "the liveness check is broken too".
    cat > "$WORK/nokill.bash" <<'EOS'
kill() {
    if [ "${1:-}" = "-0" ]; then builtin kill "$@"; return $?; fi
    return 0
}
EOS
    export SPAWN_START_TIMEOUT=2
    # stdout ONLY, like the ctl() helper — a diagnostic on stderr would break
    # the parse, which is how this file enforces the never-both-on-stdout rule.
    run bash -c 'BASH_ENV="$1" bash "$2" stop 2>/dev/null' _ "$WORK/nokill.bash" "$CTL"

    # BEHAVIOUR FIRST: the gateway is still alive and still OURS to manage.
    kill -0 "$pid"
    [ -f "$WORK/.gateway.pid" ]
    [ "$(cat "$WORK/.gateway.pid")" = "$pid" ]

    [ "$status" -eq 2 ]
    [ "$(echo "$output" | jq -s 'length')" = "1" ]
    [ "$(echo "$output" | jq -r '.ok')" = "false" ]
    [ "$(echo "$output" | jq -r '.result')" = "kill_failed" ]
}

@test "a lock whose stale-break keeps failing still times out instead of spinning forever" {
    # The livelock: the stale-break branch used to `continue`, jumping past both
    # the sleep and the counter, so LOCK_TIMEOUT was unreachable from it. With a
    # break that never succeeds the loop could not end — a 100%-CPU spin that
    # never exits and never emits the one JSON object the contract promises,
    # inherited by every fan-out worker that calls ensure.
    #
    # Reproduced the way the reviewer described it: a lock directory whose
    # PARENT is read-only, already holding a dead pid. mkdir fails EACCES, the
    # holder is dead so the break fires, the mv fails EPERM, and round it goes.
    local port; port="$(free_port)"
    make_config "$WORK/gateway.yaml" "$port" "$TOKEN" "alpha=up/alpha"
    export SPAWN_CONFIG="$WORK/gateway.yaml"
    export SPAWN_BASE_URL="http://127.0.0.1:$port/anthropic"
    make_install "$WORK/install"
    export SPAWN_INSTALL_DIR="$WORK/install"

    local lockparent="$WORK/lockparent"
    mkdir -p "$lockparent/.gateway.lock"
    printf '%s\n' "$(dead_pid)" > "$lockparent/.gateway.lock/pid"
    chmod a-w "$lockparent"
    export SPAWN_LOCK="$lockparent/.gateway.lock"
    # Small budget so the bound is observable: 1s => ~10 ticks.
    export SPAWN_LOCK_TIMEOUT=1

    # Guard the guard: the break must genuinely be impossible here, or the test
    # passes for the wrong reason (a lock that was simply acquired).
    run mv "$lockparent/.gateway.lock" "$lockparent/.gateway.lock.probe"
    [ "$status" -ne 0 ]

    local before after
    before="$(date +%s)"
    ctl start
    after="$(date +%s)"
    chmod u+w "$lockparent"

    # IT TERMINATED — the assertion the livelock fails. Bounded generously
    # (the budget is 1s; anything under 30 proves the loop ended on its own
    # rather than being cut off by something else).
    [ $((after - before)) -lt 30 ]
    # ...and it terminated the way the contract requires: one JSON object,
    # a named failure, never a silent spin.
    [ "$(echo "$output" | jq -s 'length')" = "1" ]
    [ "$status" -ne 0 ]
    [ "$(echo "$output" | jq -r '.ok')" = "false" ]
}

@test "stop still works when the install directory has been renamed away" {
    # stop used to open with `resolve_install_dir hard`, so renaming or deleting
    # ~/gateway-* under a RUNNING gateway made stop — and therefore restart —
    # die exit 3 "no gateway install found" without signalling anything. A live
    # gateway that cannot be stopped through this surface is the same
    # unmanageable state the rest of this verb goes to lengths to avoid.
    #
    # It never needed the install: pid_is_gateway anchors on $PIDFILE.bin, the
    # binary recorded beside the pidfile at start, precisely so a moved install
    # cannot break identification. status already used soft.
    local port; port="$(free_port)"
    make_config "$WORK/gateway.yaml" "$port" "$TOKEN" "alpha=up/alpha"
    export SPAWN_CONFIG="$WORK/gateway.yaml"
    export SPAWN_BASE_URL="http://127.0.0.1:$port/anthropic"
    make_install "$WORK/install"
    export SPAWN_INSTALL_DIR="$WORK/install"

    bash "$CTL" start >/dev/null
    local pid; pid="$(cat "$WORK/.gateway.pid")"
    kill -0 "$pid"

    # The install disappears under the running process, and the override with
    # it — this is the upgrade/cleanup shape, not an exotic one.
    mv "$WORK/install" "$WORK/install-moved"
    unset SPAWN_INSTALL_DIR

    # Guard the guard: resolution really must fail now, or this passes for the
    # wrong reason. The search root is empty, so nothing can be resolved.
    [ ! -d "$WORK/install" ]

    ctl stop
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.result')" = "stopped" ]
    ! kill -0 "$pid" 2>/dev/null
}
