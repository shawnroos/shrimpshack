#!/usr/bin/env bats
# Unit tests for lib/parse_tokens.py
# Verifies the per-theme token model: alias resolution, theme-varying detection
# (including light-only aliases that flip), targeted --font-family extraction,
# and idempotent normalization.

setup() {
    SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    LIB="$SCRIPT_DIR/lib/parse_tokens.py"
    FIXTURE_DIR="$SCRIPT_DIR/tests/fixtures"
    TOKENS="$FIXTURE_DIR/tokens_sample.scss"
    GENERAL="$FIXTURE_DIR/general_sample.scss"
    EXPECTED="$FIXTURE_DIR/tokens_expected.json"
}

# helper: field of the record with a given name
field() { # <name> <field>
    echo "$output" | jq -r --arg n "$1" --arg f "$2" '.[] | select(.name==$n) | .[$f]'
}

# ============================================================================
# Happy path — a redeclared token resolves to distinct light/dark
# ============================================================================

@test "parse_tokens: redeclared token (--wcs-accent) resolves distinct light/dark" {
    run bash -c "cat '$TOKENS' | python3 '$LIB'"
    [ "$status" -eq 0 ]
    [ "$(field --wcs-accent light)" = "#37D895" ]
    [ "$(field --wcs-accent dark)" = "#00B72B" ]
    # alias in light, literal in dark
    [ "$(field --wcs-accent light_alias)" = "--wcs-green-500" ]
    [ "$(field --wcs-accent dark_alias)" = "null" ]
}

# ============================================================================
# Flipping alias — declared only in light, referent redeclared in dark
# ============================================================================

@test "parse_tokens: flipping alias (--wcs-timeline-playhead) is theme-varying" {
    run bash -c "cat '$TOKENS' | python3 '$LIB'"
    [ "$status" -eq 0 ]
    # light resolves to the light accent, dark flips with the redeclared accent
    [ "$(field --wcs-timeline-playhead light)" = "#37D895" ]
    [ "$(field --wcs-timeline-playhead dark)" = "#00B72B" ]
    # non-null dark == theme-varying
    [ "$(field --wcs-timeline-playhead dark)" != "null" ]
    [ "$(field --wcs-timeline-playhead light_alias)" = "--wcs-accent" ]
}

# ============================================================================
# Non-flipping alias — referent never redeclared in dark
# ============================================================================

@test "parse_tokens: non-flipping alias (--wcs-warn-text) is theme-invariant" {
    run bash -c "cat '$TOKENS' | python3 '$LIB'"
    [ "$status" -eq 0 ]
    [ "$(field --wcs-warn-text light)" = "#C67700" ]
    # dark is null because the resolved value does not differ by theme
    [ "$(field --wcs-warn-text dark)" = "null" ]
    [ "$(field --wcs-warn-text light_alias)" = "--wcs-amber-text" ]
}

# ============================================================================
# Mode-invariant primitive
# ============================================================================

@test "parse_tokens: mode-invariant primitive (--wcs-space-2) has null dark" {
    run bash -c "cat '$TOKENS' | python3 '$LIB'"
    [ "$status" -eq 0 ]
    [ "$(field --wcs-space-2 light)" = "8px" ]
    [ "$(field --wcs-space-2 dark)" = "null" ]
}

# ============================================================================
# rgba() with internal commas must not corrupt the parse
# ============================================================================

@test "parse_tokens: rgba() internal commas survive intact" {
    run bash -c "cat '$TOKENS' | python3 '$LIB'"
    [ "$status" -eq 0 ]
    [ "$(field --wcs-lasso-fill light)" = "rgba(55, 216, 149, 0.18)" ]
    [ "$(field --wcs-lasso-fill dark)" = "rgba(136, 200, 46, 0.16)" ]
}

# ============================================================================
# Multi-part box-shadow + 8-digit hex uppercased
# ============================================================================

@test "parse_tokens: multi-part box-shadow keeps commas, uppercases 8-digit hex" {
    run bash -c "cat '$TOKENS' | python3 '$LIB'"
    [ "$status" -eq 0 ]
    [ "$(field --wcs-panel-shadow light)" = "0px 1px 3px #0000000F, 0 0 0 1px #0000000A" ]
    [ "$(field --wcs-green-100 dark)" = "#00B72B1A" ]
}

# ============================================================================
# parse_general — targeted --font-family extraction, ignores imports/keyframes
# ============================================================================

@test "parse_general: extracts --font-family from html,body and ignores noise" {
    run bash -c "cat '$GENERAL' | python3 '$LIB' --general"
    [ "$status" -eq 0 ]
    name=$(echo "$output" | jq -r '.name')
    [ "$name" = "--font-family" ]
    value=$(echo "$output" | jq -r '.light')
    [[ "$value" == *"Inter"* ]]
    [[ "$value" == *"sans-serif"* ]]
    # the decoy buried in the @keyframes block must NOT be picked
    [[ "$value" != *"DECOY"* ]]
    # theme-invariant record
    [ "$(echo "$output" | jq -r '.dark')" = "null" ]
}

# ============================================================================
# Normalization — names lowercased, hex uppercased, valid JSON, golden match
# ============================================================================

@test "parse_tokens: output is valid JSON matching the golden fixture" {
    run bash -c "cat '$TOKENS' | python3 '$LIB'"
    [ "$status" -eq 0 ]
    echo "$output" | jq . > /dev/null
    diff <(echo "$output") "$EXPECTED"
}

@test "parse_tokens: idempotent — two runs are byte-identical" {
    one=$(cat "$TOKENS" | python3 "$LIB")
    two=$(cat "$TOKENS" | python3 "$LIB")
    [ "$one" = "$two" ]
    # normalization: names lowercased, hex uppercased
    [[ "$one" == *'"--wcs-accent"'* ]]
    [[ "$one" == *'"#37D895"'* ]]
    [[ "$one" != *'"#37d895"'* ]]
}
