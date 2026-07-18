#!/usr/bin/env bats
# Unit tests for lib/classify_tokens.py
# Verifies each token gets the right Paper type, that motion/shadow/filter
# tokens are excluded with a reason, and — critically — that a multi-part value
# is NEVER emitted at type `color` (the silent-corruption coercion guard).

setup() {
    SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    LIB="$SCRIPT_DIR/lib/classify_tokens.py"
}

# Run the classifier over a one-record JSON array built from name+light values.
# Usage: classify <name> <light> [dark]
classify() {
    local name="$1" light="$2" dark="${3:-null}"
    local light_json dark_json
    light_json="\"$light\""
    if [ "$dark" = "null" ]; then dark_json="null"; else dark_json="\"$dark\""; fi
    local json="[{\"name\":\"$name\",\"light\":$light_json,\"dark\":$dark_json,\"light_alias\":null,\"dark_alias\":null}]"
    run bash -c "printf '%s' '$json' | python3 '$LIB'"
}

# field of the (single) record
field() { echo "$output" | jq -r ".[0].$1"; }

# ============================================================================
# Happy path — each value shape earns its native Paper type
# ============================================================================

@test "classify: hex color (#37d895) -> color" {
    classify --wcs-green-500 "#37d895"
    [ "$status" -eq 0 ]
    [ "$(field paper_type)" = "color" ]
    [ "$(field writable)" = "true" ]
    [ "$(field excluded_reason)" = "null" ]
}

@test "classify: rgba() -> color" {
    classify --wcs-lasso-fill "rgba(55, 216, 149, 0.18)"
    [ "$status" -eq 0 ]
    [ "$(field paper_type)" = "color" ]
}

@test "classify: transparent -> color" {
    classify --wcs-transparent "transparent"
    [ "$(field paper_type)" = "color" ]
}

@test "classify: 8px radius-named token -> radius" {
    classify --wcs-radius-sm-2 "8px"
    [ "$(field paper_type)" = "radius" ]
    [ "$(field writable)" = "true" ]
}

@test "classify: 8px space-named token -> spacing" {
    classify --wcs-space-2 "8px"
    [ "$(field paper_type)" = "spacing" ]
}

@test "classify: bare 0 space-named token -> spacing" {
    classify --wcs-space-0 "0"
    [ "$(field paper_type)" = "spacing" ]
}

@test "classify: 600 weight-named token -> fontWeight" {
    classify --wcs-panel-title-weight "600"
    [ "$(field paper_type)" = "fontWeight" ]
}

@test "classify: 'Inter', sans-serif -> fontFamily" {
    classify --font-family "'Inter', sans-serif"
    [ "$(field paper_type)" = "fontFamily" ]
    [ "$(field writable)" = "true" ]
}

# ============================================================================
# R6 — typography tokens get native Paper types
# ============================================================================

@test "classify R6: --wcs-panel-title-size (17px) -> fontSize" {
    classify --wcs-panel-title-size "17px"
    [ "$(field paper_type)" = "fontSize" ]
}

@test "classify R6: --wcs-panel-title-weight -> fontWeight" {
    classify --wcs-panel-title-weight "600"
    [ "$(field paper_type)" = "fontWeight" ]
}

@test "classify R6: --font-family -> fontFamily" {
    classify --font-family "'Inter', -apple-system, sans-serif"
    [ "$(field paper_type)" = "fontFamily" ]
}

# ============================================================================
# Exclusions — motion / shadow / filter have no Paper type (R8: reason set)
# ============================================================================

@test "classify: shadow token (multi-part) -> writable=false with a reason" {
    classify --wcs-panel-shadow "0px 1px 3px #0000000F, 0 0 0 1px #0000000A"
    [ "$status" -eq 0 ]
    [ "$(field writable)" = "false" ]
    [ "$(field paper_type)" = "null" ]
    # R8: every excluded token carries a reason
    [ "$(field excluded_reason)" != "null" ]
    [ -n "$(field excluded_reason)" ]
}

@test "classify: transition/easing value (0.15s ease) -> excluded (no Paper type)" {
    classify --wcs-transition-fast "0.15s ease"
    [ "$(field writable)" = "false" ]
    [ "$(field paper_type)" = "null" ]
    [ "$(field excluded_reason)" != "null" ]
}

@test "classify: cubic-bezier easing -> excluded" {
    classify --wcs-ease-emphasis "cubic-bezier(0.25, 1, 0.83, 1.01)"
    [ "$(field writable)" = "false" ]
    [ "$(field excluded_reason)" != "null" ]
}

@test "classify: drop-shadow filter -> excluded" {
    classify --wcs-panel-shadow-filter "drop-shadow(0 1px 3px #0000000f)"
    [ "$(field writable)" = "false" ]
    [ "$(field excluded_reason)" != "null" ]
}

# ============================================================================
# 8-digit hex must survive as a color (not mangled, not excluded)
# ============================================================================

@test "classify: 8-digit hex (#00B72B1A) -> color, not excluded" {
    classify --wcs-green-100 "#00B72B1A"
    [ "$(field paper_type)" = "color" ]
    [ "$(field writable)" = "true" ]
    [ "$(field excluded_reason)" = "null" ]
}

# ============================================================================
# COERCION GUARD — a multi-part value is NEVER emitted at type `color`
# ============================================================================

@test "classify guard: multi-part shadow paper_type is NOT color" {
    classify --wcs-panel-shadow "0px 1px 3px #0000000F, 0 0 0 1px #0000000A"
    [ "$(field paper_type)" != "color" ]
}

@test "classify guard: single-layer shadow (leading 0, trailing hex) is NOT color" {
    # No top-level comma, but still a partial-color multi-token value: the strict
    # full-match must refuse `color` here too.
    classify --wcs-popover-shadow "0 4px 16px #0003"
    [ "$(field paper_type)" != "color" ]
    [ "$(field writable)" = "false" ]
}

# ============================================================================
# Coercion guard — isolated from the name-based exclusion
# A partial-color value under a NEUTRAL name (no shadow/transition/ease) must
# still never be typed `color`. This exercises the strict _is_color full-match
# directly, which the shadow-NAMED guard tests skip (name check fires first).
# ============================================================================

@test "guard: neutral-named partial color (\"2px solid #37d895\") is NOT color" {
    classify "--wcs-icon-outline" "2px solid #37d895"
    [ "$status" -eq 0 ]
    pt=$(field paper_type)
    [ "$pt" != "color" ]
    w=$(field writable)
    [ "$w" = "false" ]
}

@test "guard: rgba(junk) is NOT typed color (loose-regex regression)" {
    classify "--wcs-icon-fill" "rgba(not,a,color)"
    [ "$status" -eq 0 ]
    pt=$(field paper_type)
    [ "$pt" != "color" ]
}

@test "sanity: a clean rgba() single color IS still color" {
    classify "--wcs-lasso-fill" "rgba(55, 216, 149, 0.18)"
    [ "$status" -eq 0 ]
    pt=$(field paper_type)
    [ "$pt" = "color" ]
}
