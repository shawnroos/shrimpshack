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
