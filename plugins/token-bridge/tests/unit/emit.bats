#!/usr/bin/env bats
# Unit tests for lib/emit_tokens.py — the Paper -> CSS reverse direction (U4).
#
# The pure emit (tokens -> CSS) and the R5 round-trip (emit -> parse ->
# build_desired -> diff) are exercised offline via `emit-from-file` and
# `roundtrip` against a fixture Paper token set. The live `run` refuse guards
# (no config, in-place dual-convention) are exercised without a daemon.

setup() {
    SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    EMIT="$SCRIPT_DIR/lib/emit_tokens.py"
    FIXTURE_DIR="$SCRIPT_DIR/tests/fixtures"
    TOKENS="$FIXTURE_DIR/paper_tokens_for_emit.json"
    DA_CONV='[{"type":"data-attribute","attr":"data-theme","value":"dark","primary":true}]'
    MQ_CONV='[{"type":"media-query","query":"(prefers-color-scheme: dark)","primary":true}]'
}

# ============================================================================
# R4 — a base + -dark twin set emits :root + a dark block (data-attribute)
# ============================================================================

@test "emit (data-attribute): base :root block + dark [data-theme] override block" {
    run python3 "$EMIT" emit-from-file --tokens "$TOKENS" --conventions "$DA_CONV" --prefix=--brand-
    [ "$status" -eq 0 ]
    [[ "$output" == *":root {"* ]]
    [[ "$output" == *'--brand-green-500: #37D895;'* ]]
    [[ "$output" == *':root[data-theme="dark"] {'* ]]
    # dark override carries the dark literal
    [[ "$output" == *'--brand-bg: #101010;'* ]]
}

# ============================================================================
# R4 — media-query primary emits an @media block wrapping :root
# ============================================================================

@test "emit (media-query): dark block is @media (prefers-color-scheme: dark) { :root { … } }" {
    run python3 "$EMIT" emit-from-file --tokens "$TOKENS" --conventions "$MQ_CONV" --prefix=--brand-
    [ "$status" -eq 0 ]
    [[ "$output" == *"@media (prefers-color-scheme: dark) {"* ]]
    [[ "$output" == *":root {"* ]]
}

# ============================================================================
# KTD4 — the dark alias referent is de-suffixed: var(--x-dark) -> var(--x)
# ============================================================================

@test "emit: a dark alias stored as var(--…-dark) emits as var(--…) in the dark scope" {
    run python3 "$EMIT" emit-from-file --tokens "$TOKENS" --conventions "$DA_CONV" --prefix=--brand-
    [ "$status" -eq 0 ]
    # accent's dark twin is var(--brand-green-500-dark) in Paper; emitted dark
    # scope must reference the plain name, NOT the -dark twin.
    [[ "$output" == *'--brand-accent: var(--brand-green-500);'* ]]
    [[ "$output" != *'var(--brand-green-500-dark)'* ]]
}

# ============================================================================
# R4 — base aliases keep the var() form, not a resolved literal
# ============================================================================

@test "emit: a base alias stored as var(--x) emits as var(--x), not the resolved literal" {
    run python3 "$EMIT" emit-from-file --tokens "$TOKENS" --conventions "$DA_CONV" --prefix=--brand-
    [ "$status" -eq 0 ]
    # accent's base value is var(--brand-green-500); it must not resolve to #37D895
    base_line=$(echo "$output" | grep -m1 -- '--brand-accent:')
    [[ "$base_line" == *'var(--brand-green-500)'* ]]
}

# ============================================================================
# Edge — a token with no -dark twin emits base-only
# ============================================================================

@test "emit: a base-only token (no -dark twin) appears only in :root, not the dark block" {
    run python3 "$EMIT" emit-from-file --tokens "$TOKENS" --conventions "$DA_CONV" --prefix=--brand-
    [ "$status" -eq 0 ]
    [[ "$output" == *'--brand-radius: 8px;'* ]]
    # only one occurrence (base), none in the dark scope
    count=$(echo "$output" | grep -c -- '--brand-radius:')
    [ "$count" -eq 1 ]
}

# ============================================================================
# R5 — the round-trip is a token-model fixed point (empty diff)
# ============================================================================

@test "roundtrip (data-attribute): emit -> parse -> build_desired -> diff is empty" {
    run python3 "$EMIT" roundtrip --tokens "$TOKENS" --conventions "$DA_CONV" --prefix=--brand-
    [ "$status" -eq 0 ]
    empty=$(echo "$output" | jq -r '.empty')
    [ "$empty" = "true" ]
    # no creates/updates/deletes/recreates
    n=$(echo "$output" | jq '[.diff.creates, .diff.updates, .diff.deletes, .diff.recreates] | map(length) | add')
    [ "$n" -eq 0 ]
}

@test "roundtrip (media-query): emit -> parse -> build_desired -> diff is empty" {
    run python3 "$EMIT" roundtrip --tokens "$TOKENS" --conventions "$MQ_CONV" --prefix=--brand-
    [ "$status" -eq 0 ]
    empty=$(echo "$output" | jq -r '.empty')
    [ "$empty" = "true" ]
}

# ============================================================================
# Safety — refuse without a config; refuse in-place emit onto a dual-convention
# source (KTD7). Neither touches the daemon.
# ============================================================================

@test "run: --repo with no config refuses (no_config), writes nothing" {
    empty="$BATS_TMPDIR/emit_no_config"
    mkdir -p "$empty"
    # refused path logs a diagnostic to stderr; drop it so $output is pure JSON.
    run bash -c "python3 '$EMIT' run --repo '$empty' 2>/dev/null"
    [ "$status" -eq 2 ]
    err=$(echo "$output" | jq -r '.error')
    [ "$err" = "no_config" ]
}

@test "run: in-place emit onto a dual-convention source refuses (KTD7), no daemon call" {
    repo="$BATS_TMPDIR/emit_inplace_dual"
    mkdir -p "$repo/styles"
    printf ':root{}\n' > "$repo/styles/tokens.css"
    cat > "$repo/token-bridge.config.json" <<'JSON'
{
  "fileId": "somefile",
  "source": { "path": "styles/tokens.css" },
  "emitTarget": "styles/tokens.css",
  "themeConventions": [
    { "type": "data-attribute", "attr": "data-theme", "value": "dark", "primary": true },
    { "type": "media-query", "query": "(prefers-color-scheme: dark)" }
  ]
}
JSON
    # Dead daemon: if it reached the network the error would differ; KTD7 fires first.
    PAPER_MCP_URL="http://127.0.0.1:1/mcp" run python3 "$EMIT" run --repo "$repo" --url "http://127.0.0.1:1/mcp"
    [ "$status" -eq 4 ]
    err=$(echo "$output" | jq -r '.error')
    [ "$err" = "refused_in_place_dual_convention" ]
    # the source file was not overwritten
    [ "$(cat "$repo/styles/tokens.css")" = ":root{}" ]
}