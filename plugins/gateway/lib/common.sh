#!/usr/bin/env bash
# common.sh — the gateway plugin's shared pure helpers.
#
# WHY THIS EXISTS
# ---------------
# Same reason lib/sanitize.sh exists, applied to the helpers that were missed:
# three byte-identical copies of a function is how one of them silently drifts.
# Each function below was duplicated verbatim in gatewayctl.sh, lens.sh and
# launch.sh (the curl escaper was written out inline twice in gatewayctl.sh
# alone), so a fix to any one of them fixed one surface and left the others.
#
# WHAT DOES *NOT* BELONG HERE
# ---------------------------
# Deliberate duplication that is a decision, not an accident, stays where it is:
#   * the mode-0600 curl --config credential-file builders (KTD6) — each runs in
#     a DIFFERENT process with its own locally-resolved token, and merging them
#     would push a token across a boundary it currently never crosses.
#   * launch.sh's quote-free TOKEN_AWK — it is embedded verbatim in the printed
#     attach command and re-invoked by the user's shell.
#   * the server.token awk parsers, and tmpwork() (whose mktemp template and
#     comment name the script they belong to).
#
# This file prints NOTHING to stderr and holds no diagnostics, which is why it
# does not source sanitize.sh: it has no terminal sink to defend. The
# escapes.bats sink lint still scans it — see the annotated carve-out there.

# ---------------------------------------------------------------------------
# ${VAR} expansion. The gateway expands env references in server.token, so a
# probe that used the literal "${GATEWAY_TOKEN}" text would present a token the
# gateway never issued and read the resulting 401 as "down" (KTD3).
# ---------------------------------------------------------------------------
expand_env_refs() {
    local s="$1" out="" name val
    while [[ "$s" =~ ^([^$]*)\$\{([A-Za-z_][A-Za-z0-9_]*)\}(.*)$ ]]; do
        name="${BASH_REMATCH[2]}"
        val="${!name-}"
        out+="${BASH_REMATCH[1]}${val}"
        s="${BASH_REMATCH[3]}"
    done
    printf '%s' "${out}${s}"
}

# The single stdout write. Every verb/path funnels through here so "exactly one
# JSON object, always" is a property of the code shape rather than of
# discipline. EMITTED stays declared in each sourcing script — a bash function
# reads the caller's globals dynamically, and the guard is that script's state.
#
# An EMPTY payload is refused rather than written. Every caller builds its
# argument with `emit "$(jq ...)"`, and a jq that errors yields the empty string
# with no failure visible at the call site — so emit would write a bare newline,
# set EMITTED, and the script would still exit with whatever code it had, which
# on a healthy gateway is 0. That is the one failure a consumer cannot tell from
# success: exit 0 and nothing to parse. Refusing here closes it for all 18 call
# sites at once instead of per-site; success paths pair this with `|| die`, and
# the error paths fall through to their own pure-bash encoder.
emit() {
    [ "$EMITTED" -eq 1 ] && return 0
    [ -n "$1" ] || return 1
    EMITTED=1
    printf '%s\n' "$1"
}

# curl --config value escaper. Backslash and quote are escaped because curl's
# config parser treats both as significant inside a quoted value.
esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
