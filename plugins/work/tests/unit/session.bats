#!/usr/bin/env bats

load setup_common

# Which herdr session this process runs in, read from the socket path herdr
# gives every pane and plugin process. herdr ids are scoped to one server, so a
# wrong answer here applies one session's records in another.

bats_require_minimum_version 1.5.0

setup() {
    FIX="$(cd "$BATS_TEST_DIRNAME/../fixtures" && pwd)"
    LIB="$(cd "$BATS_TEST_DIRNAME/../../lib" && pwd)"
    WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/hl-sess.XXXXXX")" && pwd -P)"
    export FAKE_HERDR_RECORD_DIR="$WORK/rec"
    export HERDR_BIN="$FIX/fake-herdr.sh"
    export HERDR_LINEAR_BIN_PATHS=""
    unset HERDR_SOCKET_PATH
    for f in sanitize.sh herdr-read.sh session.sh; do . "$LIB/$f"; done
}

teardown() {
    [ -n "${WORK:-}" ] && rm -rf "$WORK"
    return 0
}

@test "a pane in the default server reports default" {
    export HERDR_SOCKET_PATH="/Users/someone/.config/herdr/herdr.sock"
    run herdr_linear::session_name
    [ "$status" -eq 0 ]
    [ "$output" = "default" ]
}

@test "a pane in a named session reports that name" {
    export HERDR_SOCKET_PATH="/Users/someone/.config/herdr/sessions/canvas/herdr.sock"
    run herdr_linear::session_name
    [ "$status" -eq 0 ]
    [ "$output" = "canvas" ]
}

@test "a herdr home moved by XDG_CONFIG_HOME still names its session" {
    export HERDR_SOCKET_PATH="/x/herdr/sessions/web-2/herdr.sock"
    run herdr_linear::session_name
    [ "$status" -eq 0 ]
    [ "$output" = "web-2" ]
}

@test "outside herdr, with no socket and no server, there is no session" {
    export FAKE_HERDR_MODE=dead
    run herdr_linear::session_name
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "outside a pane the server's socket line names the session" {
    export FAKE_HERDR_MODE=running
    export FAKE_HERDR_SOCKET_PATH="/Users/someone/.config/herdr/sessions/ops/herdr.sock"
    run herdr_linear::session_name
    [ "$status" -eq 0 ]
    [ "$output" = "ops" ]
}

@test "a socket path with an unsafe session segment is refused" {
    local p
    for p in "/h/herdr/sessions/../herdr.sock" "/h/herdr/sessions/a b/herdr.sock" \
             "/h/herdr/sessions/.hidden/herdr.sock" "/h/herdr/sessions//herdr.sock" \
             '/h/herdr/sessions/$(x)/herdr.sock'; do
        export HERDR_SOCKET_PATH="$p"
        run herdr_linear::session_name
        [ "$status" -ne 0 ] || { echo "accepted: $p"; return 1; }
        [ -z "$output" ]
    done
}

@test "a socket path under an unexpected directory is refused, not guessed" {
    local p
    for p in "/tmp/fake-herdr.sock" "/h/herdr/other/canvas/herdr.sock" \
             "/h/herdr/sessions/canvas/nested/herdr.sock" "/h/notherdr/herdr.sock" \
             "/h/herdr/sessions/canvas/herdr-client.sock"; do
        export HERDR_SOCKET_PATH="$p"
        run herdr_linear::session_name
        [ "$status" -ne 0 ] || { echo "accepted: $p"; return 1; }
    done
}

@test "a pane socket that fails the rule is no session, not the server's" {
    export HERDR_SOCKET_PATH="/tmp/elsewhere.sock"
    export FAKE_HERDR_SOCKET_PATH="/h/herdr/herdr.sock"
    run herdr_linear::session_name
    [ "$status" -ne 0 ]
}

@test "the default session keeps the flat store root" {
    export HERDR_SOCKET_PATH="/h/herdr/herdr.sock"
    run herdr_linear::session_store_root
    [ "$status" -eq 0 ]
    [ "$output" = "$HERDR_LINEAR_STORE_DIR" ]
}

@test "a named session's store root is under sessions/<name>" {
    export HERDR_SOCKET_PATH="/h/herdr/sessions/canvas/herdr.sock"
    run herdr_linear::session_store_root
    [ "$status" -eq 0 ]
    [ "$output" = "$HERDR_LINEAR_STORE_DIR/sessions/canvas" ]
}

@test "with no session there is no store root" {
    export HERDR_SOCKET_PATH="/tmp/elsewhere.sock"
    run herdr_linear::session_store_root
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "a named session called herdr is that session, not the default" {
    export HERDR_SOCKET_PATH="/h/.config/herdr/sessions/herdr/herdr.sock"
    run herdr_linear::session_name
    [ "$status" -eq 0 ]
    [ "$output" = "herdr" ]
}

@test "a named session called default is refused, so it never shares the default session's records" {
    export HERDR_SOCKET_PATH="/h/.config/herdr/sessions/default/herdr.sock"
    run herdr_linear::session_name
    [ "$status" -ne 0 ]
    run herdr_linear::session_store_root
    [ "$status" -ne 0 ]
}
