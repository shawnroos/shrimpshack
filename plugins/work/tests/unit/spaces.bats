#!/usr/bin/env bats

load setup_common

# U7 — bin/work-spaces.sh, every herdr space with its binding state, as the
# list envelope. Nothing here reaches herdr or Linear: herdr is the fake, and
# the script makes no Linear call at all.

bats_require_minimum_version 1.5.0

setup() {
    ROOT="${BATS_TEST_DIRNAME}/../.."
    BIN="$ROOT/bin/work-spaces.sh"
    FIX="${BATS_TEST_DIRNAME}/../fixtures"
    SPACEFIX="$FIX/spaces"
    WORK="$(cd "$(mktemp -d)" && pwd -P)"

    export HERDR_LINEAR_STORE_DIR="$WORK/store"
    export HERDR_LINEAR_PIN_DIR="$WORK/pin"
    export HERDR_LINEAR_SHADOW_LOG="$WORK/shadow.log"
    export FAKE_HERDR_RECORD_DIR="$WORK/herdr-rec"
    export HERDR_BIN="$FIX/fake-herdr.sh"
    export FAKE_HERDR_MODE=running
    export FAKE_HERDR_WORKSPACES="wA=Plugins,wB=Scratch"
    mkdir -p "$FAKE_HERDR_RECORD_DIR"

    # shellcheck source=/dev/null
    for f in sanitize.sh binding.sh scope-record.sh; do . "$ROOT/lib/$f"; done

    PROJECT=44444444-4444-4444-8444-444444444444
    OTHER=99999999-9999-4999-8999-999999999999

    local n
    n="$(herdr_linear::workspace_propose wA "$PROJECT")"
    herdr_linear::workspace_confirm wA "$PROJECT" "$n"
}

teardown() { [ -n "${WORK:-}" ] && rm -rf "$WORK"; }

refute_match() {   # refute_match <grep-args...> -- fails when grep MATCHES
    if grep "$@"; then
        printf 'refute_match: unexpectedly matched: %s\n' "$*" >&2
        return 1
    fi
}

ws_file() { printf '%s/workspaces/%s.json' "$HERDR_LINEAR_STORE_DIR" "$1"; }
env_field() { printf '%s' "$output" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(json.dumps(eval(sys.argv[1])))' "$1"; }
row_of() { env_field "[r for r in d['rows'] if r['id'] == '$1']"; }

set_record_field() {   # set_record_field <ws> <key> <json value>
    python3 - "$(ws_file "$1")" "$2" "$3" <<'PY'
import json, sys
p, k, v = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
d = json.load(open(p))
d[k] = v
json.dump(d, open(p, "w"), indent=2, sort_keys=True)
PY
}

expect_fixture() {
    local fixture="$1" got want
    run --separate-stderr bash "$BIN"
    [ "$status" -eq 0 ] || { printf 'exit %s\nstderr: %s\n' "$status" "$stderr" >&2; return 1; }
    got="$(printf '%s' "$output" | python3 -c 'import sys,json;print(json.dumps(json.load(sys.stdin),sort_keys=True,indent=2))')"
    want="$(python3 -c 'import sys,json;print(json.dumps(json.load(sys.stdin),sort_keys=True,indent=2))' < "$SPACEFIX/$fixture")"
    if [ "$got" != "$want" ]; then
        diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") >&2 || true
        return 1
    fi
}

# ------------------------------------------------------------ the fixtures

@test "two live spaces, one bound and one not, both appear with their states" {
    expect_fixture two-spaces.json
}

@test "AE6: a failed herdr space read prints unavailable in a non-empty document" {
    export FAKE_HERDR_WORKSPACE_LIST_FAILS=1
    expect_fixture herdr-unavailable.json
    [ -n "$output" ]
    [ "$(env_field 'd["rows"]')" = '[]' ]
}

@test "herdr not running, and herdr gone, both print unavailable rather than every space bound" {
    local mode
    for mode in not_running dead; do
        FAKE_HERDR_MODE="$mode" run --separate-stderr bash "$BIN"
        [ "$status" -eq 0 ]
        [ "$(env_field 'd["status"]')" = '"unavailable"' ]
        [ "$(env_field 'd["rows"]')" = '[]' ]
        [ "$(env_field 'd["message"]')" != 'null' ]
    done
}

# ------------------------------------------------------------ the details

@test "a recorded space with no live space appears as not live, labelled by its id, after the live ones" {
    local n
    n="$(herdr_linear::workspace_propose wZ "$OTHER")"
    herdr_linear::workspace_confirm wZ "$OTHER" "$n"
    run --separate-stderr bash "$BIN"
    [ "$status" -eq 0 ]
    [ "$(env_field '[r["id"] for r in d["rows"]]')" = '["wA", "wB", "wZ"]' ]
    [ "$(row_of wZ)" = "[{\"id\": \"wZ\", \"label\": \"wZ\", \"live\": false, \"project_id\": \"$OTHER\", \"project_name\": null, \"state\": \"bound\"}]" ]
}

@test "no spaces and no records prints an empty list with ok" {
    rm -rf "$HERDR_LINEAR_STORE_DIR"
    export FAKE_HERDR_WORKSPACES=""
    run --separate-stderr bash "$BIN"
    [ "$status" -eq 0 ]
    [ "$(env_field 'd["status"]')" = '"ok"' ]
    [ "$(env_field 'd["message"]')" = 'null' ]
    [ "$(env_field 'd["rows"]')" = '[]' ]
    [ "$(env_field 'sorted(d)')" = '["message", "rows", "status"]' ]
}

@test "the state is the record's own: proposed reads as proposed, and a refused record as unbound" {
    local n
    n="$(herdr_linear::workspace_propose wB "$OTHER")"
    run --separate-stderr bash "$BIN"
    [ "$(env_field "[r['state'] for r in d['rows']]")" = '["bound", "proposed"]' ]
    [ "$(env_field "d['rows'][1]['project_id']")" = 'null' ]

    # 664 is group-writable, which the loader refuses.
    chmod 664 "$(ws_file wA)"
    run --separate-stderr bash "$BIN"
    [ "$status" -eq 0 ]
    [ "$(row_of wA)" = '[{"id": "wA", "label": "Plugins", "live": true, "project_id": null, "project_name": null, "state": "unbound"}]' ]

    chmod 600 "$(ws_file wA)"
    printf '{"version": 1, "state": "confirmed", "worktree_path": ""}\n' > "$(ws_file wA)"
    run --separate-stderr bash "$BIN"
    [ "$(env_field "d['rows'][0]['state']")" = '"unbound"' ]
}

@test "project_name comes from the space record, and no Linear call is made" {
    printf '#!/usr/bin/env bash\ntouch "%s/called"\nexit 1\n' "$WORK" > "$WORK/spy"
    chmod +x "$WORK/spy"
    export HERDR_LINEAR_CURL_BIN="$WORK/spy" HERDR_LINEAR_SECURITY_BIN="$WORK/spy"
    printf 'LINEAR_API_KEY=%s\n' "lin_api""_SPACESSPACESSPACES" > "$LINEAR_SECRETS_FILE"
    set_record_field wA project_name '"Canvas tools"'
    run --separate-stderr bash "$BIN"
    [ "$status" -eq 0 ]
    [ "$(env_field "d['rows'][0]['project_name']")" = '"Canvas tools"' ]
    set_record_field wA project_name '42'
    run --separate-stderr bash "$BIN"
    [ "$(env_field "d['rows'][0]['project_name']")" = 'null' ]
    [ ! -e "$WORK/called" ]
}

@test "a label carrying a separator, an escape or a bidi override is sanitised, and forges no row" {
    local esc rlo
    esc="$(printf '\033')"; rlo="$(printf '\xe2\x80\xae')"
    export FAKE_HERDR_WORKSPACES="wA=Plu${esc}]2;owned${esc}\\ ${rlo}gins,wB=Scr
wF	at${esc}ch"
    set_record_field wA project_name '"Canvas\u001b]0;x\u001b\\ \u202etools"'
    run --separate-stderr bash "$BIN"
    [ "$status" -eq 0 ]
    [ "$(env_field '[r["id"] for r in d["rows"]]')" = '["wA", "wB"]' ]
    [ "$(env_field "d['rows'][0]['label']")" = '"Plu]2;owned\\ gins"' ]
    [ "$(env_field "d['rows'][1]['label']")" = '"ScrwFatch"' ]
    [ "$(env_field "d['rows'][0]['project_name']")" = '"Canvas]0;x\\ tools"' ]
    refute_match -F "$esc" <<< "$output"
    refute_match -F "$rlo" <<< "$output"
}

@test "a space id outside the id shape, live or recorded, is dropped" {
    export FAKE_HERDR_WORKSPACES="wA=Plugins,../up=Escape,-rf=Option,wB=Scratch"
    mkdir -p "$HERDR_LINEAR_STORE_DIR/workspaces"
    cp "$(ws_file wA)" "$HERDR_LINEAR_STORE_DIR/workspaces/has space.json"
    run --separate-stderr bash "$BIN"
    [ "$status" -eq 0 ]
    [ "$(env_field '[r["id"] for r in d["rows"]]')" = '["wA", "wB"]' ]
}

# ------------------------------------------------------------ the exit codes

@test "any argument exits with the refusal code and prints nothing" {
    local bad
    for bad in wA "" "--all"; do
        run --separate-stderr bash "$BIN" "$bad"
        [ "$status" -eq 2 ]
        [ -z "$output" ]
    done
}

@test "with no library beside it the script exits non-zero and prints nothing" {
    mkdir -p "$WORK/lonely/bin"
    cp "$BIN" "$WORK/lonely/bin/"
    run --separate-stderr bash "$WORK/lonely/bin/work-spaces.sh"
    [ "$status" -ne 0 ]
    [ "$status" -ne 2 ]
    [ -z "$output" ]
}

@test "a space list that exits non-zero, or answers with something other than the list, is unavailable" {
    local shim="$WORK/herdr-shim.sh"
    # Every verb but `workspace list` goes to the fake, so the probe still passes.
    cat > "$shim" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = workspace ] && [ "\${2:-}" = list ]; then
    printf '%s' "\$SHIM_LIST_OUT"
    exit "\$SHIM_LIST_RC"
fi
exec "$FIX/fake-herdr.sh" "\$@"
SH
    chmod +x "$shim"
    export HERDR_BIN="$shim"
    local listing='{"result":{"workspaces":[{"workspace_id":"wA","label":"Plugins"}]}}'

    SHIM_LIST_OUT="$listing" SHIM_LIST_RC=0 run --separate-stderr bash "$BIN"
    [ "$(env_field 'd["status"]')" = '"ok"' ]

    SHIM_LIST_OUT="$listing" SHIM_LIST_RC=1 run --separate-stderr bash "$BIN"
    [ "$status" -eq 0 ]
    [ "$(env_field 'd["status"]')" = '"unavailable"' ]
    [ "$(env_field 'd["rows"]')" = '[]' ]

    local garbage
    for garbage in 'not json' '{"result":{"workspaces":{}}}' '{"error":{"code":"busy"}}'; do
        SHIM_LIST_OUT="$garbage" SHIM_LIST_RC=0 run --separate-stderr bash "$BIN"
        [ "$status" -eq 0 ]
        [ "$(env_field 'd["status"]')" = '"unavailable"' ]
        [ "$(env_field 'd["rows"]')" = '[]' ]
    done
}

@test "space records that cannot be listed, or list as something other than records, are unknown" {
    local real_py shimdir="$WORK/pyshim"
    real_py="$(command -v python3)"
    mkdir -p "$shimdir"
    # Only the record listing is intercepted; every other python3 the script
    # runs, including the one that prints the envelope, is the real one.
    cat > "$shimdir/python3" <<SH
#!/usr/bin/env bash
for a in "\$@"; do
    if [ "\$a" = list-workspaces ]; then
        printf '%s' "\$SHIM_RECORDS_OUT"
        exit "\$SHIM_RECORDS_RC"
    fi
done
exec "$real_py" "\$@"
SH
    chmod +x "$shimdir/python3"

    SHIM_RECORDS_OUT="" SHIM_RECORDS_RC=1 run --separate-stderr env PATH="$shimdir:$PATH" bash "$BIN"
    [ "$status" -eq 0 ]
    [ "$(env_field 'd["status"]')" = '"unknown"' ]
    [ "$(env_field 'd["rows"]')" = '[]' ]
    [[ "$(env_field 'd["message"]')" == *records* ]]

    SHIM_RECORDS_OUT='not json' SHIM_RECORDS_RC=0 run --separate-stderr env PATH="$shimdir:$PATH" bash "$BIN"
    [ "$status" -eq 0 ]
    [ "$(env_field 'd["status"]')" = '"unknown"' ]
    [ "$(env_field 'd["rows"]')" = '[]' ]
    [[ "$(env_field 'd["message"]')" == *records* ]]
}
