#!/usr/bin/env bats
# Unit tests for lib/map_to_tokens.py (Unit U7).
#
# Rewrites harvested getComputedStyle literals back to var(--wcs-*) references,
# matching each literal against the token's EFFECTIVE value for the theme the
# node was harvested in. Verified here (small JSON fixtures, no live server):
#   - happy: a light-harvested #37d895 -> var(--wcs-accent)
#   - theme-correctness: a dark-harvested #00b72b -> var(--wcs-accent) (dark-effective),
#     NOT left unmapped by comparing against light-effective #37D895
#   - a value with no matching token stays a literal
#   - color-equivalent forms: rgb(55,216,149) resolves like #37d895
#   - ambiguity: a value matching multiple tokens resolves via the documented
#     deterministic tie-break (same winner every run)
#   - near-miss: a value matching a token only in the non-harvested theme lands in
#     near_misses and is NOT applied
#   - normalization equivalence (#ccc == #cccccc == rgb == rgba; 0 == 0px)

setup() {
    SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    LIB="$SCRIPT_DIR/lib/map_to_tokens.py"
    LIB_DIR="$SCRIPT_DIR/lib"
    FIXTURE_DIR="$SCRIPT_DIR/tests/fixtures"
    TOKENS="$FIXTURE_DIR/map_tokens.json"
    LIGHT="$FIXTURE_DIR/map_component_light.json"
    DARK="$FIXTURE_DIR/map_component_dark.json"
}

# helper: styles value at a node path
style_at() { # <path> <prop>
    echo "$output" | jq -r --arg p "$1" --arg k "$2" \
        '.nodes[] | select(.path==$p) | .styles[$k]'
}

# ============================================================================
# Happy path: a light-harvested #37d895 maps to the accent token
# ============================================================================

@test "map_to_tokens: light #37d895 maps to var(--wcs-accent)" {
    run bash -c "cat '$LIGHT' | python3 '$LIB' --tokens '$TOKENS'"
    [ "$status" -eq 0 ]
    [ "$(style_at 0 color)" = "var(--wcs-accent)" ]
}

@test "map_to_tokens: an 8px length maps to the spacing token" {
    run bash -c "cat '$LIGHT' | python3 '$LIB' --tokens '$TOKENS'"
    [ "$status" -eq 0 ]
    [ "$(style_at 0.0 margin-top)" = "var(--wcs-space-2)" ]
}

# ============================================================================
# Theme-correctness: dark-effective match, NOT left unmapped
# ============================================================================

@test "map_to_tokens: dark #00b72b maps to var(--wcs-accent) via dark-effective value" {
    run bash -c "cat '$DARK' | python3 '$LIB' --tokens '$TOKENS'"
    [ "$status" -eq 0 ]
    # #00B72B is --wcs-accent's DARK-effective value; must map, not stay literal.
    [ "$(style_at 0 color)" = "var(--wcs-accent)" ]
    [ "$(style_at 0 color)" != "#00b72b" ]
}

# ============================================================================
# No matching token -> literal stays unchanged
# ============================================================================

@test "map_to_tokens: an unmatched literal stays a literal" {
    run bash -c "cat '$LIGHT' | python3 '$LIB' --tokens '$TOKENS'"
    [ "$status" -eq 0 ]
    [ "$(style_at 0.0 background-color)" = "#123456" ]
}

# ============================================================================
# Color-equivalent forms: rgb() resolves like the hex form
# ============================================================================

@test "map_to_tokens: rgb(55,216,149) matches the same token as #37d895" {
    run bash -c "cat '$LIGHT' | python3 '$LIB' --tokens '$TOKENS'"
    [ "$status" -eq 0 ]
    # node 0.0 color is authored as rgb(55, 216, 149) — the accent's light value.
    [ "$(style_at 0.0 color)" = "var(--wcs-accent)" ]
}

# ============================================================================
# Ambiguity: #37D895 matches accent + green-500 + nav-item-active-fg.
# Documented tie-break (semantic over primitive, then alphabetical) => accent.
# ============================================================================

@test "map_to_tokens: ambiguous match resolves deterministically to --wcs-accent" {
    run bash -c "cat '$LIGHT' | python3 '$LIB' --tokens '$TOKENS'"
    [ "$status" -eq 0 ]
    winner="$(style_at 0 color)"
    # semantic accent beats the green-500 primitive; alphabetical beats nav-item-active-fg
    [ "$winner" = "var(--wcs-accent)" ]
    [ "$winner" != "var(--wcs-green-500)" ]
    [ "$winner" != "var(--wcs-nav-item-active-fg)" ]
}

@test "map_to_tokens: tie-break is stable across runs (same winner every time)" {
    one=$(cat "$LIGHT" | python3 "$LIB" --tokens "$TOKENS" | jq -r '.nodes[] | select(.path=="0") | .styles.color')
    two=$(cat "$LIGHT" | python3 "$LIB" --tokens "$TOKENS" | jq -r '.nodes[] | select(.path=="0") | .styles.color')
    [ "$one" = "var(--wcs-accent)" ]
    [ "$one" = "$two" ]
}

# ============================================================================
# Near-miss: a value that matches a token only in the OTHER theme.
# #FF0000 is --wcs-danger's LIGHT value; harvested in DARK it must NOT be applied,
# and must be reported in near_misses.
# ============================================================================

@test "map_to_tokens: other-theme-only match lands in near_misses, not applied" {
    run bash -c "cat '$DARK' | python3 '$LIB' --tokens '$TOKENS'"
    [ "$status" -eq 0 ]
    # not applied — the literal is preserved
    [ "$(style_at 0 border-top-color)" = "#ff0000" ]
    # reported as a near-miss against the light-theme danger token
    nm=$(echo "$output" | jq -c '.near_misses[] | select(.prop=="border-top-color")')
    [ -n "$nm" ]
    [ "$(echo "$nm" | jq -r '.token')" = "--wcs-danger" ]
    [ "$(echo "$nm" | jq -r '.theme')" = "light" ]
    [ "$(echo "$nm" | jq -r '.path')" = "0" ]
}

@test "map_to_tokens: a clean light map produces no near_misses" {
    run bash -c "cat '$LIGHT' | python3 '$LIB' --tokens '$TOKENS'"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq '.near_misses | length')" -eq 0 ]
}

# ============================================================================
# Output is valid JSON and preserves the envelope shape
# ============================================================================

@test "map_to_tokens: output is valid JSON preserving envelope keys" {
    run bash -c "cat '$DARK' | python3 '$LIB' --tokens '$TOKENS'"
    [ "$status" -eq 0 ]
    echo "$output" | jq . > /dev/null
    [ "$(echo "$output" | jq -r '.ok')" = "true" ]
    [ "$(echo "$output" | jq -r '.theme')" = "dark" ]
    [ "$(echo "$output" | jq -r '.name')" = "sample-dark" ]
}

# ============================================================================
# Normalization equivalence (pure logic)
# ============================================================================

@test "map_to_tokens: normalize_value treats hex/rgb/rgba forms as equivalent" {
    run python3 -c "
import sys
sys.path.insert(0, '$LIB_DIR')
import map_to_tokens as m
forms = ['#ccc', '#cccccc', '#ccccccff', 'rgb(204,204,204)', 'rgba(204, 204, 204, 1)']
norms = {m.normalize_value(f) for f in forms}
assert len(norms) == 1, norms
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "map_to_tokens: normalize_value treats 0 and 0px as equivalent" {
    run python3 -c "
import sys
sys.path.insert(0, '$LIB_DIR')
import map_to_tokens as m
assert m.normalize_value('0') == m.normalize_value('0px'), (m.normalize_value('0'), m.normalize_value('0px'))
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}
