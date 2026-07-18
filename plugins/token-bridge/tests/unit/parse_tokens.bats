#!/usr/bin/env bats
# Unit tests for lib/parse_tokens.py — the config-driven theme-scope resolver.
# Covers: data-attribute + media-query conventions, base anchoring to the
# top-level :root, brace-aware @media descent, the carried alias-flip and
# idempotency invariants, the both-conventions disagreement warning, and the
# prefix filter.

setup() {
    SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    LIB="$SCRIPT_DIR/lib/parse_tokens.py"
    FIXTURE_DIR="$SCRIPT_DIR/tests/fixtures"

    DATAATTR="$FIXTURE_DIR/tokens_dataattr.css"
    MEDIAQUERY="$FIXTURE_DIR/tokens_mediaquery.css"
    BOTH="$FIXTURE_DIR/tokens_both.css"
    MULTIROOT="$FIXTURE_DIR/tokens_multiroot.css"

    CONV_DATAATTR='[{"type":"data-attribute","attr":"data-theme","value":"dark"}]'
    CONV_MEDIAQUERY='[{"type":"media-query","query":"(prefers-color-scheme: dark)"}]'
    CONV_BOTH='[{"type":"data-attribute","attr":"data-theme","value":"dark","primary":true},{"type":"media-query","query":"(prefers-color-scheme: dark)"}]'
}

# helper: field of the record with a given name (reads $output)
field() { # <name> <field>
    echo "$output" | jq -r --arg n "$1" --arg f "$2" '.[] | select(.name==$n) | .[$f]'
}

# helper: run the CLI over a fixture with a conventions arg (+ optional --prefix)
run_parse() { # <fixture> <conventions-json> [--prefix <p>]
    local fixture="$1" conv="$2"
    shift 2
    run bash -c "cat '$fixture' | python3 '$LIB' --conventions '$conv' $*"
}

# ============================================================================
# data-attribute happy path — distinct base/dark effective values
# ============================================================================

@test "data-attribute: :root + [data-theme=dark] resolve distinct base/dark" {
    run_parse "$DATAATTR" "$CONV_DATAATTR"
    [ "$status" -eq 0 ]
    [ "$(field --brand-accent light)" = "#37D895" ]
    [ "$(field --brand-accent dark)" = "#00B72B" ]
    # alias in base, literal in dark
    [ "$(field --brand-accent light_alias)" = "--brand-green-500" ]
    [ "$(field --brand-accent dark_alias)" = "null" ]
}

@test "data-attribute: rgba() internal commas survive intact" {
    run_parse "$DATAATTR" "$CONV_DATAATTR"
    [ "$status" -eq 0 ]
    [ "$(field --brand-lasso-fill light)" = "rgba(55, 216, 149, 0.18)" ]
    [ "$(field --brand-lasso-fill dark)" = "rgba(136, 200, 46, 0.16)" ]
}

# ============================================================================
# alias-flip — the invariant carried from the WCS parser
# ============================================================================

@test "alias-flip: base alias whose referent flips in dark is theme-varying" {
    run_parse "$DATAATTR" "$CONV_DATAATTR"
    [ "$status" -eq 0 ]
    [ "$(field --brand-playhead light)" = "#37D895" ]
    [ "$(field --brand-playhead dark)" = "#00B72B" ]
    [ "$(field --brand-playhead dark)" != "null" ]
    [ "$(field --brand-playhead light_alias)" = "--brand-accent" ]
}

@test "non-flipping alias: referent never redeclared in dark is theme-invariant" {
    run_parse "$DATAATTR" "$CONV_DATAATTR"
    [ "$status" -eq 0 ]
    [ "$(field --brand-warn-text light)" = "#C67700" ]
    [ "$(field --brand-warn-text dark)" = "null" ]
    [ "$(field --brand-warn-text light_alias)" = "--brand-amber-text" ]
}

@test "theme-invariant primitive has null dark" {
    run_parse "$DATAATTR" "$CONV_DATAATTR"
    [ "$status" -eq 0 ]
    [ "$(field --brand-space-2 light)" = "8px" ]
    [ "$(field --brand-space-2 dark)" = "null" ]
}

# ============================================================================
# media-query happy path — parser descends the @media block (brace-aware)
# ============================================================================

@test "media-query: :root + @media dark :root resolve distinct base/dark" {
    run_parse "$MEDIAQUERY" "$CONV_MEDIAQUERY"
    [ "$status" -eq 0 ]
    [ "$(field --brand-accent light)" = "#37D895" ]
    [ "$(field --brand-accent dark)" = "#00B72B" ]
}

@test "media-query brace-aware: only the inner :root is read, not the .foo decoy" {
    run_parse "$MEDIAQUERY" "$CONV_MEDIAQUERY"
    [ "$status" -eq 0 ]
    # #00B72B is from the media :root; #FF0000 is the .foo decoy that must be ignored
    [ "$(field --brand-accent dark)" = "#00B72B" ]
    [ "$(field --brand-accent dark)" != "#FF0000" ]
}

# ============================================================================
# base anchoring — top-level :root only; nested/@media/attribute :root are not base
# ============================================================================

@test "base anchoring: base is the top-level :root, not nested/@media/attribute :root" {
    run_parse "$MULTIROOT" "$CONV_DATAATTR"
    [ "$status" -eq 0 ]
    # base = top-level :root (#aaaaaa), NOT the @media :root (#bbbbbb)
    [ "$(field --brand-x light)" = "#AAAAAA" ]
    # dark = :root[data-theme="dark"] (#cccccc), matched by the data-attribute conv
    [ "$(field --brand-x dark)" = "#CCCCCC" ]
}

# ============================================================================
# both conventions — disagreeing dark values warn; primary wins
# ============================================================================

@test "both-conventions: disagreeing dark values warn (via diagnostics), primary wins" {
    run python3 -c "
import sys, json
sys.path.insert(0, '$SCRIPT_DIR/lib')
import parse_tokens
text = open('$BOTH').read()
conv = json.loads('$CONV_BOTH')
res = parse_tokens.parse_with_diagnostics(text, conv)
assert res['warnings'], 'expected at least one warning'
assert any('--brand-accent' in w for w in res['warnings']), res['warnings']
acc = [t for t in res['tokens'] if t['name'] == '--brand-accent'][0]
assert acc['dark'] == '#00B72B', 'primary (data-attribute) value expected, got %r' % acc['dark']
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *OK* ]]
}

@test "both-conventions: warning is also observable on stderr" {
    run_parse "$BOTH" "$CONV_BOTH"
    [ "$status" -eq 0 ]
    # bats merges stderr into $output; the _log warning must be visible
    [[ "$output" == *"--brand-accent"* ]]
    [[ "$output" == *"differs"* ]]
}

# ============================================================================
# prefix filter
# ============================================================================

@test "prefix filter: a prefix includes only matching custom properties" {
    # value starts with '-', so the =form is required (argparse rejects it as a flag otherwise)
    run_parse "$DATAATTR" "$CONV_DATAATTR" --prefix=--brand-
    [ "$status" -eq 0 ]
    # unprefixed --other-thing is excluded
    [ "$(echo "$output" | jq -r '[.[] | select(.name=="--other-thing")] | length')" = "0" ]
    # prefixed props remain
    [ "$(echo "$output" | jq -r '[.[] | select(.name=="--brand-accent")] | length')" = "1" ]
}

@test "prefix filter: no prefix includes all custom properties" {
    run_parse "$DATAATTR" "$CONV_DATAATTR"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '[.[] | select(.name=="--other-thing")] | length')" = "1" ]
    [ "$(field --other-thing light)" = "#123456" ]
}

# ============================================================================
# idempotency + normalization
# ============================================================================

@test "output is valid JSON, sorted, names lowercased, hex uppercased" {
    run_parse "$DATAATTR" "$CONV_DATAATTR"
    [ "$status" -eq 0 ]
    echo "$output" | jq . > /dev/null
    # sorted by name
    sorted=$(echo "$output" | jq -r '[.[].name] == ([.[].name] | sort)')
    [ "$sorted" = "true" ]
    [[ "$output" == *'"#37D895"'* ]]
    [[ "$output" != *'"#37d895"'* ]]
}

@test "idempotent — two runs are byte-identical" {
    one=$(cat "$DATAATTR" | python3 "$LIB" --conventions "$CONV_DATAATTR")
    two=$(cat "$DATAATTR" | python3 "$LIB" --conventions "$CONV_DATAATTR")
    [ "$one" = "$two" ]
    [[ "$one" == *'"--brand-accent"'* ]]
}

# ============================================================================
# media-query EXACT match — a compound @media that merely CONTAINS the config
# query is a different scope and must NOT be grabbed as the dark scope.
# ============================================================================

@test "media-query: a compound @media is not mistaken for the bare dark query" {
    src="$BATS_TMPDIR/compound.css"
    cat > "$src" <<'CSS'
:root { --brand-bg: #ffffff; }
@media (prefers-color-scheme: dark) and (min-width: 900px) {
  :root { --brand-bg: #101010; }
}
CSS
    run bash -c "cat '$src' | python3 '$LIB' --conventions '$CONV_MEDIAQUERY'"
    [ "$status" -eq 0 ]
    # The compound scope is NOT the dark scope: bg stays base-only (dark null).
    [ "$(field --brand-bg light)" = "#FFFFFF" ]
    [ "$(field --brand-bg dark)" = "null" ]
}

@test "media-query: colon-spacing differences still match (whitespace-insensitive)" {
    src="$BATS_TMPDIR/spacing.css"
    # Source omits the space after the colon that the config query carries.
    cat > "$src" <<'CSS'
:root { --brand-bg: #ffffff; }
@media (prefers-color-scheme:dark) { :root { --brand-bg: #101010; } }
CSS
    run bash -c "cat '$src' | python3 '$LIB' --conventions '$CONV_MEDIAQUERY'"
    [ "$status" -eq 0 ]
    [ "$(field --brand-bg dark)" = "#101010" ]
}

# ============================================================================
# Prefix dangling-alias warning — an included token that aliases a referent the
# prefix filter EXCLUDED warns (Paper would drop the dangling var reference).
# ============================================================================

@test "prefix: an alias to a referent outside the prefix warns on stderr" {
    src="$BATS_TMPDIR/dangling.css"
    cat > "$src" <<'CSS'
:root {
  --color-green-500: #37d895;
  --brand-accent: var(--color-green-500);
}
CSS
    err="$BATS_TMPDIR/dangling.stderr"
    run bash -c "cat '$src' | python3 '$LIB' --conventions '$CONV_DATAATTR' --prefix=--brand- 2>'$err'"
    [ "$status" -eq 0 ]
    # only the prefixed token is emitted
    [ "$(field --brand-accent light_alias)" = "--color-green-500" ]
    [ "$(echo "$output" | jq 'length')" -eq 1 ]
    # and a dangling-alias warning was logged
    grep -q 'outside the prefix filter' "$err"
    grep -q -- '--color-green-500' "$err"
}

# ============================================================================
# Public seam — sibling modules depend on these re-exported names.
# ============================================================================

@test "public seam: VAR_ALIAS_RE / normalize_hex / primary_convention are exported" {
    run python3 -c "
import sys; sys.path.insert(0, '$SCRIPT_DIR/lib')
import parse_tokens as p
assert p.VAR_ALIAS_RE.match('var(--x)'), 'VAR_ALIAS_RE'
assert p.normalize_hex('#abc123') == '#ABC123', p.normalize_hex('#abc123')
conv = [{'type':'data-attribute','attr':'data-theme','value':'dark','primary':True}]
assert p.primary_convention(conv)['type'] == 'data-attribute'
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == OK* ]]
}
