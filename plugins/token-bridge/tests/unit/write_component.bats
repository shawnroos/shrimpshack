#!/usr/bin/env bats
# Unit tests for lib/write_component.py — the end-to-end component-refresh
# orchestration of token-bridge's code -> Paper path.
#
# UNIT vs SMOKE
# -------------
# These are all UNIT tests: they exercise the orchestration logic with a
# FAKE, injected PaperClient and a pre-mapped component fixture — NO live Paper
# daemon and NO dev server. The fake client is activated by setting
# $TB_FAKE_CLIENT to a JSON spec (scripted responses) and records every
# call it receives to $TB_CALL_LOG, so a test can assert the exact
# get_children -> delete_nodes -> write_html sequence.
#
# The target codebase is given by --repo <dir>: read_config loads
# <dir>/token-bridge.config.json (which carries the target fileId). The refuse
# guard runs off that fileId, before any Paper client is constructed.
#
# The following are SMOKE-ONLY and are deliberately NOT covered here (they need a
# running, logged-in dev server AND a running Paper daemon):
#   - the actual live harvest of a component (harvest.py driving agent-browser),
#   - the real Paper write landing nodes on the canvas,
#   - the components-actually-land-on-canvas end-to-end check.

setup() {
    SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    WRITER="$SCRIPT_DIR/lib/write_component.py"
    CALL_LOG="$BATS_TMPDIR/calls.json"
    rm -f "$CALL_LOG"

    # A pre-mapped component (name = layer name = "typography-heading"). One style
    # value is already a var(--…) token ref so we can assert it survives into
    # the write payload.
    MAPPED="$BATS_TMPDIR/mapped.json"
    cat > "$MAPPED" <<'JSON'
{
  "ok": true,
  "name": "typography-heading",
  "selector": "app-typography-heading",
  "route": "/creation-studio",
  "theme": "dark",
  "root": {
    "tag": "app-typography-heading",
    "text": "",
    "styles": { "display": "block" },
    "children": [
      {
        "tag": "h1",
        "text": "Heading",
        "styles": { "color": "var(--brand-heading-fg)", "font-size": "32px" },
        "children": []
      }
    ]
  },
  "near_misses": [
    { "path": "0.0", "prop": "color", "value": "#37d895", "token": "--brand-accent", "theme": "light" }
  ]
}
JSON
}

# Write a token-bridge.config.json with the given fileId into a fresh --repo dir
# and echo the dir. The writer is pointed at it via --repo (read_config loads
# <dir>/token-bridge.config.json). fileId may be empty to exercise the refuse guard.
_write_repo() {
    local file_id="$1"
    local repo="$BATS_TMPDIR/repo"
    rm -rf "$repo"
    mkdir -p "$repo"
    cat > "$repo/token-bridge.config.json" <<JSON
{ "fileId": "$file_id", "paperDaemonUrl": "http://127.0.0.1:29979/mcp" }
JSON
    echo "$repo"
}

# ============================================================================
# R13 (UNIT): refreshing an ALREADY-PRESENT component replaces it —
# get_children -> delete_nodes -> write_html, in that order. Node count does not
# grow (exactly one write, preceded by a delete of the old wrapper).
# ============================================================================

@test "R13 present: existing component issues get_children -> delete -> write in sequence" {
    repo="$(_write_repo "01TARGETFILE")"

    # Fake: find_nodes reports one existing wrapper whose layer name matches.
    spec="$BATS_TMPDIR/spec_present.json"
    cat > "$spec" <<'JSON'
{
  "get_children":  { "ok": true, "result": { "children": [ { "id": "N-EXISTING", "name": "typography-heading" } ] } },
  "delete_nodes": { "ok": true, "result": {} },
  "write_html":   { "ok": true, "result": { "nodeId": "N-FRESH" } }
}
JSON

    TB_FAKE_CLIENT="$spec" TB_CALL_LOG="$CALL_LOG" \
        run python3 "$WRITER" --repo "$repo" --mapped-file "$MAPPED" --target-node-id "AB-1"
    [ "$status" -eq 0 ]

    # The recorded call sequence is exactly find_nodes, delete_nodes, write_html.
    [ -f "$CALL_LOG" ]
    len=$(jq 'length' "$CALL_LOG");                 [ "$len" -eq 3 ]
    [ "$(jq -r '.[0].method' "$CALL_LOG")" = "get_children" ]
    [ "$(jq -r '.[1].method' "$CALL_LOG")" = "delete_nodes" ]
    [ "$(jq -r '.[2].method' "$CALL_LOG")" = "write_html" ]

    # Delete targets the existing node id that find_nodes returned.
    [ "$(jq -r '.[1].args.nodeIds[0]' "$CALL_LOG")" = "N-EXISTING" ]

    # Exactly one write_html — the count does not grow on replace.
    writes=$(jq '[.[] | select(.method=="write_html")] | length' "$CALL_LOG")
    [ "$writes" -eq 1 ]

    # The report marks the component as replaced + written.
    [ "$(echo "$output" | jq -r '.written[0].replaced')" = "true" ]
    [ "$(echo "$output" | jq -r '.componentsReplaced')" = "1" ]
    [ "$(echo "$output" | jq -r '.componentsWritten')" = "1" ]
}

# ============================================================================
# R13 (UNIT): refreshing a NOT-YET-PRESENT component (get_children returns none)
# SKIPS delete and just writes.
# ============================================================================

@test "R13 absent: not-yet-present component skips delete, only writes" {
    repo="$(_write_repo "01TARGETFILE")"

    spec="$BATS_TMPDIR/spec_absent.json"
    cat > "$spec" <<'JSON'
{
  "get_children":  { "ok": true, "result": { "children": [] } },
  "write_html":  { "ok": true, "result": { "nodeId": "N-FRESH" } }
}
JSON

    TB_FAKE_CLIENT="$spec" TB_CALL_LOG="$CALL_LOG" \
        run python3 "$WRITER" --repo "$repo" --mapped-file "$MAPPED" --target-node-id "AB-1"
    [ "$status" -eq 0 ]

    [ -f "$CALL_LOG" ]
    len=$(jq 'length' "$CALL_LOG");                 [ "$len" -eq 2 ]
    [ "$(jq -r '.[0].method' "$CALL_LOG")" = "get_children" ]
    [ "$(jq -r '.[1].method' "$CALL_LOG")" = "write_html" ]

    # No delete_nodes was ever issued.
    deletes=$(jq '[.[] | select(.method=="delete_nodes")] | length' "$CALL_LOG")
    [ "$deletes" -eq 0 ]

    [ "$(echo "$output" | jq -r '.written[0].replaced')" = "false" ]
    [ "$(echo "$output" | jq -r '.componentsReplaced')" = "0" ]
    [ "$(echo "$output" | jq -r '.componentsWritten')" = "1" ]
}

# ============================================================================
# SAFETY (UNIT): with fileId empty in config, refresh REFUSES, writes nothing,
# exits non-zero, and issues ZERO Paper calls (the fake client is never even
# constructed, so the call log is never written).
# ============================================================================

@test "safety: empty fileId refuses, non-zero exit, ZERO client calls" {
    repo="$(_write_repo "")"

    spec="$BATS_TMPDIR/spec_any.json"
    echo '{ "write_html": { "ok": true } }' > "$spec"

    TB_FAKE_CLIENT="$spec" TB_CALL_LOG="$CALL_LOG" \
        run python3 "$WRITER" --repo "$repo" --mapped-file "$MAPPED" --target-node-id "AB-1"

    # Non-zero exit, distinct refuse code.
    [ "$status" -eq 3 ]

    # Refusal is surfaced with an actionable error.
    [ "$(echo "$output" | jq -r '.ok')" = "false" ]
    [ "$(echo "$output" | jq -r '.error')" = "no_target_file" ]

    # ZERO calls: the client was never constructed, so no call log exists.
    [ ! -f "$CALL_LOG" ]
}

# ============================================================================
# (OPTIONAL, UNIT): mapped token refs (var(--…)) survive into the write_html HTML
# payload, and the wrapper stamps the neutral data-tb-component attribute (R8).
# ============================================================================

@test "token refs survive: var(--…) reaches the write_html payload with a neutral wrapper" {
    repo="$(_write_repo "01TARGETFILE")"

    spec="$BATS_TMPDIR/spec_survive.json"
    cat > "$spec" <<'JSON'
{
  "get_children":  { "ok": true, "result": { "children": [] } },
  "write_html":  { "ok": true, "result": {} }
}
JSON

    TB_FAKE_CLIENT="$spec" TB_CALL_LOG="$CALL_LOG" \
        run python3 "$WRITER" --repo "$repo" --mapped-file "$MAPPED" --target-node-id "AB-1"
    [ "$status" -eq 0 ]

    html=$(jq -r '[.[] | select(.method=="write_html")][0].args.html' "$CALL_LOG")
    [[ "$html" == *"var(--brand-heading-fg)"* ]]

    # The wrapper carries the stable layer name used for find/replace.
    [[ "$html" == *'layer-name="typography-heading"'* ]]

    # R8: the wrapper is stamped with the neutral data-tb-component attribute,
    # never the old WCS-specific data-wcs-component.
    [[ "$html" == *'data-tb-component="typography-heading"'* ]]
    [[ "$html" != *'data-wcs-component'* ]]
}

# ============================================================================
# DATA-LOSS GUARD (UNIT): find_nodes matches ALL wrappers file-wide by the
# shared sentinel style. Refreshing ONE component must delete only the wrapper
# whose layer name matches — never a sibling's node, and never a nameless
# record. Here find returns a sibling + a nameless record and NO match for
# "typography-heading": delete must be SKIPPED entirely.
# ============================================================================

@test "guard: single-component refresh never deletes sibling/nameless wrappers" {
    repo="$(_write_repo "01TARGETFILE")"

    spec="$BATS_TMPDIR/spec_siblings.json"
    cat > "$spec" <<'JSON'
{
  "get_children":  { "ok": true, "result": { "children": [
      { "id": "N-SIBLING", "name": "typography-body" },
      { "id": "N-NONAME" }
  ] } },
  "write_html":  { "ok": true, "result": { "nodeId": "N-FRESH" } }
}
JSON

    TB_FAKE_CLIENT="$spec" TB_CALL_LOG="$CALL_LOG" \
        run python3 "$WRITER" --repo "$repo" --mapped-file "$MAPPED" --target-node-id "AB-1"
    [ "$status" -eq 0 ]

    # No delete at all — nothing matched "typography-heading".
    deletes=$(jq '[.[] | select(.method=="delete_nodes")] | length' "$CALL_LOG")
    [ "$deletes" -eq 0 ]
    # And definitely no delete referencing the sibling or nameless ids.
    [[ "$(cat "$CALL_LOG")" != *"N-SIBLING"* ]]
    [[ "$(cat "$CALL_LOG")" != *"N-NONAME"* ]]
    [ "$(echo "$output" | jq -r '.written[0].replaced')" = "false" ]
}

# ============================================================================
# R13 GUARD (UNIT): if delete_nodes FAILS, do NOT write — writing anyway would
# duplicate the component while reporting it replaced.
# ============================================================================

@test "guard: a failed delete skips the write and reports replace_failed" {
    repo="$(_write_repo "01TARGETFILE")"

    spec="$BATS_TMPDIR/spec_delfail.json"
    cat > "$spec" <<'JSON'
{
  "get_children":   { "ok": true, "result": { "children": [ { "id": "N-EXISTING", "name": "typography-heading" } ] } },
  "delete_nodes": { "ok": false, "error": "tool_error", "note": "node is locked" },
  "write_html":   { "ok": true, "result": { "nodeId": "N-FRESH" } }
}
JSON

    TB_FAKE_CLIENT="$spec" TB_CALL_LOG="$CALL_LOG" \
        run python3 "$WRITER" --repo "$repo" --mapped-file "$MAPPED" --target-node-id "AB-1"

    # find + delete happened, but NO write_html (the count must not grow).
    writes=$(jq '[.[] | select(.method=="write_html")] | length' "$CALL_LOG")
    [ "$writes" -eq 0 ]
    [ "$(echo "$output" | jq -r '.written[0].written')" = "false" ]
    [ "$(echo "$output" | jq -r '.written[0].writeError.error')" = "replace_failed" ]
}

# ============================================================================
# ESCAPING GUARD (UNIT): a getComputedStyle font-family value carries double
# quotes; it must be escaped so it can't break out of the style="" attribute.
# Typography is the FIRST harvest batch, so this fires on the very first run.
# ============================================================================

@test "guard: a quoted font-family style value is escaped, not raw" {
    repo="$(_write_repo "01TARGETFILE")"

    mapped_q="$BATS_TMPDIR/mapped_quoted.json"
    cat > "$mapped_q" <<'JSON'
{
  "ok": true, "name": "typography-body", "theme": "light",
  "root": { "tag": "p", "text": "Body",
    "styles": { "font-family": "\"Helvetica Neue\", sans-serif" }, "children": [] }
}
JSON

    spec="$BATS_TMPDIR/spec_q.json"
    echo '{ "get_children": { "ok": true, "result": { "children": [] } }, "write_html": { "ok": true, "result": {} } }' > "$spec"

    TB_FAKE_CLIENT="$spec" TB_CALL_LOG="$CALL_LOG" \
        run python3 "$WRITER" --repo "$repo" --mapped-file "$mapped_q" --target-node-id "AB-1"
    [ "$status" -eq 0 ]

    html=$(jq -r '[.[] | select(.method=="write_html")][0].args.html' "$CALL_LOG")
    # the raw double-quote must NOT appear inside the font-family value
    [[ "$html" == *"&quot;Helvetica Neue&quot;"* ]]
    # and the style attribute is not prematurely closed by a raw quote
    [[ "$html" != *'font-family: "Helvetica'* ]]
}

# ============================================================================
# SVG FIDELITY (UNIT): an <svg> node carries raw markup (svgHtml) because its
# geometry attributes (d/viewBox/stroke) are not computed styles — walking its
# children would lose the glyph and icons render blank. render_node_html must
# emit svgHtml verbatim. Regression for the live "blank icons" result.
# ============================================================================

@test "svg fidelity: an svgHtml node is emitted verbatim, not walked" {
    repo="$(_write_repo "01TARGETFILE")"
    mapped_svg="$BATS_TMPDIR/mapped_svg.json"
    cat > "$mapped_svg" <<'JSON'
{
  "ok": true, "name": "icon-comp", "theme": "light",
  "root": { "tag": "app-wc-icon", "text": "", "styles": {"display":"flex"}, "children": [
    { "tag": "svg", "text": "", "styles": {}, "svgHtml": "<svg viewBox=\"0 0 24 24\"><path d=\"M6 9l6 6 6-6\" stroke=\"#37d895\"/></svg>", "children": [] }
  ]}
}
JSON
    spec="$BATS_TMPDIR/spec_svg.json"
    echo '{ "get_children": { "ok": true, "result": { "children": [] } }, "write_html": { "ok": true, "result": {} } }' > "$spec"
    TB_FAKE_CLIENT="$spec" TB_CALL_LOG="$CALL_LOG" \
        run python3 "$WRITER" --repo "$repo" --mapped-file "$mapped_svg" --target-node-id "AB-1"
    [ "$status" -eq 0 ]
    html=$(jq -r '[.[] | select(.method=="write_html")][0].args.html' "$CALL_LOG")
    # the svg geometry (the path d) survives into the write payload
    [[ "$html" == *'d="M6 9l6 6 6-6"'* ]]
    [[ "$html" == *"<svg"* ]]
}

# ============================================================================
# IMG FIDELITY (UNIT): an <img> node carries its src (an attribute, not a
# style). render_node_html must emit a real <img src=...> so images aren't
# blank. (An unreachable external src shows Paper's broken-image placeholder —
# correct behavior; a same-origin/data src renders.)
# ============================================================================

@test "img fidelity: an imgSrc node emits a real img with its src" {
    repo="$(_write_repo "01TARGETFILE")"
    mapped_img="$BATS_TMPDIR/mapped_img.json"
    cat > "$mapped_img" <<'JSON'
{
  "ok": true, "name": "avatar-comp", "theme": "light",
  "root": { "tag": "app-wc-avatar", "text": "", "styles": {"display":"flex"}, "children": [
    { "tag": "img", "text": "", "styles": {"width":"40px","height":"40px"}, "imgSrc": "data:image/png;base64,AAAA", "children": [] }
  ]}
}
JSON
    spec="$BATS_TMPDIR/spec_img.json"
    echo '{ "get_children": { "ok": true, "result": { "children": [] } }, "write_html": { "ok": true, "result": {} } }' > "$spec"
    TB_FAKE_CLIENT="$spec" TB_CALL_LOG="$CALL_LOG" \
        run python3 "$WRITER" --repo "$repo" --mapped-file "$mapped_img" --target-node-id "AB-1"
    [ "$status" -eq 0 ]
    html=$(jq -r '[.[] | select(.method=="write_html")][0].args.html' "$CALL_LOG")
    [[ "$html" == *'<img src="data:image/png;base64,AAAA"'* ]]
}
