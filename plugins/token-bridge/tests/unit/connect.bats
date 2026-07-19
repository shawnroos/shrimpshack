#!/usr/bin/env bats
# Unit tests for lib/connect.py — scaffold <repo>/token-bridge.config.json binding
# a codebase to a Paper file (reference an existing file, or create a new one).

setup() {
    SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    LIB="$SCRIPT_DIR/lib/connect.py"
    LIB_DIR="$SCRIPT_DIR/lib"
    # Per-test dir, not the shared $BATS_TMPDIR: a concurrent bats run wipes a
    # shared repo path in its own setup() and this suite fails mid-test.
    REPO="$BATS_TEST_TMPDIR/connect_repo"
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
    # This source declares no custom properties, so R13's prefix warning goes to
    # stderr; drop it so $output is pure JSON.
    run bash -c "python3 '$LIB' --repo '$REPO' --source src/styles/tokens.css --file MYBAREID123 2>/dev/null"
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

@test "connect: extract_file_id handles URL and bare id, rejects a URL with no /file/<id>" {
    run python3 -c "
import sys; sys.path.insert(0, '$LIB_DIR')
import connect
assert connect.extract_file_id('https://app.paper.design/file/01XYZ/2-3') == '01XYZ'
assert connect.extract_file_id('01XYZ') == '01XYZ'
# URL-shaped but no /file/<id>: return '' so the caller rejects it
assert connect.extract_file_id('https://app.paper.design/files/ABC/edit') == ''
assert connect.extract_file_id('https://app.paper.design/file/') == ''
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "connect: a URL with no resolvable id is rejected at connect time (bad_file_ref)" {
    run bash -c "python3 '$LIB' --repo '$REPO' --source src/styles/tokens.css --file 'https://app.paper.design/files/ABC/edit' 2>/dev/null"
    [ "$status" -eq 2 ]
    [ "$(echo "$output" | jq -r '.error')" = "bad_file_ref" ]
    # no config was written
    [ ! -f "$CONFIG" ]
}

# ============================================================================
# Class convention (R1/R11) — scoped-class themes are a first-class convention
# ============================================================================

@test "connect: class convention writes the class themeConvention" {
    run python3 "$LIB" --repo "$REPO" --source src/styles/tokens.css \
        --convention class --class wcs-dark --file abc
    [ "$status" -eq 0 ]
    [ "$(jq -r '.themeConventions[0].type' "$CONFIG")" = "class" ]
    [ "$(jq -r '.themeConventions[0].class' "$CONFIG")" = "wcs-dark" ]
    [ "$(jq -r '.themeConventions[0].primary' "$CONFIG")" = "true" ]
}

# The silent trap: a class convention used to fall through to the data-attribute
# return in _theme_signal and raise KeyError: 'attr' while writing the config.
@test "connect: class convention writes a class harvest themeSignal (no KeyError)" {
    run python3 "$LIB" --repo "$REPO" --source src/styles/tokens.css \
        --convention class --class wcs-dark --file abc
    [ "$status" -eq 0 ]
    [ "$(jq -r '.harvest.themeSignal.type' "$CONFIG")" = "class" ]
    [ "$(jq -r '.harvest.themeSignal.class' "$CONFIG")" = "wcs-dark" ]
    # and no stray data-attribute fields leaked into the signal
    [ "$(jq -r '.harvest.themeSignal.attr // "absent"' "$CONFIG")" = "absent" ]
}

@test "connect: --convention class with no --class is an actionable exit 2" {
    run bash -c "python3 '$LIB' --repo '$REPO' --source src/styles/tokens.css --convention class --file abc 2>/dev/null"
    [ "$status" -eq 2 ]
    [ "$(echo "$output" | jq -r '.error')" = "bad_convention" ]
    [[ "$(echo "$output" | jq -r '.note')" == *"--class"* ]]
    [ ! -f "$CONFIG" ]
}

# ============================================================================
# R13 — a scaffolded config owns only its own namespace, never the whole file
# ============================================================================

@test "connect: R13 infers a dominant prefix from the source's own properties" {
    local repo="$BATS_TEST_TMPDIR/r13_dominant"
    mkdir -p "$repo/src"
    cat > "$repo/src/tokens.css" <<'CSS'
:root {
  --brand-bg: #fff;
  --brand-fg: #000;
  --brand-accent: #37D895;
}
CSS
    run python3 "$LIB" --repo "$repo" --source src/tokens.css --file abc
    [ "$status" -eq 0 ]
    [ "$(jq -r '.source.prefix' "$repo/token-bridge.config.json")" = "--brand-" ]
    [ "$(echo "$output" | jq -r '.prefixSource')" = "inferred" ]
}

@test "connect: R13 an explicit --prefix is used verbatim, never inferred over" {
    local repo="$BATS_TEST_TMPDIR/r13_explicit"
    mkdir -p "$repo/src"
    cat > "$repo/src/tokens.css" <<'CSS'
:root { --brand-bg: #fff; --brand-fg: #000; }
CSS
    run python3 "$LIB" --repo "$repo" --source src/tokens.css --prefix=--wcs- --file abc
    [ "$status" -eq 0 ]
    [ "$(jq -r '.source.prefix' "$repo/token-bridge.config.json")" = "--wcs-" ]
    [ "$(echo "$output" | jq -r '.prefixSource')" = "explicit" ]
}

@test "connect: R13 no inferable prefix warns loudly, naming whole-file ownership" {
    local repo="$BATS_TEST_TMPDIR/r13_nodominant"
    mkdir -p "$repo/src"
    cat > "$repo/src/tokens.css" <<'CSS'
:root {
  --alpha-one: 1px;
  --beta-two: 2px;
  --gamma-three: 3px;
  --delta-four: 4px;
}
CSS
    # stderr carries the loud warning; capture both streams
    run bash -c "python3 '$LIB' --repo '$repo' --source src/tokens.css --file abc 2>&1"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ENTIRE Paper file"* ]]
    [[ "$output" == *"--prefix"* ]]
    # it still scaffolds (null prefix stays legal), but says so out loud
    [ "$(jq -r '.source.prefix' "$repo/token-bridge.config.json")" = "null" ]
    run bash -c "python3 '$LIB' --repo '$repo' --source src/tokens.css --file abc --force 2>/dev/null"
    [ "$(echo "$output" | jq -r '.prefixSource')" = "none" ]
    [[ "$(echo "$output" | jq -r '.prefixWarning')" == *"ENTIRE Paper file"* ]]
}

@test "connect: R13 a missing source file cannot infer, and warns rather than guessing" {
    local repo="$BATS_TEST_TMPDIR/r13_missing"
    mkdir -p "$repo"
    run bash -c "python3 '$LIB' --repo '$repo' --source src/nope.css --file abc 2>/dev/null"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.prefixSource')" = "none" ]
    [ "$(jq -r '.source.prefix' "$repo/token-bridge.config.json")" = "null" ]
}

# Backward-compat guard: the change is scaffolding-time ONLY. A 1.0.0 config that
# already carries "prefix": null must still load and still reconcile whole-file.
@test "connect: R13 an existing null-prefix config still loads and syncs" {
    run python3 -c "
import sys; sys.path.insert(0, '$LIB_DIR')
import json, os
import paper_client, sync_tokens
repo = '$BATS_TEST_TMPDIR/r13_legacy'
os.makedirs(repo, exist_ok=True)
cfg = {'fileId': 'LEGACY1', 'paperDaemonUrl': 'http://127.0.0.1:29979/mcp',
       'source': {'path': 'tokens.css', 'ref': None, 'prefix': None},
       'emitTarget': 'tokens.generated.css', 'primitivePattern': None,
       'themeConventions': [{'type': 'data-attribute', 'attr': 'data-theme', 'value': 'dark', 'primary': True}],
       'harvest': {'themeSignal': {'type': 'data-attribute', 'attr': 'data-theme', 'value': 'dark'}, 'batch': []}}
open(os.path.join(repo, 'token-bridge.config.json'), 'w').write(json.dumps(cfg))
file_id, loaded, err = paper_client.read_config(repo)
assert err is None, err
assert file_id == 'LEGACY1', file_id
assert loaded['source']['prefix'] is None, loaded
# a null prefix still means whole-file ownership at READ time
assert sync_tokens._owns('--anything-at-all', None) is True
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

# Regression guard: the published data-attribute and media-query shapes are
# byte-identical apart from the new prefix default.
@test "connect: existing data-attribute + media-query configs are unchanged" {
    local repo="$BATS_TEST_TMPDIR/regress"
    mkdir -p "$repo/src/styles"
    touch "$repo/src/styles/tokens.css"

    python3 "$LIB" --repo "$repo" --source src/styles/tokens.css --prefix=--brand- --file abc > /dev/null 2>&1
    run jq -S -c . "$repo/token-bridge.config.json"
    [ "$output" = '{"emitTarget":"src/styles/tokens.generated.css","fileId":"abc","harvest":{"batch":[],"themeSignal":{"attr":"data-theme","type":"data-attribute","value":"dark"}},"paperDaemonUrl":"http://127.0.0.1:29979/mcp","primitivePattern":null,"source":{"path":"src/styles/tokens.css","prefix":"--brand-","ref":null},"themeConventions":[{"attr":"data-theme","primary":true,"type":"data-attribute","value":"dark"}]}' ]

    python3 "$LIB" --repo "$repo" --source src/styles/tokens.css --prefix=--brand- --file abc --force \
        --convention media-query --query '(prefers-color-scheme: dark)' > /dev/null 2>&1
    run jq -S -c '.themeConventions[0], .harvest.themeSignal' "$repo/token-bridge.config.json"
    [ "$(echo "$output" | head -1)" = '{"primary":true,"query":"(prefers-color-scheme: dark)","type":"media-query"}' ]
    [ "$(echo "$output" | tail -1)" = '{"query":"(prefers-color-scheme: dark)","type":"media-query"}' ]
}
