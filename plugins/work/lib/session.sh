#!/usr/bin/env bash
# Which herdr session this process runs in, and where that session's records
# live. Sourced, never executed.
#
# herdr ids are scoped to one server: two named sessions both have a workspace
# `w1`. A record keyed by a herdr id is only meaningful inside the session that
# wrote it, so every such record is stored under its session (KTD3).
#
# The name comes from the socket path herdr hands every pane and plugin process
# (KTD1). herdr has no request that answers it. The herdr home follows
# XDG_CONFIG_HOME, so the rule matches the path's tail, never a fixed home.
# A path of any other shape is no session, never a guess: a wrong answer would
# apply one session's records in another.

command -v herdr_linear::is_safe_identifier >/dev/null 2>&1 \
    || . "${BASH_SOURCE[0]%/*}/sanitize.sh"

HERDR_LINEAR_STORE_DIR="${HERDR_LINEAR_STORE_DIR:-$HOME/.claude/work}"

# herdr_linear::session_from_socket <socket path>
herdr_linear::session_from_socket() {
    local p="${1:-}" rest name
    case "$p" in
        */herdr/herdr.sock) printf 'default'; return 0 ;;
        */herdr/sessions/*/herdr.sock) ;;
        *) return 1 ;;
    esac
    rest="${p%/herdr.sock}"
    name="${rest##*/}"
    [ "$rest" = "${p%/herdr/sessions/*/herdr.sock}/herdr/sessions/$name" ] || return 1
    herdr_linear::is_safe_identifier "$name" || return 1
    printf '%s' "$name"
}

# A set HERDR_SOCKET_PATH is authoritative even when it fails the rule: falling
# back to the server's socket would name a session this pane is not in.
herdr_linear::session_name() {
    local sock line
    if [ -n "${HERDR_SOCKET_PATH:-}" ]; then
        herdr_linear::session_from_socket "$HERDR_SOCKET_PATH"
        return
    fi
    command -v herdr_linear::probe >/dev/null 2>&1 \
        || . "${BASH_SOURCE[0]%/*}/herdr-read.sh"
    herdr_linear::probe || return 1
    while IFS= read -r line; do
        case "$line" in
            socket:*) sock="${line#socket:}"; sock="${sock# }" ;;
        esac
    done <<EOF
$HERDR_LINEAR_PROBE_OUT
EOF
    [ -n "${sock:-}" ] || return 1
    herdr_linear::session_from_socket "$sock"
}

# The default session keeps today's flat paths, so records written before
# sessions existed keep applying where they were made (R17).
herdr_linear::session_store_root() {
    local name
    name="$(herdr_linear::session_name)" || return 1
    [ -n "$name" ] || return 1
    if [ "$name" = default ]; then
        printf '%s' "$HERDR_LINEAR_STORE_DIR"
    else
        printf '%s/sessions/%s' "$HERDR_LINEAR_STORE_DIR" "$name"
    fi
}
