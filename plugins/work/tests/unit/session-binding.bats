#!/usr/bin/env bats

load setup_common

# A herdr session's binding to one Linear scope. A binding exists only once a
# person confirms the proposal they were shown (R4), and a confirmation can
# only bind what that proposal named.

bats_require_minimum_version 1.5.0

setup() {
    LIB="$(cd "$BATS_TEST_DIRNAME/../../lib" && pwd)"
    for f in sanitize.sh session-binding.sh; do . "$LIB/$f"; done
    REC="$HERDR_LINEAR_STORE_DIR/sessions/canvas/binding.json"
}

field() {   # field <session> <key>
    herdr_linear::session_binding_read "$1" \
        | python3 -c 'import sys,json; v=json.load(sys.stdin).get(sys.argv[1]); print("" if v is None else v)' "$2"
}

@test "a session with no record reads as unbound" {
    run herdr_linear::session_binding_state canvas
    [ "$output" = "unbound" ]
    run herdr_linear::session_binding_read canvas
    [ "$status" -ne 0 ]
}

@test "a proposal without confirmation leaves the session unbound" {
    run herdr_linear::session_binding_propose canvas team t-web "WEB"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    run herdr_linear::session_binding_state canvas
    [ "$output" = "proposed" ]
    [ -z "$(field canvas scope_id)" ]
}

@test "confirming with the proposal's nonce binds" {
    nonce="$(herdr_linear::session_binding_propose canvas team t-web "WEB")"
    run herdr_linear::session_binding_confirm canvas "$nonce"
    [ "$status" -eq 0 ]
    [ "$(herdr_linear::session_binding_state canvas)" = "bound" ]
    [ "$(field canvas kind)" = "team" ]
    [ "$(field canvas scope_id)" = "t-web" ]
    [ "$(field canvas scope_name)" = "WEB" ]
}

@test "a wrong or empty nonce is refused and changes nothing" {
    nonce="$(herdr_linear::session_binding_propose canvas team t-web "WEB")"
    before="$(cat "$REC")"
    run herdr_linear::session_binding_confirm canvas "not-$nonce"
    [ "$status" -ne 0 ]
    run herdr_linear::session_binding_confirm canvas ""
    [ "$status" -ne 0 ]
    [ "$(cat "$REC")" = "$before" ]
    [ "$(herdr_linear::session_binding_state canvas)" = "proposed" ]
}

@test "a nonce is spent by its confirmation" {
    nonce="$(herdr_linear::session_binding_propose canvas team t-web "WEB")"
    herdr_linear::session_binding_confirm canvas "$nonce"
    herdr_linear::session_binding_unbind canvas
    run herdr_linear::session_binding_confirm canvas "$nonce"
    [ "$status" -ne 0 ]
    [ "$(herdr_linear::session_binding_state canvas)" = "unbound" ]
}

@test "each of the four kinds binds with its id and display name" {
    local kind
    for kind in organization team project initiative; do
        nonce="$(herdr_linear::session_binding_propose "s-$kind" "$kind" "id-$kind" "Name $kind")"
        herdr_linear::session_binding_confirm "s-$kind" "$nonce"
        [ "$(field "s-$kind" kind)" = "$kind" ]
        [ "$(field "s-$kind" scope_id)" = "id-$kind" ]
        [ "$(field "s-$kind" scope_name)" = "Name $kind" ]
    done
}

@test "a fifth kind is refused and writes nothing" {
    run herdr_linear::session_binding_propose canvas milestone m-1 "M1"
    [ "$status" -ne 0 ]
    [ ! -e "$REC" ]
}

@test "an unsafe session name or scope id is refused, never used as a path" {
    run herdr_linear::session_binding_propose "../x" team t-web "WEB"
    [ "$status" -ne 0 ]
    run herdr_linear::session_binding_propose canvas team "../t" "WEB"
    [ "$status" -ne 0 ]
    [ ! -e "$HERDR_LINEAR_STORE_DIR/x" ]
    [ ! -e "$REC" ]
}

@test "rebinding a bound session replaces the scope only after confirmation" {
    nonce="$(herdr_linear::session_binding_propose canvas team t-web "WEB")"
    herdr_linear::session_binding_confirm canvas "$nonce"
    nonce2="$(herdr_linear::session_binding_propose canvas team t-ops "OPS")"
    [ "$(herdr_linear::session_binding_state canvas)" = "bound" ]
    [ "$(field canvas scope_id)" = "t-web" ]
    herdr_linear::session_binding_confirm canvas "$nonce2"
    [ "$(field canvas scope_id)" = "t-ops" ]
    [ "$(field canvas scope_name)" = "OPS" ]
}

@test "declining a rebind keeps the existing binding" {
    nonce="$(herdr_linear::session_binding_propose canvas team t-web "WEB")"
    herdr_linear::session_binding_confirm canvas "$nonce"
    nonce2="$(herdr_linear::session_binding_propose canvas team t-ops "OPS")"
    herdr_linear::session_binding_decline canvas "$nonce2"
    [ "$(herdr_linear::session_binding_state canvas)" = "bound" ]
    [ "$(field canvas scope_id)" = "t-web" ]
}

@test "unbinding removes the binding and the session reads as unbound" {
    nonce="$(herdr_linear::session_binding_propose canvas team t-web "WEB")"
    herdr_linear::session_binding_confirm canvas "$nonce"
    run herdr_linear::session_binding_unbind canvas
    [ "$status" -eq 0 ]
    [ "$(herdr_linear::session_binding_state canvas)" = "unbound" ]
    [ -z "$(field canvas scope_id)" ]
}

@test "a declined session reports declined until a new proposal is made" {
    nonce="$(herdr_linear::session_binding_propose canvas team t-web "WEB")"
    herdr_linear::session_binding_decline canvas "$nonce"
    [ "$(herdr_linear::session_binding_state canvas)" = "declined" ]
    run herdr_linear::session_binding_should_ask canvas
    [ "$status" -ne 0 ]
    herdr_linear::session_binding_propose canvas team t-web "WEB" >/dev/null
    [ "$(herdr_linear::session_binding_state canvas)" = "proposed" ]
}

@test "a decline needs the proposal's nonce" {
    herdr_linear::session_binding_propose canvas team t-web "WEB" >/dev/null
    run herdr_linear::session_binding_decline canvas "wrong"
    [ "$status" -ne 0 ]
    [ "$(herdr_linear::session_binding_state canvas)" = "proposed" ]
}

@test "an unbound session is asked once, and asked again only after an unbind" {
    run herdr_linear::session_binding_should_ask canvas
    [ "$status" -eq 0 ]
    herdr_linear::session_binding_mark_asked canvas
    run herdr_linear::session_binding_should_ask canvas
    [ "$status" -ne 0 ]
    nonce="$(herdr_linear::session_binding_propose canvas team t-web "WEB")"
    herdr_linear::session_binding_decline canvas "$nonce"
    herdr_linear::session_binding_unbind canvas
    run herdr_linear::session_binding_should_ask canvas
    [ "$status" -eq 0 ]
}

@test "a bound session is not asked" {
    nonce="$(herdr_linear::session_binding_propose canvas team t-web "WEB")"
    herdr_linear::session_binding_confirm canvas "$nonce"
    run herdr_linear::session_binding_should_ask canvas
    [ "$status" -ne 0 ]
}

@test "a record another user could write is refused, not read or written through" {
    nonce="$(herdr_linear::session_binding_propose canvas team t-web "WEB")"
    herdr_linear::session_binding_confirm canvas "$nonce"
    chmod 666 "$REC"
    run herdr_linear::session_binding_read canvas
    [ "$status" -ne 0 ]
    [ "$(herdr_linear::session_binding_state canvas)" = "unbound" ]
    run herdr_linear::session_binding_should_ask canvas
    [ "$status" -ne 0 ]
    run herdr_linear::session_binding_propose canvas team t-ops "OPS"
    [ "$status" -ne 0 ]
    grep -q t-web "$REC"
}

@test "a record from a future version or with a state nobody writes reads as absent" {
    mkdir -p "${REC%/*}"
    printf '{"version": 99, "session": "canvas", "state": "bound", "kind": "team", "scope_id": "t", "scope_name": "T"}' > "$REC"; chmod 600 "$REC"
    run herdr_linear::session_binding_read canvas
    [ "$status" -ne 0 ]
    printf '{"version": 1, "session": "canvas", "state": "bound", "kind": "team", "scope_id": "t", "scope_name": "T"}' > "$REC"
    run herdr_linear::session_binding_read canvas
    [ "$status" -eq 0 ]
    printf '{"version": 1, "session": "canvas", "state": "confirmed"}' > "$REC"
    run herdr_linear::session_binding_read canvas
    [ "$status" -ne 0 ]
}

@test "the record is written 0600" {
    herdr_linear::session_binding_propose canvas team t-web "WEB" >/dev/null
    mode="$(stat -f %Lp "$REC" 2>/dev/null || stat -c %a "$REC")"
    [ "$mode" = "600" ]
}

@test "a display name loses control characters and is bounded" {
    long="$(printf 'A%.0s' $(seq 1 300))"
    nonce="$(herdr_linear::session_binding_propose canvas team t-web "$(printf 'WE\033[31mB')$long")"
    herdr_linear::session_binding_confirm canvas "$nonce"
    name="$(field canvas scope_name)"
    [[ "$name" != *$'\033'* ]]
    [ "${#name}" -le 120 ]
}
