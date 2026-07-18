#!/usr/bin/env bats
# Unit tests for lib/connect.py — scaffold <repo>/token-bridge.config.json binding
# a codebase to a Paper file (reference an existing file, or create a new one).

setup() {
    SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    LIB="$SCRIPT_DIR/lib/connect.py"
    LIB_DIR="$SCRIPT_DIR/lib"
    REPO="$BATS_TMPDIR/connect_repo"
    rm -rf "$REPO"
    mkdir -p "$REPO/src/styles"
    touch "$REPO/src/styles/tokens.css"
    CONFIG="$REPO/token-bridge.config.json"
}

# ============================================================================
# Reference an existing Paper file by URL — id is extracted, config scaffolded
# ============================================================================

@test "connect: references a file by URL, extracts the id, writes a valid config" {
    run python3 "$LIB" --repo "$REPO" --source src/styles/tokens.css --prefix=--brand- \
        --file 'https://app.paper.design/file/01ABC123XYZ/1-0'
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.ok')" = "true" ]
    [ "$(echo "$output" | jq -r '.fileId')" = "01ABC123XYZ" ]
    [ "$(echo "$output" | jq -r '.created')" = "false" ]

    # the written config is valid and carries the resolved fields
    [ "$(jq -r '.fileId' "$CONFIG")" = "01ABC123XYZ" ]
    [ "$(jq -r '.source.path' "$CONFIG")" = "src/styles/tokens.css" ]
    [ "$(jq -r '.source.prefix' "$CONFIG")" = "--brand-" ]
    [ "$(jq -r '.emitTarget' "$CONFIG")" = "src/styles/tokens.generated.css" ]
    [ "$(jq -r '.themeConventions[0].type' "$CONFIG")" = "data-attribute" ]
    [ "$(jq -r '.themeConventions[0].primary' "$CONFIG")" = "true" ]
    [ "$(jq -r '.harvest.themeSignal.attr' "$CONFIG")" = "data-theme" ]
}

@test "connect: a bare file id is used as-is" {
    run python3 "$LIB" --repo "$REPO" --source src/styles/tokens.css --file MYBAREID123
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.fileId')" = "MYBAREID123" ]
}

@test "connect: media-query convention writes the right themeConvention + signal" {
    run python3 "$LIB" --repo "$REPO" --source src/styles/tokens.css \
        --convention media-query --query '(prefers-color-scheme: dark)' --file abc
    [ "$status" -eq 0 ]
    [ "$(jq -r '.themeConventions[0].type' "$CONFIG")" = "media-query" ]
    [ "$(jq -r '.themeConventions[0].query' "$CONFIG")" = "(prefers-color-scheme: dark)" ]
    [ "$(jq -r '.harvest.themeSignal.type' "$CONFIG")" = "media-query" ]
}

# ============================================================================
# Safety — refuse to clobber, unless --force; require exactly one target
# ============================================================================

@test "connect: refuses to overwrite an existing config without --force" {
    python3 "$LIB" --repo "$REPO" --source src/styles/tokens.css --file first > /dev/null
    # error paths log to stderr; drop it so $output is pure JSON.
    run bash -c "python3 '$LIB' --repo '$REPO' --source src/styles/tokens.css --file second 2>/dev/null"
    [ "$status" -eq 3 ]
    [ "$(echo "$output" | jq -r '.error')" = "config_exists" ]
    # the original file id is untouched
    [ "$(jq -r '.fileId' "$CONFIG")" = "first" ]
}

@test "connect: --force overwrites an existing config" {
    python3 "$LIB" --repo "$REPO" --source src/styles/tokens.css --file first > /dev/null
    run python3 "$LIB" --repo "$REPO" --source src/styles/tokens.css --file second --force
    [ "$status" -eq 0 ]
    [ "$(jq -r '.fileId' "$CONFIG")" = "second" ]
}

@test "connect: neither --file nor --create-file is a bad_target error" {
    run bash -c "python3 '$LIB' --repo '$REPO' --source src/styles/tokens.css 2>/dev/null"
    [ "$status" -eq 2 ]
    [ "$(echo "$output" | jq -r '.error')" = "bad_target" ]
}

@test "connect: both --file and --create-file is a bad_target error" {
    run bash -c "python3 '$LIB' --repo '$REPO' --source src/styles/tokens.css --file abc --create-file 2>/dev/null"
    [ "$status" -eq 2 ]
    [ "$(echo "$output" | jq -r '.error')" = "bad_target" ]
}

# ============================================================================
# Create-file path — the new file's id comes from the daemon (faked here)
# ============================================================================

@test "connect: --create-file captures the id from a create_file envelope" {
    run python3 -c "
import sys; sys.path.insert(0, '$LIB_DIR')
import connect
class FakeClient:
    def create_file(self, name=None):
        return {'ok': True, 'result': {'fileId': 'CREATED999'}}
conv = connect._convention('data-attribute', 'data-theme', 'dark', None)
report, code = connect.run(
    repo='$REPO', source_path='src/styles/tokens.css', convention=conv,
    create=True, create_name='My Design', client=FakeClient())
assert code == 0, (report, code)
assert report['fileId'] == 'CREATED999', report
assert report['created'] is True, report
import json, os
cfg = json.load(open(os.path.join('$REPO', 'token-bridge.config.json')))
assert cfg['fileId'] == 'CREATED999', cfg
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "connect: extract_file_id handles URL and bare id" {
    run python3 -c "
import sys; sys.path.insert(0, '$LIB_DIR')
import connect
assert connect.extract_file_id('https://app.paper.design/file/01XYZ/2-3') == '01XYZ'
assert connect.extract_file_id('01XYZ') == '01XYZ'
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}
