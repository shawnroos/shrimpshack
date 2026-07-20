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
    CLASS="$FIXTURE_DIR/tokens_class.css"
    NESTED_SCOPE="$FIXTURE_DIR/tokens_nested_scope.css"
    NESTED="$FIXTURE_DIR/tokens_nested.css"

    CONV_DATAATTR='[{"type":"data-attribute","attr":"data-theme","value":"dark"}]'
    CONV_MEDIAQUERY='[{"type":"media-query","query":"(prefers-color-scheme: dark)"}]'
    CONV_BOTH='[{"type":"data-attribute","attr":"data-theme","value":"dark","primary":true},{"type":"media-query","query":"(prefers-color-scheme: dark)"}]'
    CONV_CLASS='[{"type":"class","class":"wcs-dark"}]'
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

# helper: run_parse with stderr dropped, so $output is pure JSON. Needed for a
# fixture that deliberately WARNS (bats merges stderr into $output, and the
# merged text is not valid JSON for jq). A redirect cannot be passed as an
# argument to run_parse — the shell would apply it to the function call itself.
run_parse_quiet() { # <fixture> <conventions-json> [--prefix <p>]
    local fixture="$1" conv="$2"
    shift 2
    run bash -c "cat '$fixture' | python3 '$LIB' --conventions '$conv' $* 2>/dev/null"
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

@test "prefix: an alias to an UNDECLARED referent (no prefix) warns accurately, not about a prefix" {
    src="$BATS_TMPDIR/undeclared.css"
    cat > "$src" <<'CSS'
:root { --a: var(--undefined-x); }
CSS
    err="$BATS_TMPDIR/undeclared.stderr"
    # No --prefix at all: the cause is an undeclared referent, not a filter.
    run bash -c "cat '$src' | python3 '$LIB' --conventions '$CONV_DATAATTR' 2>'$err'"
    [ "$status" -eq 0 ]
    grep -q 'is not declared in the source' "$err"
    # must NOT claim a (None) prefix filter or advise widening it
    ! grep -q 'prefix filter (None)' "$err"
    ! grep -q 'Widen the prefix' "$err"
}

# ============================================================================
# Public seam — sibling modules depend on these re-exported names.
# ============================================================================

# ============================================================================
# U2 — scope-context predicate engine.
#
# The parser walks the stylesheet recursively, carrying the enclosing at-rule
# chain as context, and accumulates EVERY block whose context satisfies a
# convention's predicates. Covers: the class predicate and its boundary rule
# (KTD4), conjunction, at-rule descent, at-rule conditionality (KTD5), and
# multi-block accumulation.
# ============================================================================

# --- class predicate (R1, KTD4) ---------------------------------------------

@test "class: .wcs-dark resolves the dark scope; base stays the bare :root" {
    run_parse "$CLASS" "$CONV_CLASS"
    [ "$status" -eq 0 ]
    [ "$(field --brand-accent light)" = "#37D895" ]
    [ "$(field --brand-accent dark)" = "#00B72B" ]
    [ "$(field --brand-accent light_alias)" = "--brand-green-500" ]
}

@test "class boundary: .wcs-darker and .wcs-dark-alt do NOT match .wcs-dark" {
    run_parse "$CLASS" "$CONV_CLASS"
    [ "$status" -eq 0 ]
    # #FF0000 lives only in the two boundary decoys; neither may be read.
    [[ "$output" != *"#FF0000"* ]]
    [ "$(field --brand-accent dark)" = "#00B72B" ]
}

@test "class boundary: an escaped-identifier selector (.dark\\:x) does NOT match .dark" {
    # Tailwind v4's default darkMode class IS literally `dark`, so a bundled
    # stylesheet is full of `.dark\:*` utilities. A CSS identifier escape
    # continues the same identifier — matching it would read every one of those
    # utility rules as the dark scope.
    run python3 -c "
import sys; sys.path.insert(0, '$SCRIPT_DIR/lib')
import parse_tokens as pt
assert pt._match_selector_predicate({'class': 'dark'}, r'.dark\:text-white') is False
assert pt._match_selector_predicate({'class': 'dark'}, r'.foo\.dark') is False
assert pt._match_selector_predicate({'class': 'dark'}, '.dark') is True
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == OK* ]]
}

@test "class boundary: the class string inside a quoted attribute value does NOT match" {
    run python3 -c "
import sys; sys.path.insert(0, '$SCRIPT_DIR/lib')
import parse_tokens as pt
assert pt._match_selector_predicate({'class': 'dark'}, 'a[href\$=\".dark\"]') is False
# ...but a REAL class alongside a decoy attribute value still matches.
assert pt._match_selector_predicate({'class': 'dark'}, '[data-x=\".dark\"].dark') is True
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == OK* ]]
}

@test "class compound forms: html.wcs-dark, .wcs-dark:hover, and a group member match" {
    run_parse "$CLASS" "$CONV_CLASS"
    [ "$status" -eq 0 ]
    [ "$(field --brand-bg dark)" = "#101010" ]    # html.wcs-dark
    [ "$(field --brand-fg dark)" = "#EEEEEE" ]    # .wcs-dark:hover
    [ "$(field --brand-ring dark)" = "#444444" ]  # `.wcs-dark, .other-scope`
}

@test "class: :root.wcs-dark matches the class but is NOT mistaken for the base" {
    src="$BATS_TMPDIR/rootclass.css"
    cat > "$src" <<'CSS'
:root { --brand-bg: #ffffff; }
:root.wcs-dark { --brand-bg: #101010; }
CSS
    run bash -c "cat '$src' | python3 '$LIB' --conventions '$CONV_CLASS'"
    [ "$status" -eq 0 ]
    [ "$(field --brand-bg light)" = "#FFFFFF" ]
    [ "$(field --brand-bg dark)" = "#101010" ]
}

# --- conjunction (R2, KTD2) --------------------------------------------------
# The `match:[…]` form is INTERNAL (KTD2a) — exercised here at the engine level,
# not as a user-authored config surface.

@test "conjunction: two class predicates match body.wcs-theme.wcs-dark only when BOTH hold" {
    run python3 -c "
import sys, json
sys.path.insert(0, '$SCRIPT_DIR/lib')
import parse_tokens as p
conv = [{'match': [{'class': 'wcs-theme'}, {'class': 'wcs-dark'}]}]

def dark_of(css):
    recs = p.parse_tokens(css, conv)
    return [r for r in recs if r['name'] == '--brand-bg'][0]['dark']

both = ':root { --brand-bg: #ffffff; } body.wcs-theme.wcs-dark { --brand-bg: #101010; }'
assert dark_of(both) == '#101010', dark_of(both)
# Neither half alone satisfies the conjunction.
theme_only = ':root { --brand-bg: #ffffff; } body.wcs-theme { --brand-bg: #ff0000; }'
assert dark_of(theme_only) is None, dark_of(theme_only)
dark_only = ':root { --brand-bg: #ffffff; } body.wcs-dark { --brand-bg: #ff0000; }'
assert dark_of(dark_only) is None, dark_of(dark_only)
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *OK* ]]
}

@test "conjunction: predicates must hold on the SAME selector group member" {
    run python3 -c "
import sys
sys.path.insert(0, '$SCRIPT_DIR/lib')
import parse_tokens as p
conv = [{'match': [{'class': 'wcs-theme'}, {'class': 'wcs-dark'}]}]
# Each member carries one class; no single member carries both.
css = ':root { --brand-bg: #ffffff; } .wcs-theme, .wcs-dark { --brand-bg: #ff0000; }'
rec = [r for r in p.parse_tokens(css, conv) if r['name'] == '--brand-bg'][0]
assert rec['dark'] is None, rec
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *OK* ]]
}

@test "desugar: media-query becomes a two-predicate conjunction with the :root anchor" {
    run python3 -c "
import sys
sys.path.insert(0, '$SCRIPT_DIR/lib')
import parse_tokens as p
preds = p.desugar_convention({'type': 'media-query', 'query': '(prefers-color-scheme: dark)'})
assert len(preds) == 2, preds
assert {'media': '(prefers-color-scheme: dark)'} in preds, preds
assert {'selector': ':root'} in preds, preds
assert p.desugar_convention({'type': 'class', 'class': 'wcs-dark'}) == [{'class': 'wcs-dark'}]
assert p.desugar_convention(
    {'type': 'data-attribute', 'attr': 'data-theme', 'value': 'dark'}
) == [{'attr': 'data-theme', 'value': 'dark'}]
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *OK* ]]
}

# --- at-rule descent (R4, KTD5) ---------------------------------------------

@test "@layer is transparent: a bare :root inside @layer IS the base" {
    src="$BATS_TMPDIR/layer.css"
    cat > "$src" <<'CSS'
@layer tokens {
  :root { --brand-bg: #ffffff; }
}
[data-theme="dark"] { --brand-bg: #101010; }
CSS
    run bash -c "cat '$src' | python3 '$LIB' --conventions '$CONV_DATAATTR'"
    [ "$status" -eq 0 ]
    # Today this parses to a base of {} — the light value is silently lost.
    [ "$(field --brand-bg light)" = "#FFFFFF" ]
    [ "$(field --brand-bg dark)" = "#101010" ]
}

@test "@layer: a dark scope nested inside @layer resolves" {
    src="$BATS_TMPDIR/layer_dark.css"
    cat > "$src" <<'CSS'
:root { --brand-bg: #ffffff; }
@layer theme {
  .wcs-dark { --brand-bg: #101010; }
}
CSS
    run bash -c "cat '$src' | python3 '$LIB' --conventions '$CONV_CLASS'"
    [ "$status" -eq 0 ]
    [ "$(field --brand-bg dark)" = "#101010" ]
}

@test "@media wrapping a class dark scope resolves" {
    run_parse "$NESTED_SCOPE" "$CONV_CLASS"
    [ "$status" -eq 0 ]
    [ "$(field --brand-bg dark)" = "#101010" ]
}

@test "@supports wrapping a class dark scope resolves" {
    run_parse "$NESTED_SCOPE" "$CONV_CLASS"
    [ "$status" -eq 0 ]
    [ "$(field --brand-fg dark)" = "#EEEEEE" ]
}

# --- at-rule conditionality: the base guard (KTD5) --------------------------

@test "conditional at-rule base guard: a :root inside @media is never the base" {
    src="$BATS_TMPDIR/condbase.css"
    cat > "$src" <<'CSS'
:root { --brand-a: #ffffff; }
@media (prefers-color-scheme: dark) {
  :root { --brand-a: #000000; }
}
CSS
    run bash -c "cat '$src' | python3 '$LIB' --conventions '$CONV_DATAATTR'"
    [ "$status" -eq 0 ]
    # The light/dark inversion this plan exists to fix: base must stay #FFFFFF.
    [ "$(field --brand-a light)" = "#FFFFFF" ]
    [ "$(field --brand-a light)" != "#000000" ]
}

@test "conditional at-rule base guard holds on tokens_multiroot under BOTH conventions" {
    run_parse "$MULTIROOT" "$CONV_DATAATTR"
    [ "$status" -eq 0 ]
    [ "$(field --brand-x light)" = "#AAAAAA" ]
    [ "$(field --brand-x dark)" = "#CCCCCC" ]

    run_parse "$MULTIROOT" "$CONV_MEDIAQUERY"
    [ "$status" -eq 0 ]
    [ "$(field --brand-x light)" = "#AAAAAA" ]
    [ "$(field --brand-x dark)" = "#BBBBBB" ]
}

@test ":root anchor holds under a media convention: the .foo decoy is not the dark scope" {
    run_parse "$MEDIAQUERY" "$CONV_MEDIAQUERY"
    [ "$status" -eq 0 ]
    # .foo inside the dark @media declares --brand-accent: #ff0000. Without the
    # :root anchor in the desugared conjunction it would win as the dark scope.
    [ "$(field --brand-accent dark)" = "#00B72B" ]
    [[ "$output" != *"#FF0000"* ]]
}

# --- accumulation (R6) ------------------------------------------------------

@test "accumulate: two top-level :root blocks both contribute to the base" {
    src="$BATS_TMPDIR/tworoot.css"
    cat > "$src" <<'CSS'
:root { --brand-a: #ffffff; }
:root { --brand-b: #eeeeee; }
CSS
    run bash -c "cat '$src' | python3 '$LIB' --conventions '$CONV_DATAATTR'"
    [ "$status" -eq 0 ]
    # Today the second :root is silently dropped and --brand-b never appears.
    [ "$(echo "$output" | jq 'length')" -eq 2 ]
    [ "$(field --brand-a light)" = "#FFFFFF" ]
    [ "$(field --brand-b light)" = "#EEEEEE" ]
}

@test "accumulate: on a conflict across two base blocks the later declaration wins" {
    src="$BATS_TMPDIR/tworoot_conflict.css"
    cat > "$src" <<'CSS'
:root { --brand-a: #ffffff; }
:root { --brand-a: #dddddd; }
CSS
    run bash -c "cat '$src' | python3 '$LIB' --conventions '$CONV_DATAATTR'"
    [ "$status" -eq 0 ]
    [ "$(field --brand-a light)" = "#DDDDDD" ]
}

@test "accumulate: two matching dark blocks both contribute" {
    run_parse "$CLASS" "$CONV_CLASS"
    [ "$status" -eq 0 ]
    # .wcs-dark, html.wcs-dark and .wcs-dark:hover are three separate blocks.
    [ "$(field --brand-accent dark)" = "#00B72B" ]
    [ "$(field --brand-bg dark)" = "#101010" ]
    [ "$(field --brand-fg dark)" = "#EEEEEE" ]
}

@test "accumulate: a base :root inside @layer merges with a top-level :root" {
    run_parse "$NESTED_SCOPE" "$CONV_CLASS"
    [ "$status" -eq 0 ]
    [ "$(field --brand-bg light)" = "#FFFFFF" ]    # from @layer tokens
    [ "$(field --brand-accent light)" = "#37D895" ] # from the top-level :root
}

# --- backward compatibility (the top risk — 1.0.0 is published) -------------

@test "regression: existing fixtures parse byte-identically to the pre-change goldens" {
    run bash -c "cat '$DATAATTR' | python3 '$LIB' --conventions '$CONV_DATAATTR' 2>/dev/null"
    [ "$status" -eq 0 ]
    [ "$output" = "$(cat "$FIXTURE_DIR/golden_dataattr.json")" ]

    run bash -c "cat '$MEDIAQUERY' | python3 '$LIB' --conventions '$CONV_MEDIAQUERY' 2>/dev/null"
    [ "$status" -eq 0 ]
    [ "$output" = "$(cat "$FIXTURE_DIR/golden_mediaquery.json")" ]

    run bash -c "cat '$MULTIROOT' | python3 '$LIB' --conventions '$CONV_DATAATTR' 2>/dev/null"
    [ "$status" -eq 0 ]
    [ "$output" = "$(cat "$FIXTURE_DIR/golden_multiroot.json")" ]

    run bash -c "cat '$BOTH' | python3 '$LIB' --conventions '$CONV_BOTH' 2>/dev/null"
    [ "$status" -eq 0 ]
    [ "$output" = "$(cat "$FIXTURE_DIR/golden_both.json")" ]
}

@test "unknown convention type is still a loud ValueError" {
    run bash -c "cat '$DATAATTR' | python3 '$LIB' --conventions '[{\"type\":\"nonsense\"}]'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"nonsense"* ]]
}

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

# ============================================================================
# U4 / KTD6 — block-local declaration parsing under CSS/SCSS nesting.
#
# The inversion below is the headline defect: a wrong VALUE, not a missing one,
# so it sails past any smoke test that only checks the token exists.
# ============================================================================

@test "KTD6 inversion: a nested &[data-theme=dark] child does NOT overwrite the base value" {
    run_parse_quiet "$NESTED" "$CONV_DATAATTR"
    [ "$status" -eq 0 ]
    # pre-U4 this returned light="#000000" — the DARK value — and dark=null
    [ "$(field --brand-bg light)" = "#FFFFFF" ]
    [ "$(field --brand-bg dark)" = "#000000" ]
}

@test "KTD6: a nested child block's declarations never appear in the parent's set" {
    run_parse_quiet "$NESTED" "$CONV_DATAATTR"
    [ "$status" -eq 0 ]
    # `.brand-card` is neither the base nor the dark scope, so its declaration
    # is not a token at all — it used to leak into :root.
    [ "$(echo "$output" | jq -r '[.[] | select(.name=="--brand-card-only")] | length')" = "0" ]
}

@test "R9: the last declaration in a block with no trailing semicolon is captured" {
    run_parse_quiet "$NESTED" "$CONV_DATAATTR"
    [ "$status" -eq 0 ]
    [ "$(field --brand-last light)" = "4px" ]
}

@test "R9: fully minified CSS parses to exactly the same tokens as its pretty form" {
    pretty="$BATS_TMPDIR/u4_pretty.css"
    minified="$BATS_TMPDIR/u4_min.css"
    cat > "$pretty" <<'CSS'
:root {
  --brand-bg: #ffffff;
  --brand-fg: #111111;
}
[data-theme="dark"] {
  --brand-bg: #101010
}
CSS
    printf ':root{--brand-bg:#ffffff;--brand-fg:#111111}[data-theme="dark"]{--brand-bg:#101010}' > "$minified"

    run_parse "$pretty" "$CONV_DATAATTR"
    [ "$status" -eq 0 ]
    pretty_out="$output"

    run_parse "$minified" "$CONV_DATAATTR"
    [ "$status" -eq 0 ]
    [ "$output" = "$pretty_out" ]
    # and it is not the trivially-equal empty parse
    [ "$(echo "$output" | jq 'length')" = "2" ]
}

@test "R9: an underscore in a custom-property name is captured" {
    run_parse_quiet "$NESTED" "$CONV_DATAATTR"
    [ "$status" -eq 0 ]
    [ "$(field --brand_accent light)" = "#37D895" ]
}

@test "R9: a brace inside a quoted value is data, not a nested rule" {
    # A `{` in a string is legal CSS — an inline-SVG data URI carrying
    # `<style>.a{fill:red}</style>` is the realistic case. Treating it as the
    # start of a child block made the enclosing declaration VANISH from the
    # parse, and a token missing from a parse becomes a DELETE downstream.
    run bash -c "printf ':root{--template:\"{not a rule}\";--a:red;}' | python3 '$LIB' --conventions '$CONV_DATAATTR' 2>/dev/null"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '[.[] | select(.name=="--template")] | length')" = "1" ]
    [ "$(echo "$output" | jq -r '[.[] | select(.name=="--a")] | length')" = "1" ]
}

@test "R9: an inline-SVG data URI containing braces keeps its token" {
    run bash -c "printf ':root{--icon:url(\"data:image/svg+xml,<svg><style>.a{fill:red}</style></svg>\");--b:blue;}' | python3 '$LIB' --conventions '$CONV_DATAATTR' 2>/dev/null"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '[.[] | select(.name=="--icon")] | length')" = "1" ]
    [ "$(echo "$output" | jq -r '[.[] | select(.name=="--b")] | length')" = "1" ]
}

@test "R9: a stray ')' does NOT swallow later declarations (depth clamped at 0)" {
    # An unmatched `)` — `--a: red);` or the very ordinary `calc(100% - 10px))`
    # typo — drove paren depth negative, after which `;` stopped terminating the
    # value and every following declaration was eaten with NO warning. A token
    # missing from a parse becomes a DELETE downstream.
    run bash -c "printf ':root{--a:red);--b:blue;}' | python3 '$LIB' --conventions '$CONV_DATAATTR' 2>/dev/null"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '[.[] | select(.name=="--b")] | length')" = "1" ]

    run bash -c "printf ':root{--x:calc(100%% - 10px));--y:#fff;}' | python3 '$LIB' --conventions '$CONV_DATAATTR' 2>/dev/null"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '[.[] | select(.name=="--y")] | length')" = "1" ]
}

@test "R9: a stray ')' still WARNS even though the boundary is recovered" {
    run bash -c "printf ':root{--a:red);--b:blue;}' | python3 '$LIB' --conventions '$CONV_DATAATTR' 2>&1 >/dev/null"
    [[ "$output" == *"unmatched ')'"* ]]
}

@test "R9: legitimately nested parens are unaffected by the clamp" {
    run bash -c "printf ':root{--g:linear-gradient(rgba(0,0,0,.5),rgba(1,1,1,.5));--z:#000;}' | python3 '$LIB' --conventions '$CONV_DATAATTR' 2>/dev/null"
    [ "$status" -eq 0 ]
    [ "$(field --g light)" = "linear-gradient(rgba(0,0,0,.5),rgba(1,1,1,.5))" ]
    [ "$(echo "$output" | jq -r '[.[] | select(.name=="--z")] | length')" = "1" ]
}

@test "U5: a NESTED light-dark() warns rather than syncing a literal silently" {
    run bash -c "printf ':root{--n:light-dark(light-dark(#fff,#eee),#000);}' | python3 '$LIB' --conventions '$CONV_DATAATTR' 2>&1 >/dev/null"
    [[ "$output" == *"nested light-dark"* ]]
}

@test "R9: an unterminated string WARNS rather than silently eating later decls" {
    run bash -c "printf ':root{--a:\"unterminated\n--b:red;}' | python3 '$LIB' --conventions '$CONV_DATAATTR' 2>&1 >/dev/null"
    [[ "$output" == *"unterminated string"* ]]
    [[ "$output" == *"not read"* ]]
}

@test "R9: a data-URI value survives its internal semicolon intact" {
    run_parse_quiet "$NESTED" "$CONV_DATAATTR"
    [ "$status" -eq 0 ]
    [ "$(field --brand-icon light)" = 'url("data:image/svg+xml;utf8,<svg/>")' ]
}

@test "R9: !important is stripped from the value, so the token still classifies" {
    run_parse_quiet "$NESTED" "$CONV_DATAATTR"
    [ "$status" -eq 0 ]
    [ "$(field --brand-important light)" = "#FFF" ]
    # the point of stripping: classify_tokens must still see a clean color
    run python3 -c "
import sys; sys.path.insert(0, '$SCRIPT_DIR/lib')
import classify_tokens
t, why = classify_tokens.classify_value('--brand-important', '#FFF')
assert t == 'color', (t, why)
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == OK* ]]
}

@test "R9: var(--x, fallback) is recognized as an alias to --x" {
    run_parse_quiet "$NESTED" "$CONV_DATAATTR"
    [ "$status" -eq 0 ]
    [ "$(field --brand-alias light_alias)" = "--brand_accent" ]
    [ "$(field --brand-alias light)" = "#37D895" ]
}

@test "R9: the alias-flip invariant holds through a var() fallback form" {
    run_parse_quiet "$NESTED" "$CONV_DATAATTR"
    [ "$status" -eq 0 ]
    # --brand-flip aliases --brand-bg, which flips; so it flips too
    [ "$(field --brand-flip light)" = "#FFFFFF" ]
    [ "$(field --brand-flip dark)" = "#000000" ]
}

@test "R9: a discarded var() fallback WARNS rather than vanishing silently" {
    run bash -c "cat '$NESTED' | python3 '$LIB' --conventions '$CONV_DATAATTR' 2>&1 >/dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" == *"--brand-alias"* ]]
    [[ "$output" == *"#eee"* ]]
    [[ "$output" == *"fallback"* ]]
}

@test "R9: a var() alias with no fallback does NOT warn" {
    run bash -c "cat '$DATAATTR' | python3 '$LIB' --conventions '$CONV_DATAATTR' 2>&1 >/dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" != *"fallback"* ]]
}

@test "R9: a non-alias value containing var() is not mistaken for an alias" {
    src="$BATS_TMPDIR/u4_notalias.css"
    cat > "$src" <<'CSS'
:root {
  --brand-pair: var(--brand-a, #eee) var(--brand-b, #fff);
  --brand-a: #111111;
  --brand-b: #222222;
}
CSS
    run_parse_quiet "$src" "$CONV_DATAATTR"
    [ "$status" -eq 0 ]
    # two var()s side by side is a composite value, not an alias
    [ "$(field --brand-pair light_alias)" = "null" ]
    # kept whole (hex runs uppercased by the usual normalization)
    [ "$(field --brand-pair light)" = "var(--brand-a, #EEE) var(--brand-b, #FFF)" ]
}

# ============================================================================
# U5 / R10 / KTD9 — light-dark() resolves at parse into both record fields
# ============================================================================

@test "U5: light-dark() in base fills light AND dark with no dark scope declared" {
    src="$BATS_TEST_TMPDIR/u5_basic.css"
    cat > "$src" <<'CSS'
:root {
  --brand-bg: light-dark(#fff, #000);
}
CSS
    run_parse_quiet "$src" "$CONV_DATAATTR"
    [ "$status" -eq 0 ]
    [ "$(field --brand-bg light)" = "#FFF" ]
    [ "$(field --brand-bg dark)" = "#000" ]
}

@test "U5: light-dark() with nested functions splits on the TOP-LEVEL comma" {
    src="$BATS_TEST_TMPDIR/u5_nested_fn.css"
    cat > "$src" <<'CSS'
:root {
  --brand-veil: light-dark(rgba(0,0,0,.5), rgba(255,255,255,.5));
}
CSS
    run_parse_quiet "$src" "$CONV_DATAATTR"
    [ "$status" -eq 0 ]
    [ "$(field --brand-veil light)" = "rgba(0,0,0,.5)" ]
    [ "$(field --brand-veil dark)" = "rgba(255,255,255,.5)" ]
}

@test "U5: light-dark(var(), var()) populates the alias fields on BOTH sides" {
    src="$BATS_TEST_TMPDIR/u5_aliases.css"
    cat > "$src" <<'CSS'
:root {
  --brand-l: #111111;
  --brand-d: #eeeeee;
  --brand-fg: light-dark(var(--brand-l), var(--brand-d));
}
CSS
    run_parse_quiet "$src" "$CONV_DATAATTR"
    [ "$status" -eq 0 ]
    [ "$(field --brand-fg light_alias)" = "--brand-l" ]
    [ "$(field --brand-fg dark_alias)" = "--brand-d" ]
    # and the aliases are chased through to their literals
    [ "$(field --brand-fg light)" = "#111111" ]
    [ "$(field --brand-fg dark)" = "#EEEEEE" ]
}

@test "U5: a dark scope overriding a light-dark() base WINS and WARNS" {
    src="$BATS_TEST_TMPDIR/u5_override.css"
    cat > "$src" <<'CSS'
:root {
  --brand-bg: light-dark(#fff, #000);
}
:root[data-theme="dark"] {
  --brand-bg: #123456;
}
CSS
    run_parse_quiet "$src" "$CONV_DATAATTR"
    [ "$status" -eq 0 ]
    [ "$(field --brand-bg light)" = "#FFF" ]
    # the more specific signal wins over the light-dark() second argument
    [ "$(field --brand-bg dark)" = "#123456" ]

    run bash -c "cat '$src' | python3 '$LIB' --conventions '$CONV_DATAATTR' 2>&1 >/dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" == *"--brand-bg"* ]]
    [[ "$output" == *"light-dark"* ]]
    [[ "$output" == *"#000"* ]]
}

@test "U5: malformed one-argument light-dark() is left literal, WARNED, not crashed" {
    src="$BATS_TEST_TMPDIR/u5_malformed.css"
    cat > "$src" <<'CSS'
:root {
  --brand-oops: light-dark(#fff);
}
CSS
    run_parse_quiet "$src" "$CONV_DATAATTR"
    [ "$status" -eq 0 ]
    [ "$(field --brand-oops light)" = "light-dark(#FFF)" ]
    # both sides are the same literal, so the token is not theme-varying
    [ "$(field --brand-oops dark)" = "null" ]

    run bash -c "cat '$src' | python3 '$LIB' --conventions '$CONV_DATAATTR' 2>&1 >/dev/null"
    [ "$status" -eq 0 ]
    [[ "$output" == *"--brand-oops"* ]]
    [[ "$output" == *"light-dark"* ]]
    [[ "$output" == *"argument"* ]]
}

@test "U5: whitespace variants inside light-dark() are tolerated" {
    src="$BATS_TEST_TMPDIR/u5_ws.css"
    cat > "$src" <<'CSS'
:root {
  --brand-a: light-dark( #fff , #000 );
  --brand-b: LIGHT-DARK(#fff,#000);
}
CSS
    run_parse_quiet "$src" "$CONV_DATAATTR"
    [ "$status" -eq 0 ]
    [ "$(field --brand-a light)" = "#FFF" ]
    [ "$(field --brand-a dark)" = "#000" ]
    # CSS function names are case-insensitive
    [ "$(field --brand-b light)" = "#FFF" ]
    [ "$(field --brand-b dark)" = "#000" ]
}

@test "U5: light-dark() reached THROUGH an alias still splits both sides" {
    src="$BATS_TEST_TMPDIR/u5_via_alias.css"
    cat > "$src" <<'CSS'
:root {
  --brand-base: light-dark(#fff, #000);
  --brand-surface: var(--brand-base);
}
CSS
    run_parse_quiet "$src" "$CONV_DATAATTR"
    [ "$status" -eq 0 ]
    [ "$(field --brand-surface light)" = "#FFF" ]
    [ "$(field --brand-surface dark)" = "#000" ]
    [ "$(field --brand-surface light_alias)" = "--brand-base" ]
}

@test "U5: a value that merely CONTAINS light-dark() is not split" {
    src="$BATS_TEST_TMPDIR/u5_composite.css"
    cat > "$src" <<'CSS'
:root {
  --brand-border: 1px solid light-dark(#fff, #000);
  --brand-two: light-dark(#fff,#000) light-dark(#111,#222);
}
CSS
    run_parse_quiet "$src" "$CONV_DATAATTR"
    [ "$status" -eq 0 ]
    [ "$(field --brand-border light)" = "1px solid light-dark(#FFF, #000)" ]
    [ "$(field --brand-border dark)" = "null" ]
    [ "$(field --brand-two light)" = "light-dark(#FFF,#000) light-dark(#111,#222)" ]
    [ "$(field --brand-two dark)" = "null" ]
}

# ============================================================================
# SCSS: interpolation is a value, and @use/@import build a file graph
# ============================================================================

@test "SCSS: an interpolation #{…} is a value, not the start of a nested rule" {
    # `#{$x}` opens an UNQUOTED brace, so the quote guard doesn't cover it. The
    # block splitter read it as a child block and dropped the declaration —
    # silent token loss, which downstream reads as a DELETE.
    run bash -c "printf ':root{--a:#{\$x};--b:#fff;}' | python3 '$LIB' --conventions '$CONV_DATAATTR' 2>/dev/null"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '[.[] | select(.name=="--a")] | length')" = "1" ]
    [ "$(echo "$output" | jq -r '[.[] | select(.name=="--b")] | length')" = "1" ]
}

@test "SCSS: a hex colour is not mistaken for an interpolation" {
    run bash -c "printf ':root{--c:#fff;--d:#0066ff;}' | python3 '$LIB' --conventions '$CONV_DATAATTR' 2>/dev/null"
    [ "$status" -eq 0 ]
    [ "$(field --c light)" = "#FFF" ]
    [ "$(field --d light)" = "#0066FF" ]
}

@test "SCSS: nested interpolation with a quoted brace inside survives" {
    run bash -c "printf ':root{--a:#{if(\$t, \"{\", \"}\")};--b:#fff;}' | python3 '$LIB' --conventions '$CONV_DATAATTR' 2>/dev/null"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '[.[] | select(.name=="--b")] | length')" = "1" ]
}

@test "SCSS graph: @use pulls dependencies in, and the importer WINS on conflict" {
    run python3 -c "
import sys, os; sys.path.insert(0, '$SCRIPT_DIR/lib')
import parse_tokens as pt
entry = '$FIXTURE_DIR/scss_graph/tokens.scss'
text, loaded, missing = pt.resolve_source_graph(entry)

# Concatenation order is dependency-first; later-wins must agree with the cascade.
assert [os.path.basename(f) for f in loaded] == ['_palette.scss', '_dark.scss', 'tokens.scss'], loaded
assert not missing, missing

recs = pt.parse_tokens(text, [{'type': 'class', 'class': 'dark', 'primary': True}])
by = {r['name']: r for r in recs}
assert by['--brand-accent']['light'] == '#0066FF', by['--brand-accent']   # from a dependency
assert by['--brand-accent']['dark']  == '#66AAFF', by['--brand-accent']   # dark scope from another
assert by['--brand-bg']['light']     == '#FAFAFA', by['--brand-bg']       # ENTRY overrides dependency
assert by['--brand-radius']['light'] == '4px', by['--brand-radius']
assert not any('sass' in f for f in loaded), loaded   # sass: built-in skipped, not loaded
assert not missing, 'a sass: built-in must not be reported missing'
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *OK* ]]
}

@test "SCSS graph: an import cycle terminates and still yields both files' tokens" {
    tmp="$BATS_TMPDIR/cycle"; mkdir -p "$tmp"
    printf '@use "./b";\n:root { --brand-a: 1px; }\n' > "$tmp/a.scss"
    printf '@use "./a";\n:root { --brand-b: 2px; }\n' > "$tmp/b.scss"
    run python3 -c "
import sys; sys.path.insert(0, '$SCRIPT_DIR/lib')
import parse_tokens as pt
text, loaded, missing = pt.resolve_source_graph('$tmp/a.scss')
recs = pt.parse_tokens(text, [{'type': 'class', 'class': 'dark', 'primary': True}])
names = sorted(r['name'] for r in recs)
assert names == ['--brand-a', '--brand-b'], names
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *OK* ]]
}

@test "SCSS graph: an unresolved import is reported, never silently skipped" {
    tmp="$BATS_TMPDIR/missing"; mkdir -p "$tmp"
    printf '@import "./nope";\n:root { --brand-a: 1px; }\n' > "$tmp/entry.scss"
    run python3 -c "
import sys; sys.path.insert(0, '$SCRIPT_DIR/lib')
import parse_tokens as pt
text, loaded, missing = pt.resolve_source_graph('$tmp/entry.scss')
assert missing and missing[0][0] == './nope', missing
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *OK* ]]
}

@test "SCSS graph: followImports is OPT-IN — default reads exactly one file" {
    tmp="$BATS_TMPDIR/optin"; mkdir -p "$tmp"
    printf '@use "./dep";\n:root { --brand-a: 1px; }\n' > "$tmp/entry.scss"
    printf ':root { --brand-dep: 9px; }\n' > "$tmp/dep.scss"
    run python3 -c "
import sys; sys.path.insert(0, '$SCRIPT_DIR/lib')
import parse_tokens as pt
cfg = {'_repo': '$tmp', 'source': {'path': 'entry.scss'}}
one = pt.parse_tokens(pt.load_source(cfg), [{'type':'class','class':'dark','primary':True}])
assert [r['name'] for r in one] == ['--brand-a'], one          # dependency NOT pulled in
cfg['source']['followImports'] = True
many = pt.parse_tokens(pt.load_source(cfg), [{'type':'class','class':'dark','primary':True}])
assert sorted(r['name'] for r in many) == ['--brand-a', '--brand-dep'], many
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *OK* ]]
}

# ============================================================================
# file convention — the dark theme is a separate FILE, not a scope
# ============================================================================

@test "file convention: light + dark files resolve to one merged record set" {
    run python3 -c "
import sys; sys.path.insert(0, '$SCRIPT_DIR/lib')
import parse_tokens as pt
light = open('$FIXTURE_DIR/theme_files/light.scss').read()
dark  = open('$FIXTURE_DIR/theme_files/dark.scss').read()
conv = [{'type': 'file', 'path': 'theme_files/dark.scss', 'primary': True}]
by = {r['name']: r for r in pt.parse_tokens(light, conv, dark_texts={0: dark})}

assert by['--brand-text']['light'] == '#21242E' and by['--brand-text']['dark'] == '#E8E8E7', by['--brand-text']
assert by['--brand-bg']['light']   == '#FCFCFC' and by['--brand-bg']['dark']   == '#0D0D0D', by['--brand-bg']
# declared only in light -> theme-invariant
assert by['--brand-only-light']['dark'] is None, by['--brand-only-light']
# declared only in dark -> the orphan-twin shape
assert by['--brand-sass']['light'] is None, by['--brand-sass']
# a component selector INSIDE the dark file is not the theme scope
assert '--brand-not-a-theme-token' not in by, sorted(by)
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *OK* ]]
}

@test "file convention: a line comment above the rule does not swallow its selector" {
    # The real dark.scss opens with `//Helpers` above `:root {`. Without
    # strip_comments the selector becomes '//Helpers\n\n:root', matches nothing,
    # and the dark scope silently reads as empty — i.e. every -dark twin deleted.
    run python3 -c "
import sys; sys.path.insert(0, '$SCRIPT_DIR/lib')
import parse_tokens as pt
light = open('$FIXTURE_DIR/theme_files/light.scss').read()
dark  = open('$FIXTURE_DIR/theme_files/dark.scss').read()
recs = pt.parse_tokens(light, [{'type':'file','path':'d','primary':True}], dark_texts={0: dark})
assert any(r['dark'] is not None for r in recs), 'dark scope resolved EMPTY'
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *OK* ]]
}

@test "file convention: a missing theme file REFUSES, never an empty dark scope" {
    run python3 -c "
import sys; sys.path.insert(0, '$SCRIPT_DIR/lib')
import parse_tokens as pt
cfg = {'_repo': '$FIXTURE_DIR', 'source': {'path': 'theme_files/light.scss'},
       'themeConventions': [{'type': 'file', 'path': 'theme_files/NOPE.scss', 'primary': True}]}
try:
    pt.resolve_dark_texts(cfg)
except RuntimeError as e:
    assert 'could not read theme file' in str(e), e
    assert 'delete every -dark twin' in str(e), 'the refusal must say WHY it refuses'
    print('OK')
else:
    raise AssertionError('a missing theme file must refuse, not yield an empty dark scope')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *OK* ]]
}

@test "file convention: desugaring one is a category error, not a silent no-match" {
    run python3 -c "
import sys; sys.path.insert(0, '$SCRIPT_DIR/lib')
import parse_tokens as pt
try:
    pt.desugar_convention({'type': 'file', 'path': 'd.scss'})
except ValueError as e:
    assert 'resolved at load' in str(e), e
    print('OK')
else:
    raise AssertionError('desugaring a file convention must raise, not return []')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *OK* ]]
}

@test "base scope: :root, html and body are base; component selectors never are" {
    run python3 -c "
import sys; sys.path.insert(0, '$SCRIPT_DIR/lib')
import parse_tokens as pt
yes = [':root', 'html', 'body', 'html, body', '  body  ']
no  = ['html.dark', ':root[data-theme=\"dark\"]', 'body.theme-dark', '.tooltip', 'html body', '.dark, .dark *']
for s in yes: assert pt._is_document_scope(s), s
for s in no:  assert not pt._is_document_scope(s), s
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *OK* ]]
}

@test "base scope: a group containing body wins — it applies ON body" {
    run bash -c "printf ':root{--brand-a:#111;}\nhtml, body{--brand-b:#222;--brand-a:#333;}' | python3 '$LIB' --conventions '$CONV_DATAATTR' 2>/dev/null"
    [ "$status" -eq 0 ]
    [ "$(field --brand-b light)" = "#222" ]
    # `html, body { … }` sets the property ON body, and body's own declaration
    # shadows the inherited :root value for body and everything under it — i.e.
    # for all rendered content. So the group wins, whatever the order.
    [ "$(field --brand-a light)" = "#333" ]
}

@test "base merge: :root beats html for the same property, whatever the order" {
    # :root is (0,1,0), html is (0,0,1) — both select the same element, so a
    # source-order merge synced a value no browser renders.
    run bash -c "printf ':root{--brand-a:#AAAAAA;}html{--brand-a:#BBBBBB;}' | python3 '$LIB' --conventions '$CONV_DATAATTR' 2>/dev/null"
    [ "$status" -eq 0 ]
    [ "$(field --brand-a light)" = "#AAAAAA" ]

    run bash -c "printf 'html{--brand-a:#BBBBBB;}:root{--brand-a:#AAAAAA;}' | python3 '$LIB' --conventions '$CONV_DATAATTR' 2>/dev/null"
    [ "$status" -eq 0 ]
    [ "$(field --brand-a light)" = "#AAAAAA" ]
}

@test "base merge: html and body share a tier, so source order still decides" {
    run bash -c "printf 'html{--brand-a:#BBBBBB;}body{--brand-a:#CCCCCC;}' | python3 '$LIB' --conventions '$CONV_DATAATTR' 2>/dev/null"
    [ "$status" -eq 0 ]
    [ "$(field --brand-a light)" = "#CCCCCC" ]
}

@test "base scope: body beats :root regardless of order (inheritance, not specificity)" {
    # body is a DIFFERENT, deeper element — its declaration shadows the
    # inherited :root value for every rendered descendant. Ordering it below
    # :root synced the one value the page never displays.
    run bash -c "printf ':root{--brand-a:#AAAAAA;}body{--brand-a:#CCCCCC;}' | python3 '$LIB' --conventions '$CONV_DATAATTR' 2>/dev/null"
    [ "$status" -eq 0 ]
    [ "$(field --brand-a light)" = "#CCCCCC" ]

    run bash -c "printf 'body{--brand-a:#CCCCCC;}:root{--brand-a:#AAAAAA;}' | python3 '$LIB' --conventions '$CONV_DATAATTR' 2>/dev/null"
    [ "$status" -eq 0 ]
    [ "$(field --brand-a light)" = "#CCCCCC" ]
}

@test "file convention: source.ref pins BOTH halves to one revision" {
    # Reading the base at a pinned ref and the dark half from the working tree
    # computes theme deltas across two revisions — uncommitted dark edits look
    # like theme variance and sync writes phantom twins.
    repo="$BATS_TMPDIR/refpair"; rm -rf "$repo"; mkdir -p "$repo"
    ( cd "$repo" && git init -q . \
      && printf ':root{--brand-x:#ffffff;}' > light.css \
      && printf ':root{--brand-x:#111111;}' > dark.css \
      && git add -A && git -c user.email=t@t -c user.name=t commit -qm init \
      && printf ':root{--brand-x:#999999;}' > dark.css )
    run python3 -c "
import sys; sys.path.insert(0, '$SCRIPT_DIR/lib')
import parse_tokens as pt
cfg = {'_repo': '$repo',
       'source': {'path': 'light.css', 'prefix': '--brand-', 'ref': 'HEAD'},
       'themeConventions': [{'type': 'file', 'path': 'dark.css', 'primary': True}]}
dark = pt.resolve_dark_texts(cfg)[0]
assert '#111111' in dark, dark          # the COMMITTED dark
assert '#999999' not in dark, dark      # not the working-tree edit
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *OK* ]]
}

@test "source.ref composes with followImports in BOTH loaders" {
    # ref returned before the followImports branch in load_source (dropping every
    # imported partial's tokens) and followImports returned before the ref check
    # in resolve_dark_texts (reading the theme from the working tree). Each
    # option silently disabled the other, in opposite directions.
    repo="$BATS_TMPDIR/refimports"; rm -rf "$repo"; mkdir -p "$repo/css"
    ( cd "$repo" && git init -q . \
      && printf '@use "palette";\n:root{--brand-fg:#111111;}' > css/tokens.scss \
      && printf ':root{--brand-accent:#00b72b;--brand-bg:#ffffff;}' > css/_palette.scss \
      && printf ':root{--brand-accent:#222222;}' > css/dark.scss \
      && git add -A && git -c user.email=t@t -c user.name=t commit -qm init \
      && printf ':root{--brand-accent:#999999;}' > css/dark.scss )
    run python3 -c "
import sys; sys.path.insert(0, '$SCRIPT_DIR/lib')
import parse_tokens as pt
cfg = {'_repo': '$repo',
       'source': {'path':'css/tokens.scss','prefix':'--brand-','ref':'HEAD','followImports':True},
       'themeConventions': [{'type':'file','path':'css/dark.scss','primary':True}]}
base = pt.load_source(cfg)
assert '--brand-accent' in base and '--brand-bg' in base, 'imported partial dropped under ref'
dark = pt.resolve_dark_texts(cfg)[0]
assert '#222222' in dark and '#999999' not in dark, 'theme read from working tree, not ref'
print('OK')
" 2>/dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *OK* ]]
}
