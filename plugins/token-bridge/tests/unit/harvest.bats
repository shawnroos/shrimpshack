#!/usr/bin/env bats
# Unit tests for lib/harvest.py (Unit U6).
#
# These run WITHOUT a live dev server: agent-browser is faked via the
# $WCS_PAPER_AGENT_BROWSER env override (tests/fixtures/fake-agent-browser.sh),
# whose behaviour is switched with FAKE_MODE / FAKE_EVAL_FILE.
#
# UNIT-TESTED here:
#   - server_unreachable envelope when the dev server can't be opened
#   - component_not_found envelope when the selector never renders (null eval)
#   - structure pass-through: one record per node, active theme recorded
#   - selector injection into the eval script (build_extract_js)
#   - wrapper unwrapping + envelope shape + valid JSON
#   - whole-batch and --list CLI modes
#
# SMOKE-ONLY (NOT covered here — needs a live, logged-in WCS dev server):
#   - AE4: a currentColor / color-mix() border coming back as a LITERAL hex/rgb.
#     getComputedStyle does that resolution in the real browser; a fixture can only
#     prove pass-through, not that the browser resolved it. Verify on a live server.

setup() {
    SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    LIB_DIR="$SCRIPT_DIR/lib"
    FIXTURE_DIR="$SCRIPT_DIR/tests/fixtures"
    HARVEST="$LIB_DIR/harvest.py"
    BATCH="$LIB_DIR/harvest_batch.json"

    FAKE="$FIXTURE_DIR/fake-agent-browser.sh"
    chmod +x "$FAKE"

    # Route harvest.py at the fake agent-browser and keep every call fast.
    export WCS_PAPER_AGENT_BROWSER="$FAKE"
    export WCS_PAPER_PROFILE="test-profile"
    export WCS_PAPER_BASE_URL="http://localhost:4200"
    export WCS_PAPER_STEP_TIMEOUT="10"
    unset FAKE_MODE FAKE_EVAL_FILE 2>/dev/null || true
}

# ============================================================================
# Error path: unreachable dev server -> server_unreachable envelope
# ============================================================================

@test "harvest: unreachable dev server returns server_unreachable envelope" {
    export FAKE_MODE="unreachable"
    run python3 "$HARVEST" --name typography-heading --batch "$BATCH"
    [ "$status" -eq 0 ]

    ok=$(echo "$output" | jq -r '.ok')
    err=$(echo "$output" | jq -r '.error')
    [ "$ok" = "false" ]
    [ "$err" = "server_unreachable" ]
    # error envelopes carry a `note` — the field every other wcs-paper script uses
    note=$(echo "$output" | jq -r '.note')
    [ "$note" != "null" ] && [ -n "$note" ]
}

@test "harvest: server_unreachable envelope carries the component identity" {
    export FAKE_MODE="unreachable"
    run python3 "$HARVEST" --name typography-heading --batch "$BATCH"
    [ "$status" -eq 0 ]

    name=$(echo "$output" | jq -r '.name')
    [ "$name" = "typography-heading" ]
}

# ============================================================================
# Error path: selector never renders -> component_not_found (NOT empty-success)
# ============================================================================

@test "harvest: a selector that never renders returns component_not_found" {
    export FAKE_MODE="notfound"
    run python3 "$HARVEST" --name typography-heading --batch "$BATCH"
    [ "$status" -eq 0 ]

    ok=$(echo "$output" | jq -r '.ok')
    err=$(echo "$output" | jq -r '.error')
    [ "$ok" = "false" ]
    [ "$err" = "component_not_found" ]
}

@test "harvest: component_not_found is NOT an empty-but-successful result" {
    export FAKE_MODE="notfound"
    run python3 "$HARVEST" --name typography-heading --batch "$BATCH"
    [ "$status" -eq 0 ]

    # Must not masquerade as ok with an empty node list.
    ok=$(echo "$output" | jq -r '.ok')
    [ "$ok" = "false" ]
    nodes=$(echo "$output" | jq -r '.nodes // "absent"')
    [ "$nodes" = "absent" ]
}

# ============================================================================
# Structure: pass-through of one record per node + active theme
# ============================================================================

@test "harvest: ok mode returns an ok envelope with the active theme" {
    export FAKE_MODE="ok"
    run python3 "$HARVEST" --name typography-heading --batch "$BATCH"
    [ "$status" -eq 0 ]

    ok=$(echo "$output" | jq -r '.ok')
    theme=$(echo "$output" | jq -r '.theme')
    [ "$ok" = "true" ]
    [ "$theme" = "dark" ]
}

@test "harvest: emits one flattened record per node" {
    export FAKE_MODE="ok"
    run python3 "$HARVEST" --name typography-heading --batch "$BATCH"
    [ "$status" -eq 0 ]

    # Fixture tree = root (app-typography-heading) + one child (h1) = 2 nodes.
    count=$(echo "$output" | jq '.nodes | length')
    [ "$count" -eq 2 ]
}

@test "harvest: each node record carries the theme" {
    export FAKE_MODE="ok"
    run python3 "$HARVEST" --name typography-heading --batch "$BATCH"
    [ "$status" -eq 0 ]

    themes=$(echo "$output" | jq -r '[.nodes[].theme] | unique | join(",")')
    [ "$themes" = "dark" ]
}

@test "harvest: node styles pass through unchanged (border literal preserved)" {
    export FAKE_MODE="ok"
    run python3 "$HARVEST" --name typography-heading --batch "$BATCH"
    [ "$status" -eq 0 ]

    # The h1 node's resolved border color survives the pass-through verbatim.
    color=$(echo "$output" | jq -r '.nodes[] | select(.tag=="h1") | .styles["border-bottom-color"]')
    [ "$color" = "rgb(88, 101, 242)" ]

    text=$(echo "$output" | jq -r '.nodes[] | select(.tag=="h1") | .text')
    [ "$text" = "Heading" ]
}

@test "harvest: output is valid JSON" {
    export FAKE_MODE="ok"
    run python3 "$HARVEST" --name typography-heading --batch "$BATCH"
    [ "$status" -eq 0 ]
    echo "$output" | jq . > /dev/null
}

@test "harvest: unwraps a result-wrapped eval payload" {
    export FAKE_MODE="ok"
    export FAKE_EVAL_FILE="$FIXTURE_DIR/harvest-tree-wrapped.json"
    run python3 "$HARVEST" --name typography-body --batch "$BATCH"
    [ "$status" -eq 0 ]

    ok=$(echo "$output" | jq -r '.ok')
    theme=$(echo "$output" | jq -r '.theme')
    [ "$ok" = "true" ]
    [ "$theme" = "light" ]
}

# ============================================================================
# Selector injection (pure logic)
# ============================================================================

@test "harvest: build_extract_js injects the selector and drops the token" {
    run python3 -c "
import sys
sys.path.insert(0, '$LIB_DIR')
import harvest
tpl = 'const S = \"__WCS_PAPER_SELECTOR__\"; S'
out = harvest.build_extract_js(tpl, 'app-typography-heading')
assert 'app-typography-heading' in out, out
assert '__WCS_PAPER_SELECTOR__' not in out, out
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "harvest: build_extract_js escapes a selector with quotes" {
    run python3 -c "
import sys
sys.path.insert(0, '$LIB_DIR')
import harvest
tpl = 'x \"__WCS_PAPER_SELECTOR__\" y'
out = harvest.build_extract_js(tpl, 'a[data-x=\"y\"]')
# Must remain a single valid JS string literal (escaped inner quotes).
assert '\\\\\"y\\\\\"' in out or '\\\\u0022' in out, out
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

# ============================================================================
# interpret_eval_output (pure logic)
# ============================================================================

@test "harvest: interpret_eval_output raises component_not_found on null" {
    run python3 -c "
import sys
sys.path.insert(0, '$LIB_DIR')
import harvest
try:
    harvest.interpret_eval_output('null')
    print('NO_RAISE')
except harvest.HarvestError as e:
    print(e.code)
"
    [ "$status" -eq 0 ]
    [ "$output" = "component_not_found" ]
}

@test "harvest: interpret_eval_output raises component_not_found on empty output" {
    run python3 -c "
import sys
sys.path.insert(0, '$LIB_DIR')
import harvest
try:
    harvest.interpret_eval_output('   ')
    print('NO_RAISE')
except harvest.HarvestError as e:
    print(e.code)
"
    [ "$status" -eq 0 ]
    [ "$output" = "component_not_found" ]
}

@test "harvest: interpret_eval_output raises component_not_found on ok:false payload" {
    run python3 -c "
import sys
sys.path.insert(0, '$LIB_DIR')
import harvest
try:
    harvest.interpret_eval_output('{\"ok\": false, \"error\": \"component_not_found\", \"root\": null}')
    print('NO_RAISE')
except harvest.HarvestError as e:
    print(e.code)
"
    [ "$status" -eq 0 ]
    [ "$output" = "component_not_found" ]
}

# ============================================================================
# CLI modes: --list and whole-batch
# ============================================================================

@test "harvest: --list prints the six seeded typography component names" {
    run python3 "$HARVEST" --list --batch "$BATCH"
    [ "$status" -eq 0 ]

    count=$(echo "$output" | jq 'length')
    [ "$count" -eq 6 ]
    first=$(echo "$output" | jq -r '.[0]')
    [ "$first" = "typography-heading" ]
}

@test "harvest: whole-batch mode wraps a per-component result array" {
    export FAKE_MODE="ok"
    run python3 "$HARVEST" --batch "$BATCH"
    [ "$status" -eq 0 ]

    ok=$(echo "$output" | jq -r '.ok')
    count=$(echo "$output" | jq '.components | length')
    [ "$ok" = "true" ]
    [ "$count" -eq 6 ]
}

@test "harvest: unknown --name returns unknown_component" {
    run python3 "$HARVEST" --name does-not-exist --batch "$BATCH"
    [ "$status" -eq 2 ]

    err=$(echo "$output" | jq -r '.error')
    [ "$err" = "unknown_component" ]
}

@test "harvest: missing batch file returns batch_not_found" {
    run python3 "$HARVEST" --batch "/nonexistent/batch.json"
    [ "$status" -eq 2 ]

    err=$(echo "$output" | jq -r '.error')
    [ "$err" = "batch_not_found" ]
}
