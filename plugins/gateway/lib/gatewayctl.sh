#!/usr/bin/env bash
# gatewayctl.sh — the gateway plugin's own control layer (plan U2).
#
#   gatewayctl.sh start            start the gateway if it is not already up
#   gatewayctl.sh stop             stop the gateway we started
#   gatewayctl.sh restart          stop (tolerating "not running") then start
#   gatewayctl.sh status           liveness, served aliases, install dir, drift
#   gatewayctl.sh ensure [alias]   the preflight lens.sh and launch.sh call
#
# CONTRACT (KTD2 owns it; this file implements it, it does not redefine it):
#   exactly one JSON object on stdout, always; diagnostics on stderr only.
#   exit 0 ok · 2 usage/refusal · 3 unreachable and could not start ·
#        4 alias unknown · 5 upstream provider error · 6 deadline exceeded ·
#        7 gateway reachable but rejected our token.
#
# set -e is deliberately OFF (only -u -o pipefail). Every failure path in this
# script is an exit code the contract names; letting bash exit on the first
# non-zero command would turn a classified 7 or 4 into an unclassified 1.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# KTD5. Sourced, not re-implemented: three copies of a sanitizer is how one of
# them silently drifts, which is precisely the failure the escape-audit
# precedent records. See README.md for the source x sink matrix.
# shellcheck source=./sanitize.sh
. "$SCRIPT_DIR/sanitize.sh"

# ---------------------------------------------------------------------------
# Contract constants
# ---------------------------------------------------------------------------
EX_OK=0
EX_USAGE=2
EX_UNREACHABLE=3
EX_ALIAS=4
# EX_UPSTREAM=5 and EX_DEADLINE=6 belong to the lens (U3); named here only so
# the enum reads whole in one place.
EX_AUTH=7

# ---------------------------------------------------------------------------
# Configuration surface. Every knob is env-overridable because the tests must
# be able to point the whole script at a fixture: a test that had to touch the
# real gateway on port 4000 would either be skipped or would fight the running
# process, and both of those are how a "passing" suite stops meaning anything.
# ---------------------------------------------------------------------------
# Runtime state deliberately lives beside ~/.gateway.pid and ~/.gateway.log,
# the paths ~/.local/bin/gw already uses, so the two control surfaces see the
# SAME gateway and neither double-starts against the other (KTD4). It stays out
# of the install directory, which R4 lets move between releases.
GATEWAY_STATE_HOME="${GATEWAY_STATE_HOME:-$HOME}"
PIDFILE="${GATEWAY_PIDFILE:-$GATEWAY_STATE_HOME/.gateway.pid}"
LOGFILE="${GATEWAY_LOG:-$GATEWAY_STATE_HOME/.gateway.log}"
LOCKDIR="${GATEWAY_LOCK:-$GATEWAY_STATE_HOME/.gateway.lock}"

# Where `~/gateway-*` is searched. Overridable so a test can own a fake $HOME
# without exporting HOME (which would relocate ~/.claude and friends too).
SEARCH_ROOT="${GATEWAY_SEARCH_ROOT:-$HOME}"

BASE_URL="${GATEWAY_BASE_URL:-http://127.0.0.1:4000/anthropic}"
BASE_URL="${BASE_URL%/}"

MODELS_JSON="${GATEWAY_MODELS_JSON:-$SCRIPT_DIR/models.json}"

# Short connection timeout so a dead endpoint fails fast; the total probe
# budget is sized from the healthy path (a model list is a small local read),
# not from a pathological one.
CONNECT_TIMEOUT="${GATEWAY_CONNECT_TIMEOUT:-2}"
PROBE_TIMEOUT="${GATEWAY_PROBE_TIMEOUT:-5}"
START_TIMEOUT="${GATEWAY_START_TIMEOUT:-20}"
LOCK_TIMEOUT="${GATEWAY_LOCK_TIMEOUT:-60}"

# Binary candidates inside a resolved install dir, most specific first.
BIN_CANDIDATES=("target/release/gateway" "target/debug/gateway" "bin/gateway" "gateway")

# ---------------------------------------------------------------------------
# Plumbing
# ---------------------------------------------------------------------------
# EVERY human-readable diagnostic in this script goes through say() or die(),
# and both sanitize (KTD5). Sanitizing at the CHOKEPOINT rather than at each
# call site is deliberate: the escape-audit precedent's whole lesson is that
# per-site discipline leaks a new sibling sink every review round, while a
# chokepoint is closed for messages nobody has written yet. Interpolating an
# attacker-controlled value into a raw `printf ... >&2` bypasses this and is
# what the lint in tests/unit/escapes.bats exists to catch.
say() { printf '▸ %s\n' "$(gateway::sanitize_for_display "$*")" >&2; }
die() {
    # $1 = exit code, rest = message. Stderr only — stdout belongs to the one
    # JSON object, and a diagnostic printed there is how a consumer's `jq`
    # blows up on output it was promised it could parse whole.
    # The sanitize call is INLINE at the printf rather than hidden behind a
    # local: the lint in tests/unit/escapes.bats reads these lines, and a
    # defence it cannot see is a defence the next reviewer cannot verify either.
    # emit_error sanitizes the same message for the JSON `error` field.
    local code="$1"; shift
    printf '✗ %s\n' "$(gateway::sanitize_for_display "$*")" >&2
    emit_error "$code" "$*"
    exit "$code"
}

TMPWORK=""
LOCK_HELD=0
cleanup() {
    [ "$LOCK_HELD" -eq 1 ] && rm -rf "$LOCKDIR" 2>/dev/null
    [ -n "$TMPWORK" ] && rm -rf "$TMPWORK" 2>/dev/null
    return 0
}
trap cleanup EXIT

# Sets TMPWORK; it does NOT print the path. A `work="$(tmpwork)"` form would run
# this in a command substitution, so the assignment would land in the subshell
# and the parent's TMPWORK would stay empty — leaving the EXIT trap with nothing
# to remove and leaking a temp dir on every single invocation. Callers read
# "$TMPWORK" after calling.
#
# umask 077 because the probe's curl --config file lands in here carrying the
# gateway token (KTD6).
tmpwork() {
    if [ -z "$TMPWORK" ]; then
        TMPWORK="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/gatewayctl.XXXXXX")" || {
            printf '✗ cannot create a temp dir\n' >&2; exit 2; }
    fi
}

need_jq() {
    command -v jq >/dev/null 2>&1 || {
        printf '✗ jq is required (the contract is one JSON object on stdout)\n' >&2
        exit 2
    }
}

# The single stdout write. Every verb funnels through here so "exactly one JSON
# object, always" is a property of the code shape rather than of discipline.
EMITTED=0
emit() {
    [ "$EMITTED" -eq 1 ] && return 0
    EMITTED=1
    printf '%s\n' "$1"
}
emit_error() {
    local code="$1" msg="$2"
    [ "$EMITTED" -eq 1 ] && return 0
    # Sanitized here as well as in die(): idempotent on an already-clean string,
    # and it means a future caller that reaches emit_error directly cannot open
    # a hole in the `error` field, which is display text a consumer prints.
    msg="$(gateway::sanitize_for_display "$msg")"
    if command -v jq >/dev/null 2>&1; then
        emit "$(jq -nc --arg verb "${VERB:-}" --arg m "$msg" --argjson c "$code" \
            '{ok:false, verb:$verb, error:$m, exit_code:$c}')"
    else
        EMITTED=1
        # No jq means no encoder, and VERB is raw argv: an unsanitized verb here
        # would put a quote (breaking the object) or an escape byte into stdout.
        # Reduced to the verb enum's own charset in pure bash — closed by
        # construction, since that is the only defence available with no jq.
        printf '{"ok":false,"verb":"%s","error":"internal","exit_code":%s}\n' "${VERB//[^a-z]/}" "$code"
    fi
}

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

# ---------------------------------------------------------------------------
# gateway.yaml reader.
#
# Only two things are read: server.token (for the authenticated probe) and the
# models block (for KTD7's third drift class — the models endpoint returns only
# id and display_name, so a repointed alias keeps its name and would otherwise
# drift silently). The file is never written.
# ---------------------------------------------------------------------------
yaml_scan() {
    local cfg="$1"
    [ -f "$cfg" ] || return 1
    awk '
        function trim(v) { sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v); return v }
        function decomment(v) { sub(/[ \t]+#.*$/, "", v); return trim(v) }
        function unquote(v) { gsub(/^["'"'"']|["'"'"']$/, "", v); return v }
        /^[A-Za-z_][A-Za-z0-9_-]*:/ { sec = $0; sub(/:.*$/, "", sec); alias = ""; next }
        sec == "server" && /^[ \t]+token:/ {
            v = $0; sub(/^[ \t]*token:[ \t]*/, "", v)
            print "TOKEN\t" unquote(decomment(v)); next
        }
        sec == "models" && /^  [A-Za-z0-9._-]+:[ \t]*(#.*)?$/ {
            alias = decomment($0); sub(/:$/, "", alias); next
        }
        sec == "models" && alias != "" && /^    model:/ {
            v = $0; sub(/^[ \t]*model:[ \t]*/, "", v); v = decomment(v)
            if (v ~ /^\[/) {
                gsub(/^\[|\]$/, "", v)
                n = split(v, parts, ",")
                out = ""
                for (i = 1; i <= n; i++) {
                    p = unquote(trim(parts[i]))
                    if (p != "") out = (out == "" ? p : out "\t" p)
                }
                print "MODEL\t" alias "\tchain\t" out
            } else {
                print "MODEL\t" alias "\tsingle\t" unquote(v)
            }
            next
        }
    ' "$cfg"
}

CONFIG_PATH=""
GATEWAY_TOKEN_VALUE=""
CONFIG_MODELS_JSON="{}"
CONFIG_LOADED=0

resolve_config() {
    [ "$CONFIG_LOADED" -eq 1 ] && return 0
    if [ -n "${GATEWAY_CONFIG:-}" ]; then
        CONFIG_PATH="$GATEWAY_CONFIG"
        [ -f "$CONFIG_PATH" ] || die "$EX_USAGE" "GATEWAY_CONFIG is set to '$CONFIG_PATH', which is not a readable file"
    else
        resolve_install_dir soft
        [ -n "$INSTALL_DIR" ] && CONFIG_PATH="$INSTALL_DIR/gateway.yaml"
    fi

    if [ -n "$CONFIG_PATH" ] && [ -f "$CONFIG_PATH" ]; then
        local line kind rest
        local -a models_lines=()
        while IFS= read -r line; do
            kind="${line%%$'\t'*}"
            rest="${line#*$'\t'}"
            case "$kind" in
                TOKEN) GATEWAY_TOKEN_VALUE="$(expand_env_refs "$rest")" ;;
                MODEL) models_lines+=("$rest") ;;
            esac
        done < <(yaml_scan "$CONFIG_PATH")

        if [ "${#models_lines[@]}" -gt 0 ]; then
            # Built with jq, and sanitized (KTD5) on the way in.
            #
            # This used to be an awk program interpolating the config's values
            # straight between quote characters. That is not a style question:
            # gateway.yaml is user-editable, so a model string carrying an ESC
            # byte (or a plain double quote) produced INVALID JSON here, which
            # made every --argjson consuming it fail, which made `status` print
            # NOTHING on stdout while still exiting 0 — a KTD2 violation
            # triggered by a character in a config file.
            #
            # jq owns the encoding, and strip_display_controls runs BEFORE the
            # split so the alias and model strings are display-clean at the
            # boundary where they enter the script. It keeps tab and newline,
            # which are the record and field separators, so the split is intact.
            CONFIG_MODELS_JSON="$(
                printf '%s\n' "${models_lines[@]}" | jq -Rsc "$GATEWAY_SANITIZE_JQ_DEF"'
                    strip_display_controls
                    | split("\n")
                    | map(select(length > 0) | split("\t"))
                    | map(select(length >= 3))
                    | map({key: .[0],
                           value: {chain: (.[1] == "chain"),
                                   model: (if .[1] == "chain" then .[2:] else .[2] end)}})
                    | from_entries'
            )"
            # Fail SAFE, not open: an unparseable config models block becomes an
            # empty table (drift class 3 reports nothing) rather than an empty
            # string that would blow up the --argjson consuming it.
            case "$CONFIG_MODELS_JSON" in
                "" | null) CONFIG_MODELS_JSON="{}" ;;
            esac
        fi
    fi
    CONFIG_LOADED=1
    return 0
}

# ---------------------------------------------------------------------------
# Install-dir and binary resolution (KTD4).
#
# explicit env override → else the newest ~/gateway-* versioned dir → else a
# distinct failure. Three hardening points, each named for the failure it stops:
#   * every candidate must be a REGULAR FILE and executable. `-x` alone is true
#     of a directory, so a stray `gateway/` dir would resolve as the binary and
#     the start would fail with a bare "permission denied" nobody can act on.
#   * a set-but-invalid override is a HARD failure, never a silent fall-through
#     to some other version — silently running the wrong build is worse than
#     not running.
#   * "newest" is a component-wise NUMERIC version compare, not `sort` and not
#     mtime: lexically 0.1.10 sorts below 0.1.9, and mtime makes a `touch` or a
#     restore-from-backup silently repoint the install.
# ---------------------------------------------------------------------------
INSTALL_DIR=""
GATEWAY_BIN=""
INSTALL_ERR=""
INSTALL_RESOLVED=0

version_sort_key() {
    # 0.1.10 -> 0000000000.0000000001.0000000010. — zero-padded so a plain
    # lexical sort over these keys IS a numeric component-wise compare.
    local v="$1" p
    local -a parts
    IFS='.-' read -ra parts <<< "$v"
    for p in "${parts[@]}"; do
        if [[ "$p" =~ ^[0-9]+$ ]]; then
            printf '%010d.' "$((10#$p))"
        else
            printf '%010d.' 0
        fi
    done
}

find_binary_in() {
    local dir="$1" cand
    for cand in "${BIN_CANDIDATES[@]}"; do
        if [ -f "$dir/$cand" ] && [ -x "$dir/$cand" ]; then
            printf '%s' "$dir/$cand"
            return 0
        fi
    done
    return 1
}

# resolve_install_dir [soft]
#   soft: a "no candidate found" outcome records INSTALL_ERR and returns 1
#         instead of exiting, so `status` can still report liveness.
#   A set-but-invalid override is a hard exit in BOTH modes — it is user error,
#   and reporting it as a soft note is the silent fall-through KTD4 forbids.
resolve_install_dir() {
    local mode="${1:-hard}"
    if [ "$INSTALL_RESOLVED" -eq 1 ]; then
        [ -n "$INSTALL_DIR" ] && return 0
        [ "$mode" = "soft" ] && return 1
        die "$EX_UNREACHABLE" "$INSTALL_ERR"
    fi
    INSTALL_RESOLVED=1

    if [ -n "${GATEWAY_INSTALL_DIR:-}" ]; then
        local ovr="$GATEWAY_INSTALL_DIR"
        [ -d "$ovr" ] || die "$EX_USAGE" "GATEWAY_INSTALL_DIR is set to '$ovr', which is not a directory (set-but-invalid override is a hard failure, never a fall-through)"
        local bin
        bin="$(find_binary_in "$ovr")" || die "$EX_USAGE" "GATEWAY_INSTALL_DIR '$ovr' holds no executable regular-file gateway binary (looked for: ${BIN_CANDIDATES[*]})"
        INSTALL_DIR="$ovr"
        GATEWAY_BIN="$bin"
        return 0
    fi

    local best="" best_key="" d name key
    for d in "$SEARCH_ROOT"/gateway-*; do
        [ -d "$d" ] || continue
        name="$(basename "$d")"
        key="$(version_sort_key "${name#gateway-}")"
        if [ -z "$best" ] || [[ "$key" > "$best_key" ]]; then
            best="$d"; best_key="$key"
        fi
    done

    if [ -z "$best" ]; then
        INSTALL_ERR="no gateway install found: no versioned directory matches '$SEARCH_ROOT/gateway-*' and GATEWAY_INSTALL_DIR is unset"
        [ "$mode" = "soft" ] && return 1
        die "$EX_UNREACHABLE" "$INSTALL_ERR"
    fi

    local bin
    if ! bin="$(find_binary_in "$best")"; then
        INSTALL_ERR="newest gateway install '$best' holds no executable regular-file gateway binary (looked for: ${BIN_CANDIDATES[*]})"
        [ "$mode" = "soft" ] && return 1
        die "$EX_UNREACHABLE" "$INSTALL_ERR"
    fi
    INSTALL_DIR="$best"
    GATEWAY_BIN="$bin"
    return 0
}

# ---------------------------------------------------------------------------
# Liveness probe (KTD3).
#
# ONE authenticated GET /anthropic/v1/models. The token is non-negotiable: the
# real gateway guards that route behind check_auth and answers an
# unauthenticated probe with 401. Reading that 401 as "down" is a P0 — `ensure`
# would start a SECOND gateway against a live one and every later command dies
# on AddrInUse. So a rejected token is its own class (exit 7), never 3, and
# never triggers a start.
#
# The pidfile is never consulted here. That is what makes AE1 (stale pidfile,
# gateway serving -> up) and AE2 (dead gateway, recycled pid -> down) both come
# out right.
# ---------------------------------------------------------------------------
PROBE_STATUS=0
PROBE_ALIASES_JSON="[]"
PROBE_HTTP=""
PROBE_DETAIL=""

probe() {
    resolve_config
    PROBE_ALIASES_JSON="[]"
    PROBE_DETAIL=""
    local work body code curlrc
    tmpwork
    work="$TMPWORK"
    body="$work/probe.body"
    : > "$body"

    # Credential delivery (KTD6): a mode-0600 curl --config file, never an argv
    # token. `-H "x-api-key: $TOK"` is the tempting one-liner and it is exactly
    # the leak — argv is readable from the process table by anything on the box,
    # and lens.sh spawns this probe as a child on every call, so an argv token
    # here would expose it on the lens path too.
    curlrc="$work/probe.curlrc"
    local esc_url esc_tok
    esc_url="$(printf '%s' "$BASE_URL/v1/models" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
    esc_tok="$(printf '%s' "$GATEWAY_TOKEN_VALUE" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
    {
        printf 'url = "%s"\n' "$esc_url"
        printf 'header = "x-api-key: %s"\n' "$esc_tok"
        printf 'header = "authorization: Bearer %s"\n' "$esc_tok"
    } > "$curlrc"
    chmod 600 "$curlrc" 2>/dev/null

    code="$(curl -s -o "$body" -w '%{http_code}' \
        --connect-timeout "$CONNECT_TIMEOUT" --max-time "$PROBE_TIMEOUT" \
        --config "$curlrc" 2>/dev/null)"
    local rc=$?
    PROBE_HTTP="$code"

    if [ $rc -ne 0 ] || [ -z "$code" ] || [ "$code" = "000" ]; then
        PROBE_DETAIL="no HTTP response from $BASE_URL/v1/models (curl rc=$rc)"
        PROBE_STATUS=$EX_UNREACHABLE
        return $EX_UNREACHABLE
    fi
    if [ "$code" = "401" ] || [ "$code" = "403" ]; then
        PROBE_DETAIL="gateway is up at $BASE_URL but rejected our token (HTTP $code); token came from ${CONFIG_PATH:-<no config resolved>}"
        PROBE_STATUS=$EX_AUTH
        return $EX_AUTH
    fi
    if [ "$code" != "200" ]; then
        PROBE_DETAIL="model-list probe returned HTTP $code from $BASE_URL/v1/models"
        PROBE_STATUS=$EX_UNREACHABLE
        return $EX_UNREACHABLE
    fi

    local aliases
    # KTD5: the served list is free-form text off the wire, and it is display
    # text in every consumer (status prints it, ensure returns it for a human to
    # read). Sanitized here, at the one place it enters the script, so no
    # downstream emit has to remember. The membership check below is unaffected:
    # a caller's alias has already passed the [A-Za-z0-9._-]+ grammar, and
    # sanitizing only removes bytes that grammar cannot contain — so a served
    # alias that could ever match is byte-identical before and after.
    aliases="$(jq -c "$GATEWAY_SANITIZE_JQ_DEF"' [.data[]?.id // empty] | strip_display_deep' < "$body" 2>/dev/null)"
    if [ -z "$aliases" ]; then
        PROBE_DETAIL="model-list probe returned HTTP 200 but the body is not the expected JSON model list"
        PROBE_STATUS=$EX_UNREACHABLE
        return $EX_UNREACHABLE
    fi
    PROBE_ALIASES_JSON="$aliases"
    PROBE_DETAIL=""
    PROBE_STATUS=$EX_OK
    return $EX_OK
}

# ---------------------------------------------------------------------------
# Lock (KTD4 idempotent start).
#
# mkdir is the atomic primitive here because flock(1) does not exist on macOS.
# A holder pid inside the dir lets a lock left behind by a killed process be
# broken, so one crashed `ensure` cannot wedge every later one for good.
# ---------------------------------------------------------------------------
acquire_lock() {
    local waited=0
    while ! mkdir "$LOCKDIR" 2>/dev/null; do
        local holder
        holder="$(cat "$LOCKDIR/pid" 2>/dev/null)"
        if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
            say "breaking a stale gateway lock left by dead pid $holder"
            rm -rf "$LOCKDIR" 2>/dev/null
            continue
        fi
        sleep 0.1
        waited=$((waited + 1))
        if [ "$waited" -gt $((LOCK_TIMEOUT * 10)) ]; then
            return 1
        fi
    done
    printf '%s\n' "$$" > "$LOCKDIR/pid" 2>/dev/null
    LOCK_HELD=1
    return 0
}

release_lock() {
    if [ "$LOCK_HELD" -eq 1 ]; then
        rm -rf "$LOCKDIR" 2>/dev/null
        LOCK_HELD=0
    fi
}

# ---------------------------------------------------------------------------
# pid verification (KTD4 stop safety).
#
# Matches the process's ARGV against the resolved binary. Never `ps -o comm`:
# comm truncates and has produced false negatives on this box, and a false
# negative here means refusing to stop a gateway we own, while a naive `kill`
# on an unverified pid means killing whatever recycled that pid.
# ---------------------------------------------------------------------------
pid_argv() {
    ps -o args= -p "$1" 2>/dev/null | head -1
}

pid_is_gateway() {
    local pid="$1" args
    kill -0 "$pid" 2>/dev/null || return 1
    args="$(pid_argv "$pid")"
    [ -n "$args" ] || return 1
    case "$args" in
        *"$GATEWAY_BIN"*) return 0 ;;
        *) return 1 ;;
    esac
}

read_pidfile() {
    local p
    [ -f "$PIDFILE" ] || return 1
    p="$(tr -dc '0-9' < "$PIDFILE" 2>/dev/null)"
    [ -n "$p" ] || return 1
    printf '%s' "$p"
}

# ---------------------------------------------------------------------------
# Alias grammar (KTD5). Validated BEFORE any network call so an escape byte or
# a shell metacharacter in an identifier is impossible rather than filtered.
# ---------------------------------------------------------------------------
validate_alias() {
    local a="$1"
    [[ "$a" =~ ^[A-Za-z0-9._-]+$ ]] || die "$EX_USAGE" "alias failed the grammar [A-Za-z0-9._-]+ — refused before any network call"
}

# ---------------------------------------------------------------------------
# start (locked, idempotent)
#
# Returns the contract code. Sets STARTED=1 only when THIS call spawned the
# process. Re-probing UNDER the lock is what makes N concurrent `ensure` calls
# against a down gateway yield exactly one gateway process: the losers of the
# mkdir race find it already up when their turn comes.
# ---------------------------------------------------------------------------
STARTED=0
do_start_locked() {
    probe
    local rc=$?
    if [ $rc -eq $EX_OK ] || [ $rc -eq $EX_AUTH ]; then
        return $rc
    fi

    resolve_install_dir hard

    # R3: append, never truncate. `gw` truncates on every start and that
    # destroyed the only evidence of why a previous start died.
    mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null
    printf -- '--- gatewayctl start %s ---\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$LOGFILE"

    (
        cd "$INSTALL_DIR" || exit 1
        nohup "$GATEWAY_BIN" --config "$CONFIG_PATH" >> "$LOGFILE" 2>&1 &
        printf '%s\n' "$!" > "$PIDFILE"
    )
    STARTED=1

    local waited=0
    while :; do
        probe
        rc=$?
        [ $rc -eq $EX_OK ] && return $EX_OK
        [ $rc -eq $EX_AUTH ] && return $EX_AUTH
        sleep 0.2
        waited=$((waited + 1))
        if [ "$waited" -gt $((START_TIMEOUT * 5)) ]; then
            say "started $GATEWAY_BIN but it never answered the model-list probe within ${START_TIMEOUT}s"
            say "last 10 log lines from $LOGFILE:"
            # KTD5 free-form sink: the gateway's own log carries upstream error
            # bodies and provider prose, so these bytes are as untrusted as a
            # model response. Piped through the sanitizer, never straight to the
            # terminal.
            tail -10 "$LOGFILE" 2>/dev/null | gateway::sanitize_stream >&2
            return $EX_UNREACHABLE
        fi
    done
}

start_if_down() {
    probe
    local rc=$?
    [ $rc -eq $EX_OK ] && return $EX_OK
    [ $rc -eq $EX_AUTH ] && return $EX_AUTH

    if ! acquire_lock; then
        die "$EX_UNREACHABLE" "could not acquire the start lock at $LOCKDIR within ${LOCK_TIMEOUT}s"
    fi
    do_start_locked
    rc=$?
    release_lock
    return $rc
}

# ---------------------------------------------------------------------------
# Drift (KTD7). Three classes:
#   1. a served alias missing from the table
#   2. a table entry with no declared window
#   3. an alias whose upstream model string no longer matches the recorded one
# Class 3 reads gateway.yaml rather than the probe response because the models
# endpoint returns only id and display_name — a repointed alias keeps its name
# and would otherwise drift silently.
# ---------------------------------------------------------------------------
table_json() {
    if [ -f "$MODELS_JSON" ]; then
        jq -c '.' < "$MODELS_JSON" 2>/dev/null || printf '{"aliases":{}}'
    else
        printf '{"aliases":{}}'
    fi
}

# ---------------------------------------------------------------------------
# Verbs
# ---------------------------------------------------------------------------
VERB="${1:-}"
[ $# -gt 0 ] && shift

case "$VERB" in
    start|stop|restart|status|ensure) ;;
    ""|-h|--help|help)
        printf 'usage: gatewayctl.sh {start|stop|restart|status|ensure [alias]}\n' >&2
        need_jq
        die "$EX_USAGE" "no verb given"
        ;;
    *)
        need_jq
        die "$EX_USAGE" "unknown verb '$VERB' (expected start|stop|restart|status|ensure)"
        ;;
esac

need_jq

case "$VERB" in

ensure)
    ALIAS="${1:-}"
    # Grammar first: refused before any network call (KTD5).
    [ -n "$ALIAS" ] && validate_alias "$ALIAS"

    start_if_down
    rc=$?
    if [ $rc -eq $EX_AUTH ]; then
        # No start is attempted: the gateway is UP, it just rejected us.
        die $EX_AUTH "$PROBE_DETAIL"
    fi
    if [ $rc -ne $EX_OK ]; then
        die $EX_UNREACHABLE "${PROBE_DETAIL:-gateway unreachable and could not be started}"
    fi

    # The served-list check lives HERE, not in lens.sh and launch.sh, so the
    # two surfaces cannot diverge on what exit 4 means.
    if [ -n "$ALIAS" ]; then
        if ! printf '%s' "$PROBE_ALIASES_JSON" | jq -e --arg a "$ALIAS" 'index($a) != null' >/dev/null 2>&1; then
            say "alias '$ALIAS' is not in the gateway's served list"
            emit "$(jq -nc --arg a "$ALIAS" --argjson served "$PROBE_ALIASES_JSON" --argjson c $EX_ALIAS \
                '{ok:false, verb:"ensure", error:"alias_unknown", alias:$a, served_aliases:$served, exit_code:$c}')"
            exit $EX_ALIAS
        fi
    fi

    emit "$(jq -nc \
        --arg base "$BASE_URL" \
        --arg alias "$ALIAS" \
        --argjson served "$PROBE_ALIASES_JSON" \
        --argjson started "$([ $STARTED -eq 1 ] && echo true || echo false)" \
        '{ok:true, verb:"ensure", running:true, started:$started, base_url:$base,
          alias:(if $alias == "" then null else $alias end),
          served_aliases:$served, error:null, exit_code:0}')"
    exit $EX_OK
    ;;

start)
    start_if_down
    rc=$?
    if [ $rc -eq $EX_AUTH ]; then
        die $EX_AUTH "$PROBE_DETAIL"
    fi
    if [ $rc -ne $EX_OK ]; then
        # "announced-but-broken is never success" — a start that did not
        # produce a serving gateway exits honestly non-zero.
        die $EX_UNREACHABLE "${PROBE_DETAIL:-gateway could not be started}"
    fi
    pid="$(read_pidfile)"
    emit "$(jq -nc \
        --arg base "$BASE_URL" \
        --arg log "$LOGFILE" \
        --argjson served "$PROBE_ALIASES_JSON" \
        --argjson started "$([ $STARTED -eq 1 ] && echo true || echo false)" \
        --arg pid "${pid:-}" \
        '{ok:true, verb:"start", running:true, started:$started, base_url:$base,
          pid:(if $pid == "" then null else ($pid|tonumber) end),
          log:$log, served_aliases:$served, error:null, exit_code:0}')"
    exit $EX_OK
    ;;

stop)
    resolve_install_dir hard
    pid="$(read_pidfile)"
    if [ -z "$pid" ]; then
        probe
        if [ $? -eq $EX_OK ]; then
            say "a gateway is serving at $BASE_URL but $PIDFILE names no pid — refusing to guess which process to signal"
            emit "$(jq -nc --arg p "$PIDFILE" --argjson c $EX_USAGE \
                '{ok:false, verb:"stop", result:"unmanaged", error:"a gateway is serving but the pidfile is empty or absent", pidfile:$p, exit_code:$c}')"
            exit $EX_USAGE
        fi
        emit "$(jq -nc --arg p "$PIDFILE" \
            '{ok:true, verb:"stop", result:"not_running", pid:null, pidfile:$p, error:null, exit_code:0}')"
        exit $EX_OK
    fi

    if ! kill -0 "$pid" 2>/dev/null; then
        rm -f "$PIDFILE"
        emit "$(jq -nc --argjson pid "$pid" \
            '{ok:true, verb:"stop", result:"stale_pidfile", pid:$pid, error:null, exit_code:0}')"
        exit $EX_OK
    fi

    # Recycled pid: a live process holds it, but its argv is not our binary.
    # Report, do not kill.
    if ! pid_is_gateway "$pid"; then
        say "pid $pid is live but its argv does not name $GATEWAY_BIN — recycled pid, refusing to signal it"
        # actual_argv is another process's command line — free-form, unrelated to
        # us, and printed by anyone diagnosing the mismatch. Sanitized (KTD5).
        emit "$(jq -nc --argjson pid "$pid" --arg bin "$GATEWAY_BIN" --arg argv "$(gateway::sanitize_for_display "$(pid_argv "$pid")")" --argjson c $EX_USAGE \
            '{ok:false, verb:"stop", result:"pid_mismatch", pid:$pid, expected_binary:$bin, actual_argv:$argv,
              error:"pidfile pid belongs to an unrelated process; not signalled", exit_code:$c}')"
        exit $EX_USAGE
    fi

    kill -TERM "$pid" 2>/dev/null
    waited=0
    while kill -0 "$pid" 2>/dev/null; do
        sleep 0.1
        waited=$((waited + 1))
        if [ "$waited" -gt 100 ]; then
            say "pid $pid ignored SIGTERM for 10s — escalating to SIGKILL"
            kill -KILL "$pid" 2>/dev/null
            break
        fi
    done
    rm -f "$PIDFILE"
    emit "$(jq -nc --argjson pid "$pid" \
        '{ok:true, verb:"stop", result:"stopped", pid:$pid, error:null, exit_code:0}')"
    exit $EX_OK
    ;;

restart)
    bash "${BASH_SOURCE[0]}" stop >/dev/null 2>&1
    stop_rc=$?
    start_if_down
    rc=$?
    if [ $rc -eq $EX_AUTH ]; then
        die $EX_AUTH "$PROBE_DETAIL"
    fi
    if [ $rc -ne $EX_OK ]; then
        die $EX_UNREACHABLE "${PROBE_DETAIL:-gateway could not be restarted}"
    fi
    pid="$(read_pidfile)"
    emit "$(jq -nc \
        --arg base "$BASE_URL" \
        --argjson served "$PROBE_ALIASES_JSON" \
        --argjson stop_rc "$stop_rc" \
        --arg pid "${pid:-}" \
        '{ok:true, verb:"restart", running:true, base_url:$base,
          pid:(if $pid == "" then null else ($pid|tonumber) end),
          stop_exit_code:$stop_rc, served_aliases:$served, error:null, exit_code:0}')"
    exit $EX_OK
    ;;

status)
    resolve_config
    # Soft: an unresolvable install dir must not stop status from reporting
    # liveness, which is the question status exists to answer. (A set-but-
    # invalid GATEWAY_INSTALL_DIR still hard-fails inside resolve_install_dir.)
    resolve_install_dir soft
    install_note="$INSTALL_ERR"

    probe
    prc=$?

    pid="$(read_pidfile)"
    pid_ok=false
    if [ -n "$pid" ] && [ -n "$GATEWAY_BIN" ] && pid_is_gateway "$pid"; then
        pid_ok=true
    fi

    tbl="$(table_json)"
    # KTD5, and the promise skills/status/SKILL.md already makes: everything the
    # config and the alias table supply as DISPLAY text is sanitized before it is
    # printed. Both blocks below are display-only — a consumer reads them to show
    # a human what drifted; nothing parses them back into a path or a URL — so a
    # deep strip cannot break a functional value the way sanitizing `config` or
    # `base_url` would.
    drift="$(jq -nc \
        --argjson served "$PROBE_ALIASES_JSON" \
        --argjson table "$tbl" \
        --argjson cfg "$CONFIG_MODELS_JSON" \
        "$GATEWAY_SANITIZE_JQ_DEF"'
        ($table.aliases // {}) as $t | {
          missing_from_table: [ $served[] as $a | select(($t | has($a)) | not) | $a ],
          missing_window: [ $t | to_entries[]
                            | select((.value.context_window // null) == null)
                            | .key ],
          model_drift: [ $t | to_entries[] as $e
                         | ($cfg[$e.key] // null)
                         | select(. != null)
                         | select(.model != $e.value.model)
                         | {alias: $e.key, recorded: $e.value.model, current: .model} ]
        } | strip_display_deep')"

    models_view="$(jq -nc --argjson table "$tbl" "$GATEWAY_SANITIZE_JQ_DEF"'
        [ ($table.aliases // {}) | to_entries[]
          | {alias: .key,
             context_window: (.value.context_window // null),
             source: (.value.source // null),
             model: (.value.model // null),
             chain: (.value.chain // false)} ]
        | strip_display_deep')"

    running=false
    [ $prc -eq $EX_OK ] && running=true

    emit "$(jq -nc \
        --argjson running "$running" \
        --argjson served "$PROBE_ALIASES_JSON" \
        --arg base "$BASE_URL" \
        --arg install "${INSTALL_DIR:-}" \
        --arg bin "${GATEWAY_BIN:-}" \
        --arg cfg "${CONFIG_PATH:-}" \
        --arg log "$LOGFILE" \
        --arg pidfile "$PIDFILE" \
        --arg pid "${pid:-}" \
        --argjson pid_verified "$pid_ok" \
        --arg install_error "$(gateway::sanitize_for_display "${install_note:-}")" \
        --argjson drift "$drift" \
        --argjson models "$models_view" \
        --arg detail "$(gateway::sanitize_for_display "${PROBE_DETAIL:-}")" \
        --argjson c "$prc" \
        '{ok: ($c == 0), verb:"status", running:$running, base_url:$base,
          install_dir:(if $install == "" then null else $install end),
          binary:(if $bin == "" then null else $bin end),
          config:(if $cfg == "" then null else $cfg end),
          install_dir_error:(if $install_error == "" then null else $install_error end),
          log:$log, pidfile:$pidfile,
          pid:(if $pid == "" then null else ($pid|tonumber) end),
          pid_verified:$pid_verified,
          served_aliases:$served, models:$models, drift:$drift,
          error:(if $detail == "" then null else $detail end),
          exit_code:$c}')"
    exit $prc
    ;;
esac
