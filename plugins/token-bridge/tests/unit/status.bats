#!/usr/bin/env bats
# Unit tests for lib/status.py — read-only bidirectional drift between a
# codebase's tokens and its connected Paper file.

setup() {
    SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    LIB="$SCRIPT_DIR/lib/status.py"
    LIB_DIR="$SCRIPT_DIR/lib"
    FIXTURE_DIR="$SCRIPT_DIR/tests/fixtures"
    SOURCE="$FIXTURE_DIR/reconcile_source.css"
    CONV='[{"type":"data-attribute","attr":"data-theme","value":"dark","primary":true}]'
}

# ============================================================================
# drift buckets — onlyInCode / onlyInDesign / differ, prefix-scoped
# ============================================================================

@test "status: drift reports the three buckets, prefix-scoped, never counting foreign tokens" {
    run python3 -c "
import sys; sys.path.insert(0, '$LIB_DIR')
import status
desired = [
  {'name':'--brand-accent','type':'color','value':'#37D895'},
  {'name':'--brand-new','type':'color','value':'#111111'},
]
live = [
  {'name':'--brand-accent','type':'color','value':'#000000'},  # differs
  {'name':'--brand-gone','type':'color','value':'#222222'},     # only in design (owned)
  {'name':'--color-native','type':'color','value':'#333333'},   # FOREIGN, must be ignored
]
d = status.drift(desired, live, owned_prefix='--brand-')
assert d['onlyInCode'] == ['--brand-new'], d
assert d['onlyInDesign'] == ['--brand-gone'], d
assert d['differ'] == ['--brand-accent'], d
assert d['inSync'] is False
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "status: identical code and design report inSync with empty buckets" {
    run python3 -c "
import sys; sys.path.insert(0, '$LIB_DIR')
import status
toks = [{'name':'--brand-accent','type':'color','value':'#37D895'}]
d = status.drift(toks, toks, owned_prefix='--brand-')
assert d['inSync'] is True, d
assert d['onlyInCode'] == [] and d['onlyInDesign'] == [] and d['differ'] == [], d
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

# ============================================================================
# drift CLI over injected source + live files (the offline path)
# ============================================================================

@test "status: the drift CLI computes buckets from source + live fixtures" {
    echo '[{"name":"--brand-accent","type":"color","value":"#37D895"}]' > "$BATS_TMPDIR/st_live.json"
    run python3 "$LIB" drift --source-file "$SOURCE" --conventions "$CONV" \
        --live-file "$BATS_TMPDIR/st_live.json" --prefix=--brand-
    [ "$status" -eq 0 ]
    # source defines many --brand-* tokens the live file lacks -> onlyInCode non-empty
    [ "$(echo "$output" | jq '.onlyInCode | length')" -gt 0 ]
    [ "$(echo "$output" | jq -r '.inSync')" = "false" ]
}

# ============================================================================
# Safety — no config under --repo refuses, reads nothing live
# ============================================================================

@test "status: run --repo with no config refuses (no_config)" {
    repo="$BATS_TMPDIR/status_no_config"
    mkdir -p "$repo"
    run bash -c "python3 '$LIB' run --repo '$repo' 2>/dev/null"
    [ "$status" -eq 2 ]
    [ "$(echo "$output" | jq -r '.refused')" = "true" ]
    [ "$(echo "$output" | jq -r '.error')" = "no_config" ]
}

@test "status: _tokens_from tolerates a bare array, {tokens:[]}, and a result envelope" {
    run python3 -c "
import sys; sys.path.insert(0, '$LIB_DIR')
import status
bare = [{'name':'--x','type':'color','value':'#000'}]
assert status._tokens_from(bare) == bare
assert status._tokens_from({'tokens': bare}) == bare
assert status._tokens_from({'result': {'tokens': bare}}) == bare
assert status._tokens_from(None) == []
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "status: run() uses _tokens_from so a bare-array daemon payload does not crash" {
    repo="$BATS_TMPDIR/status_barelist"
    mkdir -p "$repo/styles"
    printf ':root { --brand-x: #000000; }\n' > "$repo/styles/tokens.css"
    cat > "$repo/token-bridge.config.json" <<'JSON'
{ "fileId": "f", "source": { "path": "styles/tokens.css", "prefix": "--brand-" },
  "themeConventions": [ { "type": "data-attribute", "attr": "data-theme", "value": "dark", "primary": true } ] }
JSON
    run python3 -c "
import sys; sys.path.insert(0, '$LIB_DIR')
import status
class FakeClient:
    def get_tokens(self, fid):
        # daemon returns a BARE array (not {tokens:[]}) — must not crash
        return {'ok': True, 'result': [{'name':'--brand-x','type':'color','value':'#000000'}]}
report, code = status.run(repo='$repo', client=FakeClient())
assert code == 0, (report, code)
assert report['ok'] is True and report['inSync'] is True, report
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}
