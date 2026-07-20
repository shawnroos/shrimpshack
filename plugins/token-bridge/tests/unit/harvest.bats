#!/usr/bin/env bats
# Unit tests for lib/harvest.py (token-bridge component harvest).
#
# These run WITHOUT a live dev server: agent-browser is faked via the
# $TB_AGENT_BROWSER env override (tests/fixtures/fake-agent-browser.sh),
# whose behaviour is switched with FAKE_MODE / FAKE_EVAL_FILE.
#
# UNIT-TESTED here:
#   - server_unreachable envelope when the dev server can't be opened
#   - component_not_found envelope when the selector never renders (null eval)
#   - structure pass-through: one record per node, active theme recorded
#   - selector injection into the eval script (build_extract_js)
#   - theme-signal injection into the eval script (config-driven, R6)
#   - wrapper unwrapping + envelope shape + valid JSON
#   - whole-batch and --list CLI modes
#
# SMOKE-ONLY (NOT covered here — needs a live, logged-in dev server):
#   - a currentColor / color-mix() border coming back as a LITERAL hex/rgb.
#     getComputedStyle does that resolution in the real browser; a fixture can only
#     prove pass-through, not that the browser resolved it. Verify on a live server.
#   - the theme signal actually reading the live page's theme — the fake browser
#     replays a fixture blob and does not run the injected JS, so the unit suite
#     proves the signal is INJECTED into the template, not that the browser used it.

setup() {
    SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    LIB_DIR="$SCRIPT_DIR/lib"
    FIXTURE_DIR="$SCRIPT_DIR/tests/fixtures"
    HARVEST="$LIB_DIR/harvest.py"
    # A self-contained test batch, decoupled from the shipped lib fallback
    # (which is intentionally empty). Six components; [0] == typography-heading.
    BATCH="$FIXTURE_DIR/harvest_batch_test.json"

    FAKE="$FIXTURE_DIR/fake-agent-browser.sh"
    chmod +x "$FAKE"

    # Route harvest.py at the fake agent-browser and keep every call fast.
    export TB_AGENT_BROWSER="$FAKE"
    export TB_PROFILE="test-profile"
    export TB_BASE_URL="http://localhost:4200"
    export TB_STEP_TIMEOUT="10"
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
tpl = 'const S = \"__TB_SELECTOR__\"; S'
out = harvest.build_extract_js(tpl, 'app-typography-heading')
assert 'app-typography-heading' in out, out
assert '__TB_SELECTOR__' not in out, out
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
tpl = 'x \"__TB_SELECTOR__\" y'
out = harvest.build_extract_js(tpl, 'a[data-x=\"y\"]')
# Must remain a single valid JS string literal (escaped inner quotes).
assert '\\\\\"y\\\\\"' in out or '\\\\u0022' in out, out
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

# R6: harvest.py injects the config theme signal into the eval template, dropping
# the bare __TB_THEME_SIGNAL__ token and leaving a valid JS object literal. This is
# the unit-level proof of the config-driven theme signal — the fake browser doesn't
# run JS, so a live server is needed to prove the browser then USES it.
@test "harvest: build_extract_js injects the data-attribute theme signal" {
    run python3 -c "
import json, sys
sys.path.insert(0, '$LIB_DIR')
import harvest
tpl = 'const S = \"__TB_SELECTOR__\"; const T = __TB_THEME_SIGNAL__;'
signal = {'type': 'data-attribute', 'attr': 'data-theme', 'value': 'dark'}
out = harvest.build_extract_js(tpl, 'app-x', signal)
assert '__TB_THEME_SIGNAL__' not in out, out
assert json.dumps(signal) in out, out
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "harvest: build_extract_js injects a media-query theme signal" {
    run python3 -c "
import json, sys
sys.path.insert(0, '$LIB_DIR')
import harvest
tpl = 'const T = __TB_THEME_SIGNAL__;'
signal = {'type': 'media-query', 'query': '(prefers-color-scheme: dark)'}
out = harvest.build_extract_js(tpl, 'app-x', signal)
assert '__TB_THEME_SIGNAL__' not in out, out
assert json.dumps(signal) in out, out
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "harvest: build_extract_js injects a class theme signal" {
    run python3 -c "
import json, sys
sys.path.insert(0, '$LIB_DIR')
import harvest
tpl = 'const T = __TB_THEME_SIGNAL__;'
signal = {'type': 'class', 'class': 'wcs-dark'}
out = harvest.build_extract_js(tpl, 'app-x', signal)
assert '__TB_THEME_SIGNAL__' not in out, out
assert json.dumps(signal) in out, out
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

# ============================================================================
# The extractor's class signal branch, EXECUTED against a stub DOM
# ============================================================================
#
# A missing class branch fails silently — theme stays "light" and every harvested
# component is mislabelled with no error anywhere — so these tests actually RUN
# harvest_extract.js under node instead of only asserting injection.
#
# The DOM is a stub, not jsdom (no dependency): documentElement/body carry a real
# whitespace-tokenised classList.contains, which is what the boundary case
# (.wcs-darker present, .wcs-dark absent) turns on.

# Usage: run_extract '<html classes>' '<body classes>' '<theme-signal JSON>'
# Prints the resolved theme.
run_extract() {
    local html_classes="$1" body_classes="$2" signal_json="$3"
    local dir="$BATS_TEST_TMPDIR/extract"
    mkdir -p "$dir"

    # Inject the signal through the REAL production path (harvest.build_extract_js).
    python3 -c "
import sys, json
sys.path.insert(0, '$LIB_DIR')
import harvest
tpl = open('$LIB_DIR/harvest_extract.js').read()
js = harvest.build_extract_js(tpl, 'div.target', json.loads('''$signal_json'''))
open('$dir/injected.js', 'w').write(js)
" || return 1

    cat > "$dir/harness.js" <<'JS'
const fs = require("fs");
const [jsPath, htmlClasses, bodyClasses] = process.argv.slice(2);

const makeEl = (classStr) => {
  const tokens = new Set(String(classStr).split(/\s+/).filter(Boolean));
  return {
    tagName: "DIV",
    classList: { contains: (c) => tokens.has(c) },
    getAttribute: () => null,
    childNodes: [],
    children: [],
  };
};

const target = makeEl("target");
global.document = {
  documentElement: makeEl(htmlClasses),
  body: makeEl(bodyClasses),
  querySelector: () => target,
};
global.getComputedStyle = () => ({ getPropertyValue: () => "", color: "rgb(0, 0, 0)" });
global.window = { matchMedia: () => ({ matches: false }) };

const result = eval(fs.readFileSync(jsPath, "utf8"));
process.stdout.write(String(result.theme));
JS

    node "$dir/harness.js" "$dir/injected.js" "$html_classes" "$body_classes"
}

@test "harvest extract: class on <html> resolves theme dark" {
    run run_extract "wcs-dark" "" '{"type":"class","class":"wcs-dark"}'
    [ "$status" -eq 0 ]
    [ "$output" = "dark" ]
}

@test "harvest extract: class on <body> resolves theme dark" {
    run run_extract "" "app wcs-dark" '{"type":"class","class":"wcs-dark"}'
    [ "$status" -eq 0 ]
    [ "$output" = "dark" ]
}

@test "harvest extract: class absent resolves theme light" {
    run run_extract "app" "shell" '{"type":"class","class":"wcs-dark"}'
    [ "$status" -eq 0 ]
    [ "$output" = "light" ]
}

# Boundary: a class whose name merely STARTS WITH the signal class must not match.
@test "harvest extract: .wcs-darker does not satisfy a .wcs-dark signal" {
    run run_extract "wcs-darker" "wcs-darker" '{"type":"class","class":"wcs-dark"}'
    [ "$status" -eq 0 ]
    [ "$output" = "light" ]
}

# Regression guard: the data-attribute and media-query branches still work when
# executed, not just when injected.
@test "harvest extract: a data-attribute signal still resolves (regression)" {
    run run_extract "" "" '{"type":"data-attribute","attr":"data-theme","value":"dark"}'
    [ "$status" -eq 0 ]
    [ "$output" = "light" ]
}

@test "harvest: build_extract_js injects null when no theme signal is configured" {
    run python3 -c "
import sys
sys.path.insert(0, '$LIB_DIR')
import harvest
tpl = 'const T = __TB_THEME_SIGNAL__;'
out = harvest.build_extract_js(tpl, 'app-x')
assert '__TB_THEME_SIGNAL__' not in out, out
assert 'const T = null;' in out, out
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
