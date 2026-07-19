#!/usr/bin/env bats
# Unit tests for lib/paper_client.py
#
# The SSE parser and JSON-RPC response interpreter are exercised through the
# `parse-sse` subcommand, which reads an SSE-framed body from a file/stdin and
# prints the caller-facing envelope as JSON — no live daemon required.
#
# The fail-soft transport path is exercised by pointing the client at a dead
# local port (connection refused) via $PAPER_MCP_URL.

setup() {
    SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    CLIENT="$SCRIPT_DIR/lib/paper_client.py"
    FIXTURE_DIR="$SCRIPT_DIR/tests/fixtures"
}

# ============================================================================
# Happy path — single data: line parses to the inner tokens payload
# ============================================================================

@test "parse-sse: happy path extracts tokens array from a single data line" {
    run python3 "$CLIENT" parse-sse "$FIXTURE_DIR/sse_get_tokens.txt"
    [ "$status" -eq 0 ]

    ok=$(echo "$output" | jq -r '.ok')
    [ "$ok" = "true" ]

    # The inner JSON string (result.content[0].text) is parsed a second time,
    # so the tokens array surfaces under .result.tokens
    count=$(echo "$output" | jq '.result.tokens | length')
    [ "$count" -eq 1 ]

    name=$(echo "$output" | jq -r '.result.tokens[0].name')
    [ "$name" = "--wcs-accent" ]

    value=$(echo "$output" | jq -r '.result.tokens[0].value')
    [ "$value" = "#37D895" ]
}

@test "parse-sse: reads the SSE body from stdin too" {
    run bash -c "python3 '$CLIENT' parse-sse < '$FIXTURE_DIR/sse_get_tokens.txt'"
    [ "$status" -eq 0 ]

    name=$(echo "$output" | jq -r '.result.tokens[0].name')
    [ "$name" = "--wcs-accent" ]
}

# ============================================================================
# Edge — chunked / multi-line SSE: preamble lines + data split across lines
# ============================================================================

@test "parse-sse: multi-line preamble and split data lines yield the full payload" {
    cat > "$BATS_TMPDIR/chunked.txt" <<'SSE'
: keep-alive comment
event: message
id: 42
retry: 3000
data: {"result":{"content":[{"type":"text","text":
data: "{\"tokens\":[{\"name\":\"--wcs-brand\",\"type\":\"color\",\"value\":\"#000000\"}]}"}]}}
SSE
    run python3 "$CLIENT" parse-sse "$BATS_TMPDIR/chunked.txt"
    [ "$status" -eq 0 ]

    ok=$(echo "$output" | jq -r '.ok')
    [ "$ok" = "true" ]

    name=$(echo "$output" | jq -r '.result.tokens[0].name')
    [ "$name" = "--wcs-brand" ]

    value=$(echo "$output" | jq -r '.result.tokens[0].value')
    [ "$value" = "#000000" ]
}

# ============================================================================
# Error — JSON-RPC error object is surfaced, not swallowed as success
# ============================================================================

@test "parse-sse: a JSON-RPC error response becomes an error envelope" {
    cat > "$BATS_TMPDIR/rpc_error.txt" <<'SSE'
event: message
data: {"jsonrpc":"2.0","id":3,"error":{"code":-32602,"message":"Invalid params: unknown fileId"}}
SSE
    run python3 "$CLIENT" parse-sse "$BATS_TMPDIR/rpc_error.txt"
    # error envelope -> non-zero, distinct from unreachable (3) and bad-args (2)
    [ "$status" -eq 4 ]

    ok=$(echo "$output" | jq -r '.ok')
    [ "$ok" = "false" ]

    err=$(echo "$output" | jq -r '.error')
    [ "$err" = "jsonrpc_error" ]

    # the underlying daemon message is preserved, not discarded
    msg=$(echo "$output" | jq -r '.note')
    [[ "$msg" == *"unknown fileId"* ]]

    code=$(echo "$output" | jq -r '.rpc_error.code')
    [ "$code" = "-32602" ]
}

@test "parse-sse: a body with no data line is a bad_sse error envelope" {
    cat > "$BATS_TMPDIR/no_data.txt" <<'SSE'
event: message
: just a comment, no data line
SSE
    run python3 "$CLIENT" parse-sse "$BATS_TMPDIR/no_data.txt"
    [ "$status" -eq 4 ]

    err=$(echo "$output" | jq -r '.error')
    [ "$err" = "bad_sse" ]
}

# ============================================================================
# Error — connection refused: fail-soft daemon_unreachable, distinct exit code
# ============================================================================

@test "get-tokens: daemon down returns daemon_unreachable envelope (exit 3)" {
    # Port 1 refuses immediately on localhost. Diagnostics go to stderr, so
    # drop it here to keep $output as the pure JSON stdout line for jq.
    PAPER_MCP_URL="http://127.0.0.1:1/mcp" run bash -c "python3 '$CLIENT' --timeout 3 get-tokens someFileId 2>/dev/null"
    [ "$status" -eq 3 ]

    ok=$(echo "$output" | jq -r '.ok')
    [ "$ok" = "false" ]

    err=$(echo "$output" | jq -r '.error')
    [ "$err" = "daemon_unreachable" ]
}

# ============================================================================
# Bad args — distinct exit code from a connection failure
# ============================================================================

@test "no subcommand exits with the bad-args code (2), not the unreachable code" {
    run python3 "$CLIENT"
    [ "$status" -eq 2 ]
}

@test "set-tokens with malformed --tokens-json exits with the bad-args code (2)" {
    # Point at a dead URL so a *successful* parse would still fail-soft; we want
    # to prove the arg error is caught BEFORE any network call and is distinct.
    PAPER_MCP_URL="http://127.0.0.1:1/mcp" run python3 "$CLIENT" set-tokens f --tokens-json 'not json'
    [ "$status" -eq 2 ]
}

# ============================================================================
# MCP tool-execution failure — isError:true must NOT be reported as success
# ============================================================================

@test "interpret: an isError:true tool result becomes a tool_error envelope, not ok" {
    run python3 "$CLIENT" parse-sse "$FIXTURE_DIR/sse_tool_error.txt"
    # exit code is the generic error code, not ok
    [ "$status" -eq 4 ]
    ok=$(echo "$output" | jq -r '.ok')
    [ "$ok" = "false" ]
    err=$(echo "$output" | jq -r '.error')
    [ "$err" = "tool_error" ]
    # the tool's error text is surfaced in note, not swallowed
    note=$(echo "$output" | jq -r '.note')
    [[ "$note" == *"invalid fileId"* ]]
}

# ============================================================================
# Mutating calls refuse an empty fileId (defense in depth for the reconcile)
# ============================================================================

@test "set-tokens with an empty fileId refuses (no_target_file), makes no network call" {
    # dead port: if it reached the network it would report daemon_unreachable (3)
    PAPER_MCP_URL="http://127.0.0.1:1/mcp" run python3 "$CLIENT" set-tokens "" --tokens-json '[]'
    ok=$(echo "$output" | jq -r '.ok')
    [ "$ok" = "false" ]
    err=$(echo "$output" | jq -r '.error')
    [ "$err" = "no_target_file" ]
}

# ============================================================================
# read-config — the --repo bootstrap (KTD8): load <repo>/token-bridge.config.json,
# resolve source/emitTarget relative to <repo>, and refuse without a fileId.
# ============================================================================

@test "read-config: happy path loads config, resolves paths relative to --repo" {
    # The fixtures dir doubles as a --repo (it holds token-bridge.config.json).
    run python3 "$CLIENT" read-config --repo "$FIXTURE_DIR"
    [ "$status" -eq 0 ]

    ok=$(echo "$output" | jq -r '.ok')
    [ "$ok" = "true" ]

    fid=$(echo "$output" | jq -r '.result.fileId')
    [ "$fid" = "FIXTUREFILEID123" ]

    # source + emitTarget are resolved absolute, under the repo root.
    src=$(echo "$output" | jq -r '.result.source')
    [ "$src" = "$FIXTURE_DIR/src/styles/tokens.css" ]

    emit=$(echo "$output" | jq -r '.result.emitTarget')
    [ "$emit" = "$FIXTURE_DIR/src/styles/tokens.generated.css" ]

    prefix=$(echo "$output" | jq -r '.result.prefix')
    [ "$prefix" = "--brand-" ]
}

@test "read-config: --repo with no config file returns no_config, not a crash" {
    empty="$BATS_TMPDIR/empty_repo"
    mkdir -p "$empty"
    run python3 "$CLIENT" read-config --repo "$empty"
    [ "$status" -eq 4 ]
    err=$(echo "$output" | jq -r '.error')
    [ "$err" = "no_config" ]
}

@test "read-config: config present but empty fileId refuses with no_target_file" {
    repo="$BATS_TMPDIR/no_fileid_repo"
    mkdir -p "$repo"
    cat > "$repo/token-bridge.config.json" <<'JSON'
{ "fileId": "", "source": { "path": "a.css" } }
JSON
    run python3 "$CLIENT" read-config --repo "$repo"
    [ "$status" -eq 4 ]
    err=$(echo "$output" | jq -r '.error')
    [ "$err" = "no_target_file" ]
}

@test "read-config: a non-string prefix is rejected with an actionable bad_config" {
    repo="$BATS_TMPDIR/bad_prefix_repo"
    mkdir -p "$repo"
    cat > "$repo/token-bridge.config.json" <<'JSON'
{ "fileId": "x", "source": { "path": "a.css", "prefix": 42 } }
JSON
    run python3 "$CLIENT" read-config --repo "$repo"
    [ "$status" -eq 4 ]
    err=$(echo "$output" | jq -r '.error')
    [ "$err" = "bad_config" ]
    note=$(echo "$output" | jq -r '.note')
    [[ "$note" == *"prefix"* ]]
}

@test "read-config: a malformed themeConventions entry is rejected with bad_config" {
    repo="$BATS_TMPDIR/bad_conv_repo"
    mkdir -p "$repo"
    # data-attribute missing its required 'value'
    cat > "$repo/token-bridge.config.json" <<'JSON'
{ "fileId": "x", "themeConventions": [ { "type": "data-attribute", "attr": "data-theme" } ] }
JSON
    run python3 "$CLIENT" read-config --repo "$repo"
    [ "$status" -eq 4 ]
    err=$(echo "$output" | jq -r '.error')
    [ "$err" = "bad_config" ]
}

# ============================================================================
# themeConventions: the three named types are the whole public surface (KTD2a).
# The predicate `match:[…]` form is internal — what the named types desugar to,
# never something a user authors — so the validator must refuse it.
# ============================================================================

@test "read-config: a class convention validates" {
    repo="$BATS_TMPDIR/class_conv_repo"
    mkdir -p "$repo"
    cat > "$repo/token-bridge.config.json" <<'JSON'
{ "fileId": "x", "themeConventions": [ { "type": "class", "class": "wcs-dark" } ] }
JSON
    run python3 "$CLIENT" read-config --repo "$repo"
    [ "$status" -eq 0 ]
    ok=$(echo "$output" | jq -r '.ok')
    [ "$ok" = "true" ]
    cls=$(echo "$output" | jq -r '.result.themeConventions[0].class')
    [ "$cls" = "wcs-dark" ]
}

@test "read-config: a class convention desugars to a one-predicate match" {
    run python3 -c "
import json, sys
sys.path.insert(0, '$SCRIPT_DIR/lib')
from parse_tokens import desugar_convention
print(json.dumps(desugar_convention({'type': 'class', 'class': 'wcs-dark'})))
"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq 'length')" = "1" ]
    [ "$(echo "$output" | jq -r '.[0].class')" = "wcs-dark" ]
}

@test "read-config: a class convention with no 'class' is rejected, naming the field" {
    repo="$BATS_TMPDIR/class_noclass_repo"
    mkdir -p "$repo"
    cat > "$repo/token-bridge.config.json" <<'JSON'
{ "fileId": "x", "themeConventions": [ { "type": "class" } ] }
JSON
    run python3 "$CLIENT" read-config --repo "$repo"
    [ "$status" -eq 4 ]
    err=$(echo "$output" | jq -r '.error')
    [ "$err" = "bad_config" ]
    note=$(echo "$output" | jq -r '.note')
    [[ "$note" == *"class"* ]]
}

@test "read-config: a class convention with an empty 'class' is rejected" {
    repo="$BATS_TMPDIR/class_emptyclass_repo"
    mkdir -p "$repo"
    cat > "$repo/token-bridge.config.json" <<'JSON'
{ "fileId": "x", "themeConventions": [ { "type": "class", "class": "" } ] }
JSON
    run python3 "$CLIENT" read-config --repo "$repo"
    [ "$status" -eq 4 ]
    err=$(echo "$output" | jq -r '.error')
    [ "$err" = "bad_config" ]
    note=$(echo "$output" | jq -r '.note')
    [[ "$note" == *"class"* ]]
}

@test "read-config: a user-authored predicate 'match' is rejected (internal form stays internal)" {
    repo="$BATS_TMPDIR/user_match_repo"
    mkdir -p "$repo"
    cat > "$repo/token-bridge.config.json" <<'JSON'
{ "fileId": "x", "themeConventions": [ { "match": [ { "class": "wcs-theme" }, { "class": "wcs-dark" } ] } ] }
JSON
    run python3 "$CLIENT" read-config --repo "$repo"
    [ "$status" -eq 4 ]
    err=$(echo "$output" | jq -r '.error')
    [ "$err" = "bad_config" ]
    note=$(echo "$output" | jq -r '.note')
    # Names the three accepted types...
    [[ "$note" == *"class"* ]]
    [[ "$note" == *"data-attribute"* ]]
    [[ "$note" == *"media-query"* ]]
    # ...and names 'match' as the thing to remove. Someone who WROTE match
    # already knows it exists; withholding it just sends them to the wrong fix.
    # What the message must not do is document match's shape or present it as a
    # supported alternative.
    [[ "$note" == *"match"* ]]
    [[ "$note" == *"not user-authorable"* ]]
}

@test "read-config: a 'match' smuggled alongside a valid type is still rejected" {
    # desugar_convention checks 'match' FIRST, so a match riding along with a
    # named type would silently win — the named type is not enough of a gate.
    repo="$BATS_TMPDIR/smuggled_match_repo"
    mkdir -p "$repo"
    cat > "$repo/token-bridge.config.json" <<'JSON'
{ "fileId": "x", "themeConventions": [ { "type": "class", "class": "wcs-dark", "match": [ { "attr": "data-x", "value": "y" } ] } ] }
JSON
    run python3 "$CLIENT" read-config --repo "$repo"
    [ "$status" -eq 4 ]
    err=$(echo "$output" | jq -r '.error')
    [ "$err" = "bad_config" ]
    # The message must point at 'match', not at the type — reporting
    # "type must be … 'class', got 'class'" is self-contradictory and sends the
    # reader to the wrong fix.
    note=$(echo "$output" | jq -r '.note')
    [[ "$note" == *"internal 'match' form"* ]]
    [[ "$note" != *"got 'class'"* ]]
}

@test "read-config: backward compat — data-attribute and media-query configs still validate" {
    repo="$BATS_TMPDIR/backcompat_conv_repo"
    mkdir -p "$repo"
    cat > "$repo/token-bridge.config.json" <<'JSON'
{ "fileId": "x", "themeConventions": [
  { "type": "data-attribute", "attr": "data-theme", "value": "dark", "primary": true },
  { "type": "media-query", "query": "(prefers-color-scheme: dark)" }
] }
JSON
    run python3 "$CLIENT" read-config --repo "$repo"
    [ "$status" -eq 0 ]
    ok=$(echo "$output" | jq -r '.ok')
    [ "$ok" = "true" ]
    [ "$(echo "$output" | jq -r '.result.themeConventions[0].type')" = "data-attribute" ]
    [ "$(echo "$output" | jq -r '.result.themeConventions[1].type')" = "media-query" ]
}

@test "read-config: a media-query desugars to a two-predicate conjunction with the :root anchor" {
    # Conjunction machinery ships and runs on every media-query config even
    # though no user can author a conjunction directly (KTD2a).
    run python3 -c "
import json, sys
sys.path.insert(0, '$SCRIPT_DIR/lib')
from parse_tokens import desugar_convention
print(json.dumps(desugar_convention({'type': 'media-query', 'query': '(prefers-color-scheme: dark)'})))
"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq 'length')" = "2" ]
    [ "$(echo "$output" | jq -r '.[0].media')" = "(prefers-color-scheme: dark)" ]
    [ "$(echo "$output" | jq -r '.[1].selector')" = ":root" ]
}

@test "read-config: an unknown convention type is rejected naming all three accepted types" {
    repo="$BATS_TMPDIR/unknown_conv_repo"
    mkdir -p "$repo"
    cat > "$repo/token-bridge.config.json" <<'JSON'
{ "fileId": "x", "themeConventions": [ { "type": "attribute-selector", "sel": "[dark]" } ] }
JSON
    run python3 "$CLIENT" read-config --repo "$repo"
    [ "$status" -eq 4 ]
    note=$(echo "$output" | jq -r '.note')
    [[ "$note" == *"data-attribute"* ]]
    [[ "$note" == *"media-query"* ]]
    [[ "$note" == *"class"* ]]
}

@test "read-config: two conventions without exactly one primary is rejected" {
    repo="$BATS_TMPDIR/dual_no_primary_repo"
    mkdir -p "$repo"
    cat > "$repo/token-bridge.config.json" <<'JSON'
{ "fileId": "x", "themeConventions": [
  { "type": "data-attribute", "attr": "data-theme", "value": "dark" },
  { "type": "media-query", "query": "(prefers-color-scheme: dark)" }
] }
JSON
    run python3 "$CLIENT" read-config --repo "$repo"
    [ "$status" -eq 4 ]
    err=$(echo "$output" | jq -r '.error')
    [ "$err" = "bad_config" ]
    note=$(echo "$output" | jq -r '.note')
    [[ "$note" == *"primary"* ]]
}
