#!/usr/bin/env bash
# The read-only herdr accessor. Sourced, never executed.
#
# READ-ONLY IS A HARD BOUNDARY. Nothing in this file may invoke a mutating
# herdr verb — create, split, move, swap, close, rename, focus, run,
# send-keys, resize, zoom, report-metadata, report-agent. Two verbs are used
# here and no others: `status server` and `api snapshot`. Writes live in their
# own file so this one can be read by anybody who needs to know whether a call
# can disturb the user's terminal, and the answer is always no.
#
# No `set -e` and no `set -o pipefail` here: this file is sourced into callers
# with their own options, and turning either on for them changes their control
# flow. Every expansion is `${VAR:-}` so a caller running `set -u` is safe.

# Order: an explicit HERDR_BIN override, then PATH, then a list of known
# install locations.
#
# Every candidate — the override included — must be a regular file AND
# executable. `-x` alone is true of a DIRECTORY, so HERDR_BIN=/opt/homebrew/bin
# would otherwise "resolve" and hand the caller a directory to run. A SET
# override that fails the test resolves to EMPTY and deliberately does NOT fall
# through to PATH: someone who named a binary meant that binary, and quietly
# driving a different one is worse than not running at all.

herdr_linear::_bin_usable() { [ -n "${1:-}" ] && [ -f "$1" ] && [ -x "$1" ]; }

# Resolved through the parent directory rather than by gluing $PWD on the
# front: `HERDR_BIN=./herdr` that way yields ".../opt/./herdr", which runs but
# fails any comparison a caller makes against the path it expected.
herdr_linear::_abspath() {
    local p="${1:-}" d b
    [ -n "$p" ] || return 0
    d="$(dirname "$p")"
    b="$(basename "$p")"
    d="$(cd "$d" 2>/dev/null && pwd -P)" || { printf '%s' "$p"; return 0; }
    printf '%s/%s' "${d%/}" "$b"
}

# Splitting is pure parameter expansion, deliberately: a resolver whose whole
# purpose is to not depend on PATH must not shell out to `tr` or `sed` to do
# the splitting, or it dies of "tr: command not found" on the very path it
# exists to survive.
herdr_linear::_scan() {
    local rest="${1:-}" suffix="${2:-}" head
    while [ -n "$rest" ]; do
        head="${rest%%:*}"
        if [ "$head" = "$rest" ]; then rest=""; else rest="${rest#*:}"; fi
        [ -n "$head" ] || continue
        head="${head%/}$suffix"
        if herdr_linear::_bin_usable "$head"; then printf '%s' "$head"; return 0; fi
    done
    return 1
}

# `${VAR-default}`, NOT `${VAR:-default}`: an explicitly EMPTY
# HERDR_LINEAR_BIN_PATHS must mean "no known locations". The knob exists so a
# test can guarantee nothing resolves; with `:-` a caller that set it to ""
# would get /opt/homebrew/bin back and resolve the host's real herdr, passing
# for the wrong reason.
herdr_linear::_bin_paths() {
    printf '%s' "${HERDR_LINEAR_BIN_PATHS-/opt/homebrew/bin:/usr/local/bin:${HOME:-}/.local/bin}"
}

# Echoes a validated ABSOLUTE path, or nothing. Never fails and never writes to
# stderr — deciding what an empty result MEANS belongs to the caller. Absolute
# because resolution may happen before a caller changes directory, and a
# relative candidate would stop resolving the moment the cwd moved.
herdr_linear::bin() {
    local override="${HERDR_BIN:-}" cand
    if [ -n "$override" ]; then
        herdr_linear::_bin_usable "$override" && herdr_linear::_abspath "$override"
        return 0
    fi
    cand="$(command -v herdr 2>/dev/null)"
    if herdr_linear::_bin_usable "${cand:-}"; then herdr_linear::_abspath "$cand"; return 0; fi
    if cand="$(herdr_linear::_scan "$(herdr_linear::_bin_paths)" "/herdr")"; then
        herdr_linear::_abspath "$cand"
        return 0
    fi
    return 0
}

# The override that was thrown out, so a diagnostic can name it. Derived rather
# than exported by herdr_linear::bin, because that runs in a command
# substitution and a subshell cannot set a variable its caller would see. The
# contract makes the derivation exact: a set override that passed the usable
# test yields a non-empty path, so "override set AND result empty" is precisely
# the rejected case.
herdr_linear::bin_rejected() {
    local override="${HERDR_BIN:-}"
    [ -n "$override" ] && [ -z "$(herdr_linear::bin)" ] && printf '%s' "$override"
    return 0
}

# herdr must NEVER be piped into an early-exiting reader to decide liveness.
# `grep -q` exits the instant it matches and closes the pipe, so herdr dies
# mid-write and exits non-zero — and under a caller's `set -o pipefail` that
# non-zero becomes the pipeline's status, so the probe returns FALSE on a match
# that already succeeded. Measured at 80-94 failures per 300 against a live
# server. Capture first, then test the text.
#
# Do not look for one exit code: the signature is not stable across herdr
# releases. Observed 101 (a Rust broken-pipe panic) on 0.8.0 and 141 (plain
# SIGPIPE) on 0.8.2. Capturing first is correct for any of them, because no
# exit status reaches a conditional at all.
#
# The match is an exact `status: running` LINE, not a substring: `grep -qi
# running` also accepts "not running". herdr prints five lines and the match
# may not be the first, so both sides are wrapped in newlines and one glob
# matches an exact line anywhere.

HERDR_LINEAR_PROBE_OUT=""
HERDR_LINEAR_PROBE_ERR=""

herdr_linear::probe() {
    local bin err
    bin="$(herdr_linear::bin)"
    HERDR_LINEAR_PROBE_OUT=""
    HERDR_LINEAR_PROBE_ERR=""
    [ -n "$bin" ] || return 1

    err="$(mktemp 2>/dev/null)" || err="${TMPDIR:-/tmp}/herdr-linear-probe.$$"
    if : >"$err" 2>/dev/null; then
        HERDR_LINEAR_PROBE_OUT="$("$bin" status server 2>"$err" || true)"
        HERDR_LINEAR_PROBE_ERR="$(cat "$err" 2>/dev/null || true)"
        rm -f "$err"
    else
        # No writable scratch file. Keep stdout — the match input — intact.
        HERDR_LINEAR_PROBE_OUT="$("$bin" status server 2>/dev/null || true)"
    fi

    case $'\n'"$HERDR_LINEAR_PROBE_OUT"$'\n' in
        *$'\nstatus: running\n'*) return 0 ;;
        *) return 1 ;;
    esac
}

# herdr exports these into every pane it owns, so a snapshot walk to learn
# where this session already knows it is would be a round trip for an answer
# already in hand — and one that can fail when the server is busy.

# The environment carries this pane's identity AT LAUNCH, which stops being its
# identity the moment the pane is moved to another workspace: herdr keeps the
# old id resolving for the moved process, but `api snapshot` reports the new
# one. So the env value is an alias, and matching it against snapshot data
# silently finds nothing -- which is exactly how pane_id and tab_of_pane
# compose. One cheap `pane get` resolves the alias; it is still not a snapshot
# walk. When herdr cannot answer, the env value is returned unchanged, because
# a wrong-but-present id degrades better here than an empty one.
# All three fields come from ONE `pane get` on the pane id. Resolving a tab or
# workspace id by passing IT to `pane get` cannot work -- that verb takes a pane
# -- so the call fails and the stale env value is returned, which is the bug
# this function exists to remove and looks identical to success.
herdr_linear::_resolve_position() {
    local field="$1" env_value="$2" bin out
    [ -n "$env_value" ] || return 1
    bin="$(herdr_linear::bin)"
    if [ -n "$bin" ] && [ -n "${HERDR_PANE_ID:-}" ]; then
        out="$("$bin" pane get "$HERDR_PANE_ID" 2>/dev/null | herdr_linear::json "result.pane.$field")"
        if [ -n "$out" ]; then printf '%s' "$out"; return 0; fi
    fi
    printf '%s' "$env_value"
}

herdr_linear::pane_id()      { herdr_linear::_resolve_position pane_id      "${HERDR_PANE_ID:-}"; }
herdr_linear::tab_id()       { herdr_linear::_resolve_position tab_id       "${HERDR_TAB_ID:-}"; }
herdr_linear::workspace_id() { herdr_linear::_resolve_position workspace_id "${HERDR_WORKSPACE_ID:-}"; }


# The whole snapshot, as JSON, on stdout. The only reason to reach for this is
# a question about NEIGHBOURS — which tab a pane sits in, which other panes
# share it. Anything about this session's own position comes from the
# environment above.
herdr_linear::snapshot() {
    local bin
    bin="$(herdr_linear::bin)"
    [ -n "$bin" ] || return 1
    "$bin" api snapshot 2>/dev/null
}

# herdr_linear::json <dotted.path> — read one field from JSON on stdin.
# Numeric segments index arrays: result.snapshot.panes.0.pane_id. jq when
# present, python3 as the portable fallback. Empty output for any miss.
herdr_linear::json() {
    local path="${1:-}"
    if command -v jq >/dev/null 2>&1; then
        local seg expr=""
        local IFS=.
        for seg in $path; do
            case "$seg" in
                ''|*[!0-9]*) expr="$expr[\"$seg\"]" ;;
                *) expr="$expr[$seg]" ;;
            esac
        done
        jq -r "try (.$expr) // empty" 2>/dev/null
    else
        HERDR_LINEAR_JPATH="$path" python3 -c '
import sys, json, os
try:
    d = json.load(sys.stdin)
    for k in os.environ["HERDR_LINEAR_JPATH"].split("."):
        d = d[int(k)] if isinstance(d, list) else d[k]
    sys.stdout.write("" if d is None else str(d))
except Exception:
    sys.stdout.write("")
' 2>/dev/null
    fi
}

# The snapshot is captured to a variable before it is filtered, for the same
# reason the probe is: a filter that stops reading early kills herdr mid-write.
herdr_linear::_pane_field() {
    local match_key="$1" match_val="$2" want="$3" snap
    snap="$(herdr_linear::snapshot)" || return 1
    [ -n "$snap" ] || return 1
    local out
    if command -v jq >/dev/null 2>&1; then
        out="$(printf '%s' "$snap" | jq -r --arg k "$match_key" --arg v "$match_val" --arg w "$want" \
            '.result.snapshot.panes[]? | select(.[$k] == $v) | .[$w] // empty' 2>/dev/null)"
    else
        out="$(printf '%s' "$snap" | HL_K="$match_key" HL_V="$match_val" HL_W="$want" python3 -c '
import sys, json, os
try:
    panes = json.load(sys.stdin)["result"]["snapshot"]["panes"]
    for p in panes:
        if p.get(os.environ["HL_K"]) == os.environ["HL_V"]:
            v = p.get(os.environ["HL_W"])
            if v is not None:
                print(v)
except Exception:
    pass
' 2>/dev/null)"
    fi
    [ -n "$out" ] || return 1
    printf '%s' "$out"
}

# Which tab a pane sits in.
herdr_linear::tab_of_pane() {
    [ -n "${1:-}" ] || return 1
    herdr_linear::_pane_field pane_id "$1" tab_id
}

# That tab's panes, one id per line, in snapshot order.
herdr_linear::panes_in_tab() {
    [ -n "${1:-}" ] || return 1
    herdr_linear::_pane_field tab_id "$1" pane_id
}
