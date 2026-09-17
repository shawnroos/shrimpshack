#!/usr/bin/env bats

load setup_common

# The work plugin's herdr plugin: a startup hook that asks an unbound session to
# bind, the popup that asks, and the label a tab bar entry shows.
#
# herdr runs a startup hook with no person watching, and a linked plugin runs in
# every herdr server the person starts (docs/session-spikes.md). So the hook only
# ever OPENS the question: it never proposes, confirms or declines a binding,
# and it asks a session at most once.

bats_require_minimum_version 1.5.0

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    FIX="$ROOT/tests/fixtures"
    WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/hl-hp.XXXXXX")" && pwd -P)"
    export HERDR_SOCKET_PATH="/h/.config/herdr/sessions/canvas/herdr.sock"
    export HERDR_BIN_PATH="$FIX/fake-herdr.sh"
    export HERDR_BIN="$FIX/fake-herdr.sh"
    export HERDR_LINEAR_BIN_PATHS=""
    export FAKE_HERDR_RECORD_DIR="$WORK/rec"
    export HERDR_PLUGIN_ID="work.session"
    export HERDR_PLUGIN_CONFIG_DIR="$WORK/config"
    mkdir -p "$HERDR_PLUGIN_CONFIG_DIR"
    for f in sanitize.sh session.sh binding.sh session-binding.sh; do . "$ROOT/lib/$f"; done
}

teardown() { [ -n "${WORK:-}" ] && rm -rf "$WORK"; return 0; }

opens() { local n; n="$(grep -c '^plugin pane open --plugin work.session --entrypoint bind$' "$FAKE_HERDR_RECORD_DIR/argv" 2>/dev/null)" || true; printf '%s' "${n:-0}"; }

start_hook() { run bash "$ROOT/bin/session-start.sh"; }

bind_canvas() {   # bind_canvas <kind> <id> <name>
    local n; n="$(herdr_linear::session_binding_propose canvas "$1" "$2" "$3")"
    herdr_linear::session_binding_confirm canvas "$n"
}

linear_world() {
    export HERDR_LINEAR_CURL_BIN="$FIX/fake-linear.sh"
    export HERDR_LINEAR_SECURITY_BIN="$FIX/fake-security.sh"
    export FAKE_SECURITY_STORE_DIR="$WORK/kc"
    export FAKE_LINEAR_RECORD_DIR="$WORK/lrec"
    export LINEAR_SECRETS_FILE="$WORK/secrets"
    export HERDR_LINEAR_RETRY_MAX=1
    mkdir -p "$FAKE_LINEAR_RECORD_DIR"
    printf 'LINEAR_API_KEY=%s\n' "lin_api""_HERDRPLUGINHERDRPLUG" > "$LINEAR_SECRETS_FILE"
    export FAKE_LINEAR_SCOPE_WORLD="$WORK/world.json"
    printf '%s' '{"teams":[{"id":"t-web","key":"WEB","name":"Web"},{"id":"t-ops","key":"OPS","name":"Ops"}],"projects":{},"issues":{}}' > "$FAKE_LINEAR_SCOPE_WORLD"
}

# ------------------------------------------------------------ the startup hook

@test "AE2: an unbound session's start opens the bind popup once, and later starts do not" {
    start_hook
    [ "$status" -eq 0 ]
    [ "$(opens)" = 1 ]
    start_hook
    [ "$status" -eq 0 ]
    [ "$(opens)" = 1 ]
}

@test "a declined session's start opens nothing" {
    n="$(herdr_linear::session_binding_propose canvas team t-web "WEB Web")"
    herdr_linear::session_binding_decline canvas "$n"
    start_hook
    [ "$status" -eq 0 ]
    [ "$(opens)" = 0 ]
}

@test "a bound session's start opens nothing" {
    bind_canvas team t-web "WEB Web"
    start_hook
    [ "$(opens)" = 0 ]
}

@test "a popup herdr would not open is asked again at the next start, and the hook still exits 0" {
    export FAKE_HERDR_PANE_OPEN_FAILS=1
    start_hook
    [ "$status" -eq 0 ]
    run herdr_linear::session_binding_should_ask canvas
    [ "$status" -eq 0 ]
}

@test "the startup hook never proposes or confirms a binding" {
    start_hook
    [ "$(herdr_linear::session_binding_state canvas)" = unbound ]
    herdr_linear::session_binding_read canvas | python3 -c '
import sys, json
r = json.load(sys.stdin)
assert r["proposal"] is None and r["scope_id"] == "" and r["asked"] is True, r'
    run grep -nE 'session_binding_(propose|confirm|decline|unbind)' "$ROOT/bin/session-start.sh"
    [ "$status" -ne 0 ]
}

@test "an unreadable store makes the hook exit 0 without asking" {
    mkdir -p "$HERDR_LINEAR_STORE_DIR/sessions/canvas"
    printf '{"version":1,"session":"canvas","state":"unbound"}' > "$HERDR_LINEAR_STORE_DIR/sessions/canvas/binding.json"
    chmod 666 "$HERDR_LINEAR_STORE_DIR/sessions/canvas/binding.json"
    start_hook
    [ "$status" -eq 0 ]
    [ "$(opens)" = 0 ]
}

@test "a person's off switch stops every start-time ask" {
    : > "$HERDR_PLUGIN_CONFIG_DIR/no-ask"
    start_hook
    [ "$status" -eq 0 ]
    [ "$(opens)" = 0 ]
    [ ! -e "$HERDR_LINEAR_STORE_DIR/sessions" ]
}

@test "a server whose socket names no session is left alone" {
    export HERDR_SOCKET_PATH="/tmp/some-other-tool.sock"
    start_hook
    [ "$status" -eq 0 ]
    [ "$(opens)" = 0 ]
    [ ! -e "$HERDR_LINEAR_STORE_DIR/sessions" ]
}

@test "a hook with no plugin id opens nothing" {
    unset HERDR_PLUGIN_ID
    start_hook
    [ "$status" -eq 0 ]
    [ "$(opens)" = 0 ]
}

# ------------------------------------------------------------------- the label

@test "a bound session's label is its scope's display name" {
    bind_canvas team t-web "WEB Web"
    run bash "$ROOT/bin/session-label.sh"
    [ "$status" -eq 0 ]
    [ "$output" = "WEB Web" ]
}

@test "an unbound session's label says unbound, and a server with no session shows nothing" {
    run bash "$ROOT/bin/session-label.sh"
    [ "$output" = "unbound" ]
    export HERDR_SOCKET_PATH="/tmp/some-other-tool.sock"
    run bash "$ROOT/bin/session-label.sh"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "a label cannot carry control characters or run long, even from a record edited by hand" {
    bind_canvas team t-web "WEB"
    python3 - "$HERDR_LINEAR_STORE_DIR/sessions/canvas/binding.json" <<'PY'
import json, sys
p = sys.argv[1]; r = json.load(open(p))
r["scope_name"] = "WEB\x1b]0;x\x07" + "A" * 90
json.dump(r, open(p, "w"))
PY
    run bash "$ROOT/bin/session-label.sh"
    [[ "$output" != *$'\033'* ]]
    [[ "$output" != *$'\007'* ]]
    [ "${#output}" -le 40 ]
}

# ------------------------------------------------------------------- the popup

@test "the popup binds the session to the team the person picks, after a yes" {
    linear_world
    run bash -c "printf '2\n2\ny\n' | HL_POPUP_PAUSE=0 bash '$ROOT/bin/session-bind.sh'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"canvas"* ]]
    [[ "$output" == *"OPS Ops"* ]]
    [ "$(herdr_linear::session_binding_state canvas)" = bound ]
    [ "$(herdr_linear::session_scope | cut -f2)" = t-ops ]
}

@test "a no in the popup declines, and the next start does not ask" {
    linear_world
    run bash -c "printf '2\n1\nn\n' | HL_POPUP_PAUSE=0 bash '$ROOT/bin/session-bind.sh'"
    [ "$status" -eq 0 ]
    [ "$(herdr_linear::session_binding_state canvas)" = declined ]
    start_hook
    [ "$(opens)" = 0 ]
}

@test "closing the popup without an answer records nothing" {
    linear_world
    run bash -c "printf '\n' | HL_POPUP_PAUSE=0 bash '$ROOT/bin/session-bind.sh'"
    [ "$status" -eq 0 ]
    run herdr_linear::session_binding_read canvas
    [ "$status" -ne 0 ]
    run bash -c "printf '2\n9\n' | HL_POPUP_PAUSE=0 bash '$ROOT/bin/session-bind.sh'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"There is no choice 9"* ]]
    [ "$(herdr_linear::session_binding_state canvas)" = unbound ]
}

@test "a Linear read that fails in the popup changes nothing and says so" {
    linear_world
    export FAKE_LINEAR_SCOPE_FAIL=rate_limited
    run bash -c "printf '2\n' | HL_POPUP_PAUSE=0 bash '$ROOT/bin/session-bind.sh'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"could not be read"* ]]
    [ "$(herdr_linear::session_binding_state canvas)" = unbound ]
}

@test "the bind action opens the popup even for a session that declined" {
    n="$(herdr_linear::session_binding_propose canvas team t-web "WEB Web")"
    herdr_linear::session_binding_decline canvas "$n"
    run bash "$ROOT/bin/session-bind.sh" open
    [ "$status" -eq 0 ]
    [ "$(opens)" = 1 ]
}

# ---------------------------------------------------------------- the manifest

@test "the manifest declares the startup hook, the bind action and a popup pane, each running a script that exists" {
    run python3 - "$ROOT/herdr/herdr-plugin.toml" "$ROOT" <<'PY'
import os, re, sys, tomllib
m = tomllib.load(open(sys.argv[1], "rb"))
root = sys.argv[2]
for k in ("id", "name", "version", "min_herdr_version"):
    assert m.get(k), k
assert m["id"] == "work.session", m["id"]
def script(cmd):
    text = " ".join(cmd)
    found = re.findall(r"bin/[a-z-]+\.sh", text)
    assert found, text
    for f in found:
        assert os.path.isfile(os.path.join(root, f)), f
    return text
assert "session-start.sh" in script(m["startup"][0]["command"])
acts = {a["id"]: a for a in m["actions"]}
assert script(acts["bind"]["command"]).rstrip().endswith('session-bind.sh" open'), acts["bind"]["command"]
assert "open" not in script(panes_cmd := [p for p in m["panes"] if p["id"] == "bind"][0]["command"]), panes_cmd
panes = {p["id"]: p for p in m["panes"]}
assert panes["bind"]["placement"] == "popup", panes
assert "session-bind.sh" in script(panes["bind"]["command"])
PY
    [ "$status" -eq 0 ] || printf '%s\n' "$output" >&2
    [ "$status" -eq 0 ]
}
