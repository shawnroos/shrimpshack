#!/usr/bin/env bash
# spawnctl.sh — the gateway plugin's own control layer (plan U2).
#
#   spawnctl.sh start            start the gateway if it is not already up
#   spawnctl.sh stop             stop the gateway we started
#   spawnctl.sh restart          stop (tolerating "not running") then start
#   spawnctl.sh status           liveness, served aliases, install dir, drift
#   spawnctl.sh ensure [alias]   the preflight lens.sh and launch.sh call
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

# Same reason, applied to the plain helpers: expand_env_refs, emit and the curl
# --config escaper were byte-identical copies across the three scripts.
# shellcheck source=./common.sh
. "$SCRIPT_DIR/common.sh"

# The Keychain primitives (U1). Sourced for the START path only: nothing else in
# this script reads a credential store, and the read happens inside
# do_start_locked rather than at load time, so `status`, `ensure` against a live
# gateway and every probe path touch the Keychain zero times.
# shellcheck source=./secrets.sh
. "$SCRIPT_DIR/secrets.sh"

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
SPAWN_STATE_HOME="${SPAWN_STATE_HOME:-$HOME}"
PIDFILE="${SPAWN_PIDFILE:-$SPAWN_STATE_HOME/.gateway.pid}"
LOGFILE="${SPAWN_LOG:-$SPAWN_STATE_HOME/.gateway.log}"
LOCKDIR="${SPAWN_LOCK:-$SPAWN_STATE_HOME/.gateway.lock}"

# Where `~/gateway-*` is searched. Overridable so a test can own a fake $HOME
# without exporting HOME (which would relocate ~/.claude and friends too).
SEARCH_ROOT="${SPAWN_SEARCH_ROOT:-$HOME}"

BASE_URL="${SPAWN_BASE_URL:-http://127.0.0.1:4000/anthropic}"
BASE_URL="${BASE_URL%/}"

MODELS_JSON="${SPAWN_MODELS_JSON:-$SCRIPT_DIR/models.json}"

# Short connection timeout so a dead endpoint fails fast; the total probe
# budget is sized from the healthy path (a model list is a small local read),
# not from a pathological one.
CONNECT_TIMEOUT="${SPAWN_CONNECT_TIMEOUT:-2}"
PROBE_TIMEOUT="${SPAWN_PROBE_TIMEOUT:-5}"
START_TIMEOUT="${SPAWN_START_TIMEOUT:-20}"
LOCK_TIMEOUT="${SPAWN_LOCK_TIMEOUT:-60}"

# Binary candidates inside a resolved install dir, most specific first.

# ---------------------------------------------------------------------------
# Keychain item identity (KTD1, U1's primitives).
#
# THIS IS A CROSS-FILE CONTRACT: setup.sh writes these exact items and this
# script reads them. They are one service with two accounts rather than two
# services, so a single `security` service name identifies everything this
# plugin stores. Env-overridable for the same reason every other knob is — a
# test points them at the fake store instead of this machine's login keychain.
# ---------------------------------------------------------------------------
KEYCHAIN_SERVICE="${SPAWN_KEYCHAIN_SERVICE:-spawn-gateway}"
KEYCHAIN_ACCOUNT_OPENROUTER="${SPAWN_KEYCHAIN_ACCOUNT_OPENROUTER:-openrouter-api-key}"
KEYCHAIN_ACCOUNT_TOKEN="${SPAWN_KEYCHAIN_ACCOUNT_TOKEN:-gateway-token}"

# Read-only here: this script never loads, unloads or starts a launchd job — it
# only ASKS whether one supervises the gateway, so `stop` can stop claiming a
# stop that KeepAlive undoes. Same default and same override name setup-lib.sh
# uses, so a suite that redirects one redirects both.
LAUNCHCTL_BIN="${SPAWN_LAUNCHCTL_BIN:-/bin/launchctl}"

# The transient delivery file (KTD1). `.env.local` is the gateway's own
# CWD-relative dotenv name, and do_start_locked already runs the child with the
# install dir as its CWD, so no start-path restructuring is needed.
DELIVERY_NAME=".env.local"

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
say() { printf '▸ %s\n' "$(spawn::sanitize_for_display "$*")" >&2; }
die() {
    # $1 = exit code, rest = message. Stderr only — stdout belongs to the one
    # JSON object, and a diagnostic printed there is how a consumer's `jq`
    # blows up on output it was promised it could parse whole.
    # The sanitize call is INLINE at the printf rather than hidden behind a
    # local: the lint in tests/unit/escapes.bats reads these lines, and a
    # defence it cannot see is a defence the next reviewer cannot verify either.
    # emit_error sanitizes the same message for the JSON `error` field.
    local code="$1"; shift
    printf '✗ %s\n' "$(spawn::sanitize_for_display "$*")" >&2
    emit_error "$code" "$*"
    exit "$code"
}

TMPWORK=""
LOCK_HELD=0
# The delivery file this process wrote, and only this process. Removal is gated
# on the flag rather than on the path existing: a departing process must never
# delete a delivery file some other start is mid-flight with — the same
# ownership rule the lock release already follows.
DELIVERY_FILE=""
DELIVERY_WRITTEN=0
remove_delivery() {
    [ "$DELIVERY_WRITTEN" -eq 1 ] || return 0
    rm -f "$DELIVERY_FILE" 2>/dev/null
    DELIVERY_WRITTEN=0
    return 0
}
cleanup() {
    # Ownership-checked, same reason release_lock is: an unconditional rm here
    # lets an exiting process delete a lock another process now holds.
    if [ "$LOCK_HELD" -eq 1 ] && [ "$(cat "$LOCKDIR/pid" 2>/dev/null)" = "$$" ]; then
        rm -rf "$LOCKDIR" 2>/dev/null
    fi
    [ -n "$TMPWORK" ] && rm -rf "$TMPWORK" 2>/dev/null
    # The backstop for KTD1's "removed on every exit path". do_start_locked
    # removes it explicitly as soon as the start probe settles; this catches the
    # paths that never get there — a die() mid-start, and the INT/TERM/HUP traps
    # below, which is where the lens path's own temp-file leak was found.
    remove_delivery
    return 0
}
trap cleanup EXIT
# bash does NOT run an EXIT trap when the shell dies on an untrapped INT/TERM/HUP
# (measured on this box, bash 5.3.15). Without these, a cancelled invocation
# leaks $TMPWORK — which on the lens path holds the mode-0600 curl --config file
# carrying the gateway token, so KTD6's "removed within a single invocation" is
# false exactly when an orchestrator cancels a fan-out. It also leaves $LOCKDIR
# behind, which is the stale-lock precondition acquire_lock then has to break.
# These exit THROUGH the EXIT path rather than calling cleanup directly: a bare
# `trap cleanup INT TERM` runs cleanup and then lets the script keep going.
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

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
        TMPWORK="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/spawnctl.XXXXXX")" || {
            # Same contract as need_jq below: "exactly one JSON object on stdout,
            # ALWAYS" includes this path. An unwritable or missing TMPDIR used to
            # exit 2 having printed nothing — indistinguishable from a crash. The
            # fix was applied to need_jq and not to its neighbour here.
            printf '✗ cannot create a temp dir\n' >&2
            emit_error 2 "cannot create a temp dir under ${TMPDIR:-/tmp}"
            exit 2; }
    fi
}

need_jq() {
    command -v jq >/dev/null 2>&1 || {
        printf '✗ jq is required (the contract is one JSON object on stdout)\n' >&2
        # "exactly one JSON object on stdout, ALWAYS" includes the path where
        # the encoder itself is missing. This used to exit 2 printing nothing,
        # which is the contract violation a consumer cannot distinguish from a
        # crash. Same pure-bash fallback emit_error's non-jq branch uses: VERB
        # is raw argv, so it is reduced to the verb enum's own charset —
        # unsanitized, it could put a quote or an escape byte into stdout.
        # The envelope comes from common.sh (R23) rather than being written out
        # here, so this tier cannot drift from the other two.
        emit "$(spawn::envelope_bash plugin "internal" 2 ",\"verb\":\"${VERB//[^a-z]/}\",\"help_requested\":$HELP_REQUESTED" "Install jq and re-run. The plugin's contract is one JSON object on stdout, and jq is what encodes it.")"
        exit 2
    }
}

# The single stdout write lives in common.sh (emit); EMITTED is this script's
# own state, so it stays declared here — a bash function reads the caller's
# globals dynamically.
EMITTED=0

# R11 — the help discriminator. `--help` and an unknown or missing verb are all
# exit 2 with error:"usage" because the enum is contract-frozen (KTD2), and they
# were separated only by the English in `detail`. This field is that distinction
# as data, and it rides every error response on both encoder tiers.
HELP_REQUESTED=false

# R12 — this script's error vocabulary is exactly the shared one (its enums all
# come from the exit code through spawn::enum_for_code), so the table in
# common.sh answers every value. The wrapper exists so a site can be given a
# narrower repair here without moving the shared table, and so the three scripts
# read the same way.
remedy_for() { spawn::remedy_for "$1"; }

emit_error() {
    local code="$1" msg="$2"
    [ "$EMITTED" -eq 1 ] && return 0
    # R23: `error` carries the ENUM and the prose moves to `detail`. This script
    # used to put English in `error` while lens.sh and launch.sh put an enum
    # there — the divergence that made forwarding a preflight object unsafe and
    # broke every fan-out caller's `.error` switch at once. The enum comes from
    # the exit code through the one table in common.sh, which is the same table
    # the two lenses classify a preflight failure with.
    local err
    err="$(spawn::enum_for_code "$code")"
    [ -n "$err" ] || err="internal"
    # Sanitized here as well as in die(): idempotent on an already-clean string,
    # and it means a future caller that reaches emit_error directly cannot open
    # a hole in the `detail` field, which is display text a consumer prints.
    msg="$(spawn::sanitize_for_display "$msg")"
    # R12: the site's own REMEDY wins, otherwise the enum's default from the one
    # table. Defaulted here rather than at every die site, so "every error names
    # its remedy" holds for die sites nobody has written yet.
    local rem="${REMEDY:-}"
    [ -n "$rem" ] || rem="$(remedy_for "$err")"
    local obj=""
    if command -v jq >/dev/null 2>&1; then
        # VERB is raw argv on the unknown-verb path, and jq's --arg escapes
        # control bytes but emits Unicode format characters (e.g. a U+202E bidi
        # override) verbatim. lens.sh and launch.sh sanitize their `alias` field
        # for exactly this reason; the structurally identical field here was left
        # raw, which made the jq path weaker than the pure-bash fallback below.
        local verb_d
        verb_d="$(spawn::sanitize_for_display "${VERB:-}")"
        obj="$(jq -nc --arg verb "$verb_d" --arg e "$err" --arg m "$msg" \
            --arg r "$rem" --argjson c "$code" --argjson h "$HELP_REQUESTED" \
            "$(spawn::envelope_jq plugin)"' + {ok:false, verb:$verb, error:$e,
              detail:$m, remedy:(if $r == "" then null else $r end),
              help_requested:$h, exit_code:$c}')"
    fi
    # No jq means no encoder, and VERB is raw argv: an unsanitized verb here
    # would put a quote (breaking the object) or an escape byte into stdout.
    # Reduced to the verb enum's own charset in pure bash — closed by
    # construction, since that is the only defence available with no jq. Also
    # reached when jq is present but ERRORED, which used to print nothing at all.
    [ -n "$obj" ] || obj="$(spawn::envelope_bash plugin "$err" "$code" ",\"verb\":\"${VERB//[^a-z]/}\",\"help_requested\":$HELP_REQUESTED" "$rem")"
    emit "$obj"
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
SPAWN_TOKEN_VALUE=""
# Where SPAWN_TOKEN_VALUE came from: config | env | keychain | "" (nothing).
# Provenance is tracked rather than inferred from emptiness because the two
# consumers below need different answers. See resolve_token_fallback.
SPAWN_TOKEN_SOURCE=""
CONFIG_MODELS_JSON="{}"
CONFIG_LOADED=0

# ---------------------------------------------------------------------------
# resolve_token_fallback — R27.
#
# Setup retires the token from gateway.yaml (U4/KTD18), so from that point on
# the config is NOT a token source for anyone. The gateway gets its token at
# start time through the delivery file; every OTHER command — status, lens,
# launch — has to present the same credential to a gateway that is ALREADY
# running, and none of them goes anywhere near do_start_locked. Resolving the
# fallback here, in the one place every verb passes through, is what stops a
# successful setup from leaving `status` and `lens` exiting 7 against the
# gateway it just configured.
#
# PRECEDENCE, and why:
#   1. the config, when it declares one — unchanged behaviour for a pre-setup
#      machine, and the gateway still treats a config token as valid;
#   2. an inherited GATEWAY_TOKEN — the shell already holds the credential
#      (KTD15 puts it there by reference), so consulting the Keychain again
#      would be a second unlock-capable call for a value in hand;
#   3. the stored credential.
# ---------------------------------------------------------------------------
resolve_token_fallback() {
    if [ -n "$SPAWN_TOKEN_VALUE" ]; then
        SPAWN_TOKEN_SOURCE="config"
        return 0
    fi
    # env-then-Keychain lives in secrets.sh so lens.sh and launch.sh run the
    # SAME chain. When it lived here, they did not, and a retired config token
    # made this probe authenticate while a real lens call 401'd.
    spawn::token_fallback "$KEYCHAIN_SERVICE" "$KEYCHAIN_ACCOUNT_TOKEN" || true
    return 0
}

resolve_config() {
    [ "$CONFIG_LOADED" -eq 1 ] && return 0
    if [ -n "${SPAWN_CONFIG:-}" ]; then
        CONFIG_PATH="$SPAWN_CONFIG"
        [ -f "$CONFIG_PATH" ] || die "$EX_USAGE" "SPAWN_CONFIG is set to '$CONFIG_PATH', which is not a readable file"
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
                TOKEN) SPAWN_TOKEN_VALUE="$(expand_env_refs "$rest")" ;;
                MODEL) models_lines+=("$rest") ;;
            esac
        done < <(yaml_scan "$CONFIG_PATH")

        # Only `status` ever reads CONFIG_MODELS_JSON (drift class 3). `ensure`
        # resolves the config on EVERY lens and launch call, so building the
        # table there was a jq process spawned per call for a value nothing
        # reads. The read loop above still runs — it is where server.token
        # comes from, and that every verb needs.
        if [ "${VERB:-}" = "status" ] && [ "${#models_lines[@]}" -gt 0 ]; then
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
                printf '%s\n' "${models_lines[@]}" | jq -Rsc "$SPAWN_SANITIZE_JQ_DEF"'
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
    # After the config has had its say, never before: a declared token still
    # wins, and this only fills the hole setup leaves behind (R27).
    resolve_token_fallback
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
SPAWN_BIN=""
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

    if [ -n "${SPAWN_INSTALL_DIR:-}" ]; then
        local ovr="$SPAWN_INSTALL_DIR"
        [ -d "$ovr" ] || die "$EX_USAGE" "SPAWN_INSTALL_DIR is set to '$ovr', which is not a directory (set-but-invalid override is a hard failure, never a fall-through)"
        local bin
        bin="$(find_binary_in "$ovr")" || die "$EX_USAGE" "SPAWN_INSTALL_DIR '$ovr' holds no executable regular-file gateway binary (looked for: ${SPAWN_BIN_CANDIDATES[*]})"
        INSTALL_DIR="$ovr"
        SPAWN_BIN="$bin"
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
        INSTALL_ERR="no gateway install found: no versioned directory matches '$SEARCH_ROOT/gateway-*' and SPAWN_INSTALL_DIR is unset"
        [ "$mode" = "soft" ] && return 1
        die "$EX_UNREACHABLE" "$INSTALL_ERR"
    fi

    local bin
    if ! bin="$(find_binary_in "$best")"; then
        INSTALL_ERR="newest gateway install '$best' holds no executable regular-file gateway binary (looked for: ${SPAWN_BIN_CANDIDATES[*]})"
        [ "$mode" = "soft" ] && return 1
        die "$EX_UNREACHABLE" "$INSTALL_ERR"
    fi
    INSTALL_DIR="$best"
    SPAWN_BIN="$bin"
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
PROBE_ALIASES_JSON="[]"
PROBE_DETAIL=""
# alias -> display_name, straight off the model list. The gateway serves a
# display_name per served id, and two ids carrying the SAME display_name is the
# gateway itself saying they present as one model. That is the only statement
# the gateway makes about aliases it generates rather than reads out of the
# config's `models:` block (the claude-* twins), so drift class 1 needs it.
# Built only for `status`, the one verb that reads it — the same reason
# CONFIG_MODELS_JSON is guarded, and for the same hot path (lens and launch
# probe on every call).
PROBE_DISPLAY_JSON="{}"
# Set to 1 the moment curl comes back with ANY http status. rc=0 with a status
# PROVES a process holds the port, whatever it answered — only the
# connect-failure branch establishes that nothing is there. start_if_down
# branches on this: spawning a second gateway against a held port cannot
# succeed (AddrInUse), and the corpse it leaves overwrites the pidfile.
PROBE_LISTENING=0

probe() {
    resolve_config
    PROBE_ALIASES_JSON="[]"
    PROBE_DISPLAY_JSON="{}"
    PROBE_DETAIL=""
    PROBE_LISTENING=0
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
    esc_url="$(esc "$BASE_URL/v1/models")"
    esc_tok="$(esc "$SPAWN_TOKEN_VALUE")"
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

    if [ $rc -ne 0 ] || [ -z "$code" ] || [ "$code" = "000" ]; then
        PROBE_DETAIL="no HTTP response from $BASE_URL/v1/models (curl rc=$rc)"
        return $EX_UNREACHABLE
    fi
    PROBE_LISTENING=1
    if [ "$code" = "401" ] || [ "$code" = "403" ]; then
        PROBE_DETAIL="gateway is up at $BASE_URL but rejected our token (HTTP $code); token came from ${CONFIG_PATH:-<no config resolved>}"
        return $EX_AUTH
    fi
    if [ "$code" != "200" ]; then
        PROBE_DETAIL="model-list probe returned HTTP $code from $BASE_URL/v1/models"
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
    aliases="$(jq -c "$SPAWN_SANITIZE_JQ_DEF"' [.data[]?.id // empty] | strip_display_deep' < "$body" 2>/dev/null)"
    if [ -z "$aliases" ]; then
        PROBE_DETAIL="model-list probe returned HTTP 200 but the body is not the expected JSON model list"
        return $EX_UNREACHABLE
    fi
    PROBE_ALIASES_JSON="$aliases"

    if [ "${VERB:-}" = "status" ]; then
        local disp
        # Keys go through the SAME strip as PROBE_ALIASES_JSON's values (the
        # whole object is walked after from_entries), so a lookup by served
        # alias cannot miss on a byte the other path removed. An id with no
        # display_name becomes "" — which the drift program reads as "the
        # gateway said nothing", never as a match.
        disp="$(jq -c "$SPAWN_SANITIZE_JQ_DEF"'
            [ .data[]? | select((.id // null) != null)
              | {key: (.id | tostring),
                 value: ((.display_name // "") | tostring)} ]
            | from_entries | strip_display_deep' < "$body" 2>/dev/null)"
        [ -n "$disp" ] && PROBE_DISPLAY_JSON="$disp"
    fi

    PROBE_DETAIL=""
    return $EX_OK
}

# ---------------------------------------------------------------------------
# Lock (KTD4 idempotent start).
#
# mkdir is the atomic primitive here because flock(1) does not exist on macOS.
# A holder pid inside the dir lets a lock left behind by a killed process be
# broken, so one crashed `ensure` cannot wedge every later one for good.
# ---------------------------------------------------------------------------
# Breaking a stale lock is `mv` then remove, never a bare `rm -rf`. read-then-rm
# -then-mkdir is not atomic: two waiters that read the SAME dead holder pid both
# run rm -rf, the first one's mkdir wins, and the second one's rm then deletes
# the lock the winner is holding — so both proceed into do_start_locked and both
# spawn a gateway, which is exactly the AddrInUse collision the lock exists to
# prevent. Reproduced at 2-3 simultaneous holders in 4 of 5 trials with 8
# concurrent workers against a pre-seeded stale lock. Only one contender's `mv`
# can succeed, so the loser falls through to another mkdir attempt instead.
#
# The pid-write failure is treated as LOSING the lock rather than ignored: in
# the same repro the loser's write landed on a directory that had already been
# moved away, leaving a lock dir with no pid file — and `[ -n "$holder" ]` means
# a pid-less lock can never be broken, so every later caller waited the full
# LOCK_TIMEOUT and exited 3, permanently, until the file was removed by hand.
# The mtime fallback below is the belt for any pid-less lock that still appears.
acquire_lock() {
    local waited=0
    while ! mkdir "$LOCKDIR" 2>/dev/null; do
        local holder stale=""
        holder="$(cat "$LOCKDIR/pid" 2>/dev/null)"
        if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
            stale="dead pid $holder"
        elif [ -z "$holder" ] && [ -d "$LOCKDIR" ]; then
            # A lock dir with no pid file inside. Either we caught a holder in
            # the window before its write, or a previous break left it wedged.
            # Age is the only signal available; a real holder writes its pid
            # within milliseconds of the mkdir.
            if [ -z "$(find "$LOCKDIR" -maxdepth 0 -mmin -1 2>/dev/null)" ]; then
                stale="no holder pid and older than a minute"
            fi
        fi
        if [ -n "$stale" ]; then
            say "breaking a stale gateway lock ($stale)"
            mv "$LOCKDIR" "$LOCKDIR.stale.$$" 2>/dev/null && rm -rf "$LOCKDIR.stale.$$" 2>/dev/null
            continue
        fi
        sleep 0.1
        waited=$((waited + 1))
        if [ "$waited" -gt $((LOCK_TIMEOUT * 10)) ]; then
            return 1
        fi
    done
    if ! printf '%s\n' "$$" > "$LOCKDIR/pid" 2>/dev/null; then
        # The directory we just created is already gone — another contender broke
        # it out from under us. We do NOT hold this lock; say so instead of
        # proceeding into a start that a second process is also entering.
        return 1
    fi
    LOCK_HELD=1
    return 0
}

# Ownership-checked. An unconditional rm -rf here lets a departing process delete
# a lock a DIFFERENT process has since acquired, which reopens the double-start
# the lock exists to close.
release_lock() {
    if [ "$LOCK_HELD" -eq 1 ]; then
        if [ "$(cat "$LOCKDIR/pid" 2>/dev/null)" = "$$" ]; then
            rm -rf "$LOCKDIR" 2>/dev/null
        fi
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

# Anchored to argv[0], NOT a substring of the whole command line. The substring
# form failed open in the direction that kills: any unrelated process whose argv
# merely MENTIONS the binary path — `less ~/gateway-0.1.1/target/release/gateway`,
# a tail on its log, another spawnctl — was "verified as ours" and would take
# SIGTERM then SIGKILL.
#
# It also failed closed after an upgrade. resolve_install_dir always picks the
# NEWEST ~/gateway-*, but a running process keeps the argv of the version it was
# launched from, so the moment a newer directory appeared, stop stopped
# recognizing the gateway it legitimately owns — permanently. R4 explicitly lets
# the install dir move between releases, so this is expected, not exotic.
#
# The recorded path (written beside the pidfile at start) is therefore the
# primary check; argv[0] under the versioned install root is the fallback for a
# gateway this plugin did not start.
#
# The match is on a WHOLE argv element at position 0 or 1, never a substring of
# the command line, and an executable position is not enough on its own:
#   * position 0 is a compiled binary launched directly (the real gateway)
#   * position 1 is an interpreter-launched one — for a shebang script `ps`
#     reports the INTERPRETER as argv[0] and the script as argv[1]. Verified on
#     this box; the test fixture is exactly this shape, which is why a strict
#     argv[0] rule looks correct and silently stops recognizing it.
# `--config` must also be present, because a pager or editor holding the binary
# path (`less .../gateway`) puts that path in an executable-looking position too.
# Every gateway launch carries --config; nothing else that merely names the file
# does.
_argv_names_binary() {
    local args="$1" cand="$2"
    [ -n "$cand" ] || return 1
    awk -v a="$args" -v c="$cand" 'BEGIN{
        n = split(a, f, " ")
        if (f[1] == c) exit 0
        if (n >= 2 && f[2] == c) {
            for (i = 1; i <= n; i++) if (f[i] == "--config") exit 0
        }
        exit 1
    }'
}

pid_is_gateway() {
    local pid="$1" args recorded
    kill -0 "$pid" 2>/dev/null || return 1
    args="$(pid_argv "$pid")"
    [ -n "$args" ] || return 1

    # 1. the binary this plugin recorded when it started that pid — survives an
    #    upgrade that moves the install dir underneath a running process.
    recorded="$(cat "$PIDFILE.bin" 2>/dev/null)"
    _argv_names_binary "$args" "$recorded" && return 0
    # 2. the binary we resolve today
    _argv_names_binary "$args" "${SPAWN_BIN:-}" && return 0
    # 3. any gateway binary under the versioned install root — still a positive
    #    identification, just not pinned to whichever version is newest today.
    awk -v a="$args" -v root="$SEARCH_ROOT" 'BEGIN{
        n = split(a, f, " ")
        pat = "^" root "/gateway-[^/]+/target/release/gateway$"
        if (f[1] ~ pat) exit 0
        if (n >= 2 && f[2] ~ pat) {
            for (i = 1; i <= n; i++) if (f[i] == "--config") exit 0
        }
        exit 1
    }' && return 0
    return 1
}

read_pidfile() {
    local p
    [ -f "$PIDFILE" ] || return 1
    p="$(tr -dc '0-9' < "$PIDFILE" 2>/dev/null)"
    [ -n "$p" ] || return 1
    printf '%s' "$p"
}

# ---------------------------------------------------------------------------
# Is this gateway supervised by launchd?
#
# WHY stop HAS TO ASK. On an adopted machine `stop` was a ~10s RESTART, not a
# stop: it killed the gateway, the launcher's `wait` returned, the launcher
# exited, and KeepAlive respawned the whole thing. `result:"stopped"` was true
# for about a second. The plugin already says this out loud elsewhere — the
# open-proxy fix unloads the agent first "because stopping the process only
# triggers a respawn" — it just never applied it to the everyday verb.
#
# WHY THE PARENT, NOT THE GATEWAY ITSELF. setup's launcher is the launchd job;
# the gateway is its CHILD, so the gateway's own pid never appears in
# `launchctl list`. Verified on this machine: gateway 1518's parent 1359 is the
# row `1359 0 com.shawnroos.gateway`. Both are checked anyway, because a plist
# pointed straight at the binary (the pre-adoption shape) makes the gateway the
# job itself.
#
# WHY NOT REUSE detect_supervisor. That one parses every plist in
# ~/Library/LaunchAgents through plutil to decide which agent setup should
# ADOPT — it needs an install dir, it can die, and it answers a different
# question. Asking launchd directly needs no plist, no plutil, and no install
# resolution. This is one lookup, not a second copy of that logic.
#
# Sets SUPERVISOR_LABEL. Returns 1 when nothing supervises the pid, INCLUDING
# on any machine with no launchctl at all (Linux, a container) — where the
# honest answer is "not supervised" rather than a failure.
SUPERVISOR_LABEL=""
supervising_label() {
    local pid="$1" ppid="" row
    SUPERVISOR_LABEL=""
    [ -n "$pid" ] || return 1
    [ -x "$LAUNCHCTL_BIN" ] || command -v "$LAUNCHCTL_BIN" >/dev/null 2>&1 || return 1
    ppid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -dc '0-9')"
    # PPID 1 IS NOT SUPERVISION. do_start_locked backgrounds the gateway inside
    # a subshell that then exits, so an unsupervised gateway is reparented to
    # pid 1 — launchd itself. If pid 1 ever appeared in `launchctl list`, every
    # orphan on the box would read as supervised and `stop` would refuse to
    # stop anything it started. It does not appear there today (checked), but
    # "checked once" is not a guarantee, and the cost of excluding a pid that
    # can never legitimately be a job's own pid is zero.
    [ "$ppid" = "1" ] && ppid=""
    # Column 1 of `launchctl list` is the pid; column 3 is the label. Matching
    # on the WHOLE field, never a substring: pid 15 must not match 1518.
    row="$("$LAUNCHCTL_BIN" list 2>/dev/null | awk -F'\t' -v a="$pid" -v b="${ppid:-}" \
        '$1 == a || (b != "" && $1 == b) { print $3; exit }')"
    [ -n "$row" ] || return 1
    SUPERVISOR_LABEL="$row"
    return 0
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
# Start-time secret delivery (KTD1; R7, R9).
#
# WHY A FILE AND NOT THE ENVIRONMENT
# ----------------------------------
# A variable present in a process's environment AT EXEC is readable by any
# same-user process through `ps -Eww` (verified this session: exec-time hit
# count 1). A variable the process assigns to ITSELF at runtime is not (hit
# count 0). The gateway loads `./.env.local` relative to its CWD and assigns
# with runtime set_var (upstream src/main.rs:26-45), so delivering through the
# file is the difference between the key being visible in the process table and
# not. Putting it in the child's exec environment is precisely the exposure R7
# forbids, which is why it is never done here.
#
# WHY AN INHERITED KEY IS CLEARED RATHER THAN WARNED ABOUT (AE9)
# --------------------------------------------------------------
# That dotenv load sets only variables that are currently UNSET. So an
# inherited `OPENROUTER_API_KEY` export does two bad things at once: it
# SUPPRESSES the delivered value, and it lands in the child's exec-time
# environment where `ps` can read it. A warning changes neither. The child's
# copy is therefore cleared before exec, and the operator is told the inherited
# value was ignored.
#
# The file is in-flight delivery for the duration of startup, not storage at
# rest: it is replaced on entry (never appended to) and removed the moment the
# start probe settles, on success and on failure, with cleanup() as the backstop
# for the paths that never get there.
# ---------------------------------------------------------------------------
KEY_DELIVERED=0
TOKEN_DELIVERED=0
deliver_secrets() {
    # xtrace guard: this scope holds credential values in locals, and a
    # caller running under `bash -x` would otherwise trace every one of them
    # into whatever it redirects stderr to. `local -` scopes the shell options
    # to this function, so the caller's own -x is restored on return.
    local -
    set +x
    local kc_key="" kc_tok="" have_key=0 have_tok=0

    # keychain_exists never produces the value; the read that follows is the
    # only place it is held, and it is held in a local that never reaches a
    # diagnostic, an argv or the JSON object.
    if spawn::keychain_exists "$KEYCHAIN_SERVICE" "$KEYCHAIN_ACCOUNT_OPENROUTER"; then
        kc_key="$(spawn::keychain_read "$KEYCHAIN_SERVICE" "$KEYCHAIN_ACCOUNT_OPENROUTER")"
        [ -n "$kc_key" ] && have_key=1
    fi
    # resolve_token_fallback may already have read this same item earlier in
    # this process. Reuse its value rather than spawning `security` twice for
    # one answer — a credential read is worth doing once. The unresolved and
    # config/env-sourced cases still take the read below.
    if [ "$SPAWN_TOKEN_SOURCE" = "keychain" ] && [ -n "$SPAWN_TOKEN_VALUE" ]; then
        kc_tok="$SPAWN_TOKEN_VALUE"
        have_tok=1
    elif spawn::keychain_exists "$KEYCHAIN_SERVICE" "$KEYCHAIN_ACCOUNT_TOKEN"; then
        kc_tok="$(spawn::keychain_read "$KEYCHAIN_SERVICE" "$KEYCHAIN_ACCOUNT_TOKEN")"
        [ -n "$kc_tok" ] && have_tok=1
    fi

    # R9. The gateway's auth check returns success IMMEDIATELY when its token
    # list is empty, so a config with no token and nothing to deliver does not
    # produce a gateway that rejects callers — it produces an open proxy on
    # 127.0.0.1 that forwards anything to a paid provider. Refused before the
    # spawn, so nothing is started and no delivery file is written.
    #
    # SPAWN_TOKEN_VALUE can now also hold an inherited GATEWAY_TOKEN (R27), and
    # that correctly satisfies this guard rather than weakening it: with nothing
    # delivered, TOKEN_DELIVERED stays 0, the child KEEPS the inherited export,
    # and the gateway merges it into its auth list at startup (upstream
    # src/main.rs:54-56). The list is non-empty, which is the whole claim.
    if [ -z "$SPAWN_TOKEN_VALUE" ] && [ "$have_tok" -eq 0 ]; then
        die "$EX_USAGE" "refusing to start an unauthenticated gateway: ${CONFIG_PATH:-<no config resolved>} declares no server.token and no gateway token is stored (Keychain service '$KEYCHAIN_SERVICE', account '$KEYCHAIN_ACCOUNT_TOKEN') — an empty auth token list makes the gateway an open proxy; run the setup command to store one"
    fi

    if [ "$have_key" -eq 0 ] && [ "$have_tok" -eq 0 ]; then
        # Degrade: a pre-setup machine whose config carries its own token starts
        # exactly as it did before any of this existed.
        return 0
    fi

    DELIVERY_FILE="$INSTALL_DIR/$DELIVERY_NAME"
    # REPLACE, never append. A crashed prior start can leave one behind, and an
    # appended file would hand the gateway a stale first assignment — dotenv
    # takes the first value it sees for a name.
    #
    # `rm` and not just the truncating `: >` below, and the difference is not
    # stylistic: `: >` FOLLOWS A SYMLINK. A stale `.env.local` that is a link
    # would take the OpenRouter key straight to wherever it points — outside
    # the install dir, at whatever mode that file already has. Removing the
    # name first means the create below always makes a fresh regular file.
    # (Measured: with the rm dropped, the append/mode assertions still pass —
    # truncation covers those — and only the symlink test goes red. That test
    # is what makes this line load-bearing.)
    rm -f "$DELIVERY_FILE" 2>/dev/null
    if ! (umask 077; : > "$DELIVERY_FILE") 2>/dev/null; then
        die "$EX_UNREACHABLE" "cannot write the start-time delivery file in $INSTALL_DIR"
    fi
    DELIVERY_WRITTEN=1
    # chmod as well as umask: umask only governs CREATION, and this file is
    # replaced rather than created when a stale one survived a crash.
    chmod 600 "$DELIVERY_FILE" 2>/dev/null
    {
        # SHELL BUILTIN printf, for the reason secrets.sh spells out: a builtin
        # never execs, so neither value ever reaches the process table.
        [ "$have_key" -eq 1 ] && printf 'OPENROUTER_API_KEY=%s\n' "$kc_key"
        [ "$have_tok" -eq 1 ] && printf 'GATEWAY_TOKEN=%s\n' "$kc_tok"
    } >> "$DELIVERY_FILE"
    KEY_DELIVERED="$have_key"
    TOKEN_DELIVERED="$have_tok"

    # The probe has to authenticate against the gateway it just started. When
    # the config carries no token of its own, the delivered one is the only
    # credential in play. A config token that IS present stays authoritative —
    # the gateway merges rather than substitutes, so both are valid, and
    # today's behaviour is left alone.
    #
    # Keyed on PROVENANCE, not on emptiness, since R27's fallback now populates
    # SPAWN_TOKEN_VALUE before this point. An inherited GATEWAY_TOKEN is a
    # POSSIBLY STALE copy — the child has it unset (TOKEN_DELIVERED below), so
    # the started gateway's auth list holds the delivered value and nothing
    # else, and probing with the stale one would report a rotation as exit 7.
    if [ "$SPAWN_TOKEN_SOURCE" != "config" ] && [ "$have_tok" -eq 1 ]; then
        SPAWN_TOKEN_VALUE="$kc_tok"
        SPAWN_TOKEN_SOURCE="keychain"
    fi

    if [ "$have_key" -eq 1 ] && [ -n "${OPENROUTER_API_KEY:-}" ]; then
        say "an OPENROUTER_API_KEY was already exported here — it is IGNORED and cleared from the gateway's environment, and the stored key is delivered through a mode-0600 file instead (an inherited export would both suppress it and expose it in the process table)"
    fi
    kc_key=""
    kc_tok=""
    return 0
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

    # Something IS listening on the port — it just answered wrongly (a 503
    # during its own startup, a 404 from a moved route, a 200 with a body that
    # is not a model list). curl returning an HTTP status proves the port is
    # held, so a start here spawns a process that dies on AddrInUse, and the
    # spawn overwrites the pidfile with the corpse's pid — the running process
    # becomes unmanageable through this surface. Refuse instead: only the
    # connect-failure branch (PROBE_LISTENING=0) established nothing is there.
    if [ "$PROBE_LISTENING" -eq 1 ]; then
        PROBE_DETAIL="${PROBE_DETAIL:-the probe failed} — something is already listening at $BASE_URL, so refusing to start a second gateway against a held port; fix or stop whatever holds it"
        return $EX_UNREACHABLE
    fi

    resolve_install_dir hard

    # The pidfile is a CLAIM, and this is not the only writer of it. The
    # launchd launcher (setup's spawn-launch.sh) declines to claim when the
    # recorded pid is alive and names the same binary; without the mirror of
    # that guard here, a start on a supervised machine stamps its own pid over
    # the launcher's claim, and when that process dies `status` reports
    # running:true / pid_verified:false against a corpse while the real,
    # supervised gateway runs unmanaged — stop and restart both refuse, so the
    # machine cannot be controlled through this surface at all. Observed live
    # 2026-08-10: the launcher claimed at 21:37:35, the pidfile was rewritten
    # 81 minutes later, and the rewritten pid was already dead.
    #
    # Reachable even though the probe just failed: a supervised gateway that is
    # still binding, wedged, or listening elsewhere is alive without answering.
    # A DEAD recorded pid is not a claim (nothing to protect), and a live pid
    # that argv-fails pid_is_gateway is an unrelated process on a reused pid —
    # neither blocks a start.
    local claimed_pid
    if claimed_pid="$(read_pidfile)" && pid_is_gateway "$claimed_pid"; then
        PROBE_DETAIL="${PROBE_DETAIL:-the probe failed} — but $PIDFILE already claims pid $claimed_pid, which is alive and is a gateway process; refusing to start a second one and overwrite that claim (a supervisor such as the launchd agent may own it). Stop that gateway, or unload the launchd agent, before starting one here"
        return $EX_UNREACHABLE
    fi

    # Both secrets, and the R9 refusal, before anything is spawned.
    deliver_secrets

    # R3: append, never truncate. `gw` truncates on every start and that
    # destroyed the only evidence of why a previous start died.
    mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null
    printf -- '--- spawnctl start %s ---\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$LOGFILE"

    (
        cd "$INSTALL_DIR" || exit 1
        # AE9 / R7. Cleared in the SUBSHELL, so the parent's own environment is
        # untouched and only the child loses it. Without this an inherited
        # export would suppress the delivered value (dotenv sets unset
        # variables only) AND ride into the child's exec-time environment,
        # where any same-user process reads it out of the process table.
        # The token is cleared on the same reasoning when it too is delivered:
        # the Keychain is the source of truth, and an open shell holding a
        # pre-rotation value must not out-rank it.
        [ "$KEY_DELIVERED" -eq 1 ] && unset OPENROUTER_API_KEY
        [ "$TOKEN_DELIVERED" -eq 1 ] && unset GATEWAY_TOKEN
        nohup "$SPAWN_BIN" --config "$CONFIG_PATH" >> "$LOGFILE" 2>&1 &
        printf '%s\n' "$!" > "$PIDFILE"
        # Record WHICH binary this pid was launched from, beside the pidfile.
        # pid_is_gateway verifies argv[0] against this rather than against
        # whatever resolve_install_dir picks today, so unpacking a newer
        # ~/gateway-* release cannot make stop stop recognizing a gateway it
        # legitimately owns (R4 lets the install dir move between releases).
        printf '%s\n' "$SPAWN_BIN" > "$PIDFILE.bin"
    )
    STARTED=1

    local waited=0
    while :; do
        probe
        rc=$?
        # The delivery file's whole life is this window: the gateway has read it
        # by the time it answers a probe, and a start that never answers is not
        # going to read it either. Removed on BOTH settled outcomes, not only
        # the happy one — a failure that leaves a key on disk is the exact state
        # KTD1 says must not exist.
        [ $rc -eq $EX_OK ] && { remove_delivery; return $EX_OK; }
        [ $rc -eq $EX_AUTH ] && { remove_delivery; return $EX_AUTH; }
        sleep 0.2
        waited=$((waited + 1))
        if [ "$waited" -gt $((START_TIMEOUT * 5)) ]; then
            remove_delivery
            say "started $SPAWN_BIN but it never answered the model-list probe within ${START_TIMEOUT}s"
            say "last 10 log lines from $LOGFILE:"
            # KTD5 free-form sink: the gateway's own log carries upstream error
            # bodies and provider prose, so these bytes are as untrusted as a
            # model response. Piped through the sanitizer, never straight to the
            # terminal.
            tail -10 "$LOGFILE" 2>/dev/null | spawn::sanitize_stream >&2
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
# Normalizes SHAPE, not just syntax. `jq -c '.'` succeeds on any valid JSON, so a
# table that is an array, or whose aliases map to scalars, used to pass this guard
# and reach the two jq programs in `status` — where `.value.context_window` and
# `has($a)` error, the command substitution yields "", --argjson rejects it, emit
# wrote a bare newline and the script still exited 0 against a live gateway. That
# is exit 0 with nothing to parse: the one failure a consumer cannot distinguish
# from success. models.json is hand-maintained metadata by design (KTD7), so a
# typo here is the expected input, not an exotic one. launch.sh hardened its own
# read of this same file; this read was left open.
#
# U2 (KTD3): `families`, `no_family_alias` and `chain_policy` get the same
# shape treatment as `aliases` — a malformed families block collapses to `{}`,
# a malformed no_family_alias to `null`, a malformed chain_policy to `{}`,
# rather than surviving `jq -c '.'`'s syntax-only check and erroring inside a
# downstream program the way the pre-KTD7 `aliases` read did. The drift
# computation in `status` reads only `.aliases` from this table, so a malformed
# families block cannot touch it either way — this normalization exists so a
# future reader (this file's own --describe, or a caller) can consume the
# grammar without its own defensive jq.
table_json() {
    local empty='{"aliases":{},"families":{},"no_family_alias":null,"chain_policy":{}}'
    if [ -f "$MODELS_JSON" ]; then
        jq -c "$SPAWN_MODELS_ALIASES_JQ_DEF$SPAWN_MODELS_GRAMMAR_JQ_DEF"'
            if (type == "object" and ((.aliases // {}) | type) == "object")
            then {
                aliases: spawn_aliases,
                families: safe_families,
                no_family_alias: ((.no_family_alias // null) as $n | if ($n|type) == "string" then $n else null end),
                chain_policy: safe_chain_policy
            }
            else {aliases:{}, families:{}, no_family_alias:null, chain_policy:{}} end
        ' < "$MODELS_JSON" 2>/dev/null \
            || printf '%s' "$empty"
    else
        printf '%s' "$empty"
    fi
}

# ---------------------------------------------------------------------------
# --describe (R10, R14, KD2) — the control layer's contract as data.
#
# Every value is projected from what this script actually runs on: the EX_*
# constants, the verb list the case below accepts, the shared enum table and the
# shared remedy table. A caller reconciles against the running version instead of
# a table it copied once and now hard-codes.
# ---------------------------------------------------------------------------
emit_describe() {
    local ev grammar
    ev="$(jq -n \
        --arg r_usage "$(remedy_for usage)" \
        --arg r_unreach "$(remedy_for unreachable)" \
        --arg r_alias "$(remedy_for alias_unknown)" \
        --arg r_auth "$(remedy_for auth_rejected)" \
        --arg r_int "$(remedy_for internal)" \
        '[{value:"usage",         exit_code:2, remedy:$r_usage},
          {value:"unreachable",   exit_code:3, remedy:$r_unreach},
          {value:"alias_unknown", exit_code:4, remedy:$r_alias},
          {value:"auth_rejected", exit_code:7, remedy:$r_auth},
          {value:"internal",      exit_code:2, remedy:$r_int}]')" || return 1

    # U2 (KTD3, KD6): table_json() already normalizes families/no_family_alias/
    # chain_policy shape-safe (see the function above), so this needs no
    # further defense here. Read with the gateway down, with no install and
    # with no config — table_json() only touches MODELS_JSON on disk.
    grammar="$(table_json)"

    emit "$(jq -nc --argjson errors "$ev" --arg base "$BASE_URL" --argjson grammar "$grammar" \
        "$(spawn::envelope_jq plugin)"' + {
          ok:true, error:null, exit_code:0,
          response_kind:"describe",
          surface:"spawnctl.sh",
          summary:"Start, stop and report on the local gateway process, and answer the one preflight question the other two scripts ask.",
          base_url:$base,
          families:$grammar.families,
          no_family_alias:$grammar.no_family_alias,
          chain_policy:$grammar.chain_policy,
          verbs:[
            {name:"status",  argument:null,
             note:"never starts anything; exit 3 is a normal answer meaning the gateway is down"},
            {name:"ensure",  argument:"alias (optional)",
             note:"starts the gateway if it is down, then checks the alias against the served list; the single owner of exit 4"},
            {name:"start",   argument:null,  note:"idempotent; a start that does not serve exits non-zero"},
            {name:"stop",    argument:null,
             note:"exits 0 for stopped, not_running and stale_pidfile; refuses to signal an unmanaged or recycled pid"},
            {name:"restart", argument:null,  note:"a refused stop is a failed restart, never a green one"}
          ],
          flags:[
            {name:"--help",     value:null, required:false, default:null,
             note:"exit 2 with help_requested:true — not a usage error"},
            {name:"--describe", value:null, required:false, default:null,
             note:"this document; exit 0; needs no running gateway, no install and no config"}
          ],
          exit_codes:[
            {code:0, error:null,            origin:"own", meaning:"the verb did what it says"},
            {code:2, error:"usage",         origin:"own",
             meaning:"unknown or missing verb, help, or a stop that refused to signal; branch on help_requested"},
            {code:3, error:"unreachable",   origin:"own",
             meaning:"the gateway is not answering; for status this is an answer, not a malfunction"},
            {code:4, error:"alias_unknown", origin:"own",
             meaning:"ensure only: the gateway is up but does not serve that alias"},
            {code:7, error:"auth_rejected", origin:"own",
             meaning:"the gateway answered and refused our token; deliberately not exit 3"}
          ],
          error_values:$errors,
          response_fields:[
            {name:"schema",           always:true,  note:"the version of this contract"},
            {name:"ok",               always:true,  note:"boolean; agrees with exit_code"},
            {name:"error",            always:true,  note:"enum value or null, never prose"},
            {name:"remedy",           always:true,  note:"what to do about it; null only on success"},
            {name:"detail",           always:true,  note:"human-readable diagnostic; the only prose field"},
            {name:"content_trust",    always:true,  note:"how far the payload may be trusted"},
            {name:"content_notice",   always:true,  note:"the rule that follows from content_trust"},
            {name:"exit_code",        always:true,  note:"the process exit status, restated in the data"},
            {name:"verb",             always:false, note:"which verb answered"},
            {name:"running",          always:false, note:"did the probe reach a serving gateway"},
            {name:"base_url",         always:false, note:"where the probe looked"},
            {name:"served_aliases",   always:false, note:"the aliases the gateway reports; the real allowlist"},
            {name:"alias",            always:false, note:"ensure only: the alias that was checked"},
            {name:"config",           always:false, note:"the resolved gateway.yaml path; a path, never a token"},
            {name:"install_dir",      always:false, note:"the resolved install directory"},
            {name:"install_dir_error",always:false, note:"why resolution failed, when it did"},
            {name:"binary",           always:false, note:"the gateway executable this script would run"},
            {name:"log",              always:false, note:"where a started gateway writes"},
            {name:"pidfile",          always:false, note:"where the managed pid is recorded"},
            {name:"pid",              always:false, note:"the recorded pid"},
            {name:"pid_verified",     always:false, note:"true only when that pid is live AND its argv names our binary"},
            {name:"started",          always:false, note:"ensure only: did this call start the gateway"},
            {name:"result",           always:false, note:"stop only: stopped, not_running, stale_pidfile, unmanaged or pid_mismatch"},
            {name:"models",           always:false, note:"status only: the plugin table, as data"},
            {name:"drift",            always:false, note:"status only: the four drift classes below"},
            {name:"help_requested",   always:false, note:"true only for --help; present on every error response"},
            {name:"families",        always:false, note:"--describe only: the declared family -> tier -> alias grammar (KTD3), same table lens.sh and launch.sh describe"},
            {name:"no_family_alias", always:false, note:"--describe only: the alias prose naming no family resolves to"},
            {name:"chain_policy",    always:false, note:"--describe only: which surfaces (agent, session, bg-agent) may resolve to a chain alias (KTD4)"}
          ],
          drift_kinds:[
            {name:"missing_from_table", note:"a served alias the plugin table does not list, and which the gateway says resolves to something the table does not already carry"},
            {name:"unknown_resolution", note:"a served alias the plugin table does not list and whose resolution the gateway does not state; not assumed equivalent to anything"},
            {name:"missing_window",     note:"a table entry with no declared context window"},
            {name:"model_drift",        note:"an alias whose upstream model string moved; each entry carries alias, recorded and current"}
          ],
          drift_entry_fields:["alias","recorded","current"]
        }')" || return 1
    return 0
}

# ---------------------------------------------------------------------------
# Verbs
# ---------------------------------------------------------------------------
VERB="${1:-}"
[ $# -gt 0 ] && shift

case "$VERB" in
    start|stop|restart|status|ensure) ;;
    --describe)
        # R10. Answered HERE — before resolve_config, before resolve_install_dir
        # and before any probe — so the contract is readable with the gateway
        # down, with no install found and with no gateway.yaml on the box. A
        # caller reads it in order to interpret a failure, so it must not need
        # the thing that failed.
        #
        # It requires jq, like every other success-shaped response in this
        # plugin: the pure-bash tier encodes failures only, because building a
        # payload with no encoder means hand-writing the envelope, and that is
        # the drift R23 exists to close. With no jq, need_jq answers with the
        # standard no-encoder object at exit 2.
        need_jq
        emit_describe || die "$EX_USAGE" "could not encode the describe object"
        exit $EX_OK
        ;;
    -h|--help|help)
        # R11: help is exit 2 like a usage error — the enum is frozen — but it
        # is NOT the same event, and the difference is now a field rather than
        # the English in `detail`. Split from the ""-arm below on purpose: "you
        # asked me to explain myself" and "you forgot the verb" were previously
        # the same branch, which is precisely the pair a machine has to tell
        # apart.
        HELP_REQUESTED=true
        printf 'usage: spawnctl.sh {start|stop|restart|status|ensure [alias]} | --describe | --help\n' >&2
        need_jq
        REMEDY="Nothing is broken — this was a help request, and exit 2 is what the frozen enum has for it. Branch on help_requested, not on the code. Call --describe for the same contract as data." \
            die "$EX_USAGE" "help requested"
        ;;
    "")
        printf 'usage: spawnctl.sh {start|stop|restart|status|ensure [alias]} | --describe | --help\n' >&2
        need_jq
        REMEDY="Call again with one of the verbs: start, stop, restart, status, ensure. Run --describe for the machine-readable list." \
            die "$EX_USAGE" "no verb given"
        ;;
    *)
        need_jq
        REMEDY="Call again with one of the verbs: start, stop, restart, status, ensure. Run --describe for the machine-readable list." \
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
                --arg rem "$(remedy_for alias_unknown)" \
                "$(spawn::envelope_jq plugin)"' + {ok:false, verb:"ensure",
                  error:"alias_unknown", alias:$a, served_aliases:$served,
                  remedy:$rem, exit_code:$c}')" \
        || die "$EX_USAGE" "could not encode the alias_unknown object"
            exit $EX_ALIAS
        fi
    fi

    # `config` is reported here for the same reason `status` reports it, and in
    # the same field with the same shape. Without it, lens.sh and launch.sh had
    # to spawn a SECOND spawnctl running `status` purely to read this path —
    # and `status` re-resolves the install dir, re-parses the config and fires
    # another live curl probe, on the fan-out hot path, for one string this
    # process already holds. It is a filesystem path, not a credential; the
    # token stays where it is, resolved locally in each process (KTD6).
    emit "$(jq -nc \
        --arg base "$BASE_URL" \
        --arg alias "$ALIAS" \
        --arg cfg "${CONFIG_PATH:-}" \
        --argjson served "$PROBE_ALIASES_JSON" \
        --argjson started "$([ $STARTED -eq 1 ] && echo true || echo false)" \
        "$(spawn::envelope_jq plugin)"' + {ok:true, verb:"ensure", running:true,
          started:$started, base_url:$base,
          alias:(if $alias == "" then null else $alias end),
          config:(if $cfg == "" then null else $cfg end),
          served_aliases:$served, error:null, exit_code:0}')" \
        || die "$EX_USAGE" "could not encode the ensure object"
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
        "$(spawn::envelope_jq plugin)"' + {ok:true, verb:"start", running:true,
          started:$started, base_url:$base,
          pid:(if $pid == "" then null else ($pid|tonumber) end),
          log:$log, served_aliases:$served, error:null, exit_code:0}')" \
        || die "$EX_USAGE" "could not encode the start object"
    exit $EX_OK
    ;;

stop)
    resolve_install_dir hard
    pid="$(read_pidfile)"
    if [ -z "$pid" ]; then
        probe
        # A listener that answered ANYTHING proves a gateway is there. Keying
        # this on EX_OK alone meant a 401 — the gateway answering, with a
        # token it did not like — read as "nothing is running": the empty-pid
        # branch reported a clean stop that never happened, and the dead-pid
        # branch below deleted the ownership record while a gateway served,
        # which is the unstoppable-through-this-surface state this probe was
        # added to prevent. PROBE_LISTENING is the signal do_start_locked
        # already uses for the same decision.
        if [ "$PROBE_LISTENING" -eq 1 ]; then
            say "a gateway is serving at $BASE_URL but $PIDFILE names no pid — refusing to guess which process to signal"
            emit "$(jq -nc --arg p "$PIDFILE" --argjson c $EX_USAGE \
                --arg rem "Find the serving process yourself and stop it, or restart the box's gateway by hand; this script refuses to guess which pid to signal." \
                "$(spawn::envelope_jq plugin)"' + {ok:false, verb:"stop",
                  result:"unmanaged", error:"usage",
                  detail:"a gateway is serving but the pidfile is empty or absent",
                  remedy:$rem, pidfile:$p, exit_code:$c}')" \
        || die "$EX_USAGE" "could not encode the stop refusal object"
            exit $EX_USAGE
        fi
        emit "$(jq -nc --arg p "$PIDFILE" \
            "$(spawn::envelope_jq plugin)"' + {ok:true, verb:"stop",
              result:"not_running", pid:null, pidfile:$p, error:null,
              exit_code:0}')" \
        || die "$EX_USAGE" "could not encode the stop not_running object"
        exit $EX_OK
    fi

    if ! kill -0 "$pid" 2>/dev/null; then
        # Probe BEFORE declaring success. This branch used to delete the pidfile
        # and return ok:true while a gateway was still answering on the base URL,
        # which is a wrong-success on the plugin's own bar — and it destroyed the
        # only record of the live process, so the next stop fell into the
        # empty-pidfile branch and the gateway became unstoppable through this
        # surface. The empty-pidfile branch above already probes for exactly this
        # reason; this one did not. The state is not exotic: do_start_locked
        # writes $! before any liveness check, so a spawn that dies instantly on
        # AddrInUse against a gateway `gw` already started creates it by our hand.
        probe
        # A listener that answered ANYTHING proves a gateway is there. Keying
        # this on EX_OK alone meant a 401 — the gateway answering, with a
        # token it did not like — read as "nothing is running": the empty-pid
        # branch reported a clean stop that never happened, and the dead-pid
        # branch below deleted the ownership record while a gateway served,
        # which is the unstoppable-through-this-surface state this probe was
        # added to prevent. PROBE_LISTENING is the signal do_start_locked
        # already uses for the same decision.
        if [ "$PROBE_LISTENING" -eq 1 ]; then
            say "pid $pid is dead but a gateway is still serving at $BASE_URL — refusing to report a stop that did not happen, and leaving $PIDFILE alone"
            emit "$(jq -nc --argjson pid "$pid" --arg p "$PIDFILE" --argjson c $EX_USAGE \
                --arg rem "A gateway is still serving under a pid this script did not record, so the pidfile was left alone. Stop that process yourself, then run start." \
                "$(spawn::envelope_jq plugin)"' + {ok:false, verb:"stop",
                  result:"unmanaged", pid:$pid, pidfile:$p, error:"usage",
                  detail:"the recorded pid is dead but a gateway is still serving; not stopped",
                  remedy:$rem, exit_code:$c}')" \
        || die "$EX_USAGE" "could not encode the stop refusal object"
            exit $EX_USAGE
        fi
        rm -f "$PIDFILE" "$PIDFILE.bin"
        emit "$(jq -nc --argjson pid "$pid" \
            "$(spawn::envelope_jq plugin)"' + {ok:true, verb:"stop",
              result:"stale_pidfile", pid:$pid, error:null, exit_code:0}')" \
        || die "$EX_USAGE" "could not encode the stop stale_pidfile object"
        exit $EX_OK
    fi

    # Recycled pid: a live process holds it, but its argv is not our binary.
    # Report, do not kill.
    if ! pid_is_gateway "$pid"; then
        say "pid $pid is live but its argv does not name $SPAWN_BIN — recycled pid, refusing to signal it"
        # Only argv[0], never the arguments. This object goes to stdout, into an
        # agent transcript, and from there into summaries and files — and the
        # process we are describing is by definition NOT ours, so its arguments
        # may hold that process's own secrets. KTD6 refuses to put our token in
        # argv precisely because the process table is readable by anything on the
        # box; harvesting another process's argv and republishing it would be the
        # same leak with the roles reversed. The executable answers the
        # diagnostic question ("this pid is /usr/bin/foo, not the gateway")
        # without the copy. Sanitized as display text (KTD5).
        emit "$(jq -nc --argjson pid "$pid" --arg bin "$SPAWN_BIN" \
            --arg rem "The recorded pid was recycled by an unrelated process, so nothing was signalled. Delete the stale pidfile named in this response, then run start." \
            --arg cmd "$(spawn::sanitize_for_display "$(pid_argv "$pid" | awk '{print $1}')")" --argjson c $EX_USAGE \
            "$(spawn::envelope_jq plugin)"' + {ok:false, verb:"stop",
              result:"pid_mismatch", pid:$pid, expected_binary:$bin,
              actual_command:$cmd, error:"usage",
              detail:"pidfile pid belongs to an unrelated process; not signalled",
              remedy:$rem, exit_code:$c}')" \
        || die "$EX_USAGE" "could not encode the stop pid_mismatch object"
        exit $EX_USAGE
    fi

    # SUPERVISED: killing this is a ~10s restart, not a stop. Refuse BEFORE
    # signalling anything — a kill followed by an honest "it will come back"
    # would still churn the machine and still leave the caller's intent
    # unmet, and this script's other two honest outcomes (`unmanaged`,
    # `pid_mismatch`) both refuse rather than act. Nothing is signalled here,
    # so the gateway keeps serving and no state changes.
    #
    # Unloading the agent is deliberately NOT done on the operator's behalf:
    # setup treats owning a step in the machine's startup path as needing
    # explicit consent (exit 8), and a `stop` that quietly unloaded a launchd
    # job would take that decision without asking. The remedy names the exact
    # command instead.
    if supervising_label "$pid"; then
        say "pid $pid is supervised by the launchd job '$SUPERVISOR_LABEL' — killing it would only trigger a respawn, so nothing was signalled"
        emit "$(jq -nc --argjson pid "$pid" --arg label "$SUPERVISOR_LABEL" \
            --arg p "$PIDFILE" --argjson c $EX_USAGE \
            --arg rem "This gateway is supervised by launchd, which restarts it when it dies. Unload the agent to actually stop it: launchctl unload ~/Library/LaunchAgents/<the plist declaring this label>. Re-run setup to bring it back." \
            "$(spawn::envelope_jq plugin)"' + {ok:false, verb:"stop",
              result:"supervised", pid:$pid, supervisor_label:$label,
              pidfile:$p, error:"usage",
              detail:("the gateway is supervised by the launchd job \($label), which respawns it — a kill here would report a stop that lasts about a second"),
              remedy:$rem, exit_code:$c}')" \
        || die "$EX_USAGE" "could not encode the stop supervised object"
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
    rm -f "$PIDFILE" "$PIDFILE.bin"
    emit "$(jq -nc --argjson pid "$pid" \
        "$(spawn::envelope_jq plugin)"' + {ok:true, verb:"stop",
          result:"stopped", pid:$pid, error:null, exit_code:0}')" \
        || die "$EX_USAGE" "could not encode the stop stopped object"
    exit $EX_OK
    ;;

restart)
    # Capture stop's object rather than discarding it, so its refusal reason can
    # travel into the error below.
    stop_out="$(bash "${BASH_SOURCE[0]}" stop 2>/dev/null)"
    stop_rc=$?
    # A refused stop is a FAILED restart. stop exits 0 for every outcome that
    # means "nothing left to stop" (stopped, not_running, stale_pidfile); the
    # non-zero ones — unmanaged, pid_mismatch — signalled nothing, so the old
    # process is still serving. start_if_down then probes, finds it up, and this
    # verb used to report ok:true/exit 0 while the caller's whole reason for
    # restarting (a changed gateway.yaml, a new binary) was silently not
    # honoured. It also reported a `pid` re-read from the pidfile — the very pid
    # the stop it just ran had refused to signal as unrelated. The `start` verb
    # applies "announced-but-broken is never success" a few lines above; restart
    # did not apply it to its own stop leg.
    if [ "$stop_rc" -ne "$EX_OK" ]; then
        # .detail first: post-R23 `.error` carries the ENUM and the prose moved
        # to `.detail`, so reading .error here printed "(usage)" where the
        # sentence belonged. Same fix the lens and launch rewraps already carry.
        stop_reason="$(printf '%s' "$stop_out" | jq -r '.detail // .error // "no reason given"' 2>/dev/null)"
        # The supervised case gets its own remedy. Before the stop verb learned
        # to detect launchd, restart on an adopted machine "worked" by
        # accident: the kill triggered a respawn, start_if_down probed, found a
        # gateway up, and reported success. It really did restart — but only
        # because something this script does not manage put it back, which is
        # not a thing to rely on and not a thing to describe as a restart this
        # verb performed. Restarting a supervised job means going through the
        # supervisor, and the operator is told exactly how rather than having
        # this script reach into launchd on its own (same reasoning as stop).
        if [ "$(printf '%s' "$stop_out" | jq -r '.result // ""' 2>/dev/null)" = "supervised" ]; then
            stop_label="$(printf '%s' "$stop_out" | jq -r '.supervisor_label // "the launchd job"' 2>/dev/null)"
            die "$EX_USAGE" "restart aborted: this gateway is supervised by the launchd job '$stop_label', so restarting it means restarting that job, not killing the process — a kill here is undone by KeepAlive within seconds. Run: launchctl kickstart -k gui/\$UID/$stop_label (or unload and load its plist). Nothing was signalled and the gateway is still serving."
        fi
        die "$EX_USAGE" "restart aborted: the stop phase exited $stop_rc without stopping the running gateway ($stop_reason) — the old process is still serving and was NOT replaced"
    fi
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
        "$(spawn::envelope_jq plugin)"' + {ok:true, verb:"restart", running:true,
          base_url:$base,
          pid:(if $pid == "" then null else ($pid|tonumber) end),
          stop_exit_code:$stop_rc, served_aliases:$served, error:null,
          exit_code:0}')" \
        || die "$EX_USAGE" "could not encode the restart object"
    exit $EX_OK
    ;;

status)
    resolve_config
    # Soft: an unresolvable install dir must not stop status from reporting
    # liveness, which is the question status exists to answer. (A set-but-
    # invalid SPAWN_INSTALL_DIR still hard-fails inside resolve_install_dir.)
    resolve_install_dir soft
    install_note="$INSTALL_ERR"

    probe
    prc=$?

    pid="$(read_pidfile)"
    pid_ok=false
    if [ -n "$pid" ] && [ -n "$SPAWN_BIN" ] && pid_is_gateway "$pid"; then
        pid_ok=true
    fi

    tbl="$(table_json)"
    # KTD5, and the promise skills/status/SKILL.md already makes: everything the
    # config and the alias table supply as DISPLAY text is sanitized before it is
    # printed. Both blocks below are display-only — a consumer reads them to show
    # a human what drifted; nothing parses them back into a path or a URL — so a
    # deep strip cannot break a functional value the way sanitizing `config` or
    # `base_url` would.
    # R17/KD8. A served alias the table does not list is only drift if it is a
    # DIFFERENT thing from something the table already lists, and that is decided
    # from what the gateway says each alias resolves to — never from one name
    # being a prefix of another. Prefix-stripping would hide a genuinely new
    # model served as `claude-<new>`, which is the worse error in the other
    # direction.
    #
    # Two sources say what an alias resolves to, and they are not equal in
    # strength:
    #
    #   * the config's `models:` block ($cfg[a].model) — the model string
    #     itself. Authoritative BOTH ways: equal strings mean the same model,
    #     different strings mean different models.
    #   * the model list's display_name ($disp[a]) — the gateway's own label.
    #     Authoritative only for SAMENESS: the gateway generates the claude-*
    #     aliases itself, so they never appear in `models:`, and an identical
    #     display_name is the gateway stating they present as one model. Two
    #     DIFFERENT labels prove nothing — a label is prose, and one model can
    #     be labelled twice.
    #
    # So: the model string decides when we have it; display equality may only
    # suppress; and an alias with neither a config entry nor a matching label is
    # reported as unknown_resolution rather than being assumed equivalent.
    # Assuming equivalence there is the same class of error as the false alarm
    # this replaces, just pointing the other way.
    drift="$(jq -nc \
        --argjson served "$PROBE_ALIASES_JSON" \
        --argjson table "$tbl" \
        --argjson cfg "$CONFIG_MODELS_JSON" \
        --argjson disp "$PROBE_DISPLAY_JSON" \
        "$SPAWN_SANITIZE_JQ_DEF"'
        ($table.aliases // {}) as $t |
        # What the aliases the table DOES list resolve to. The config wins where
        # it knows; the recorded model string in the table stands in where it
        # does not, so a table entry for an alias absent from the models block
        # still anchors its twins.
        ([ $t | keys[] | (($cfg[.].model) // ($t[.].model) // empty) ]) as $known_models |
        ([ $t | keys[] | (($disp[.]) // "") | select(. != "") ]) as $known_labels |
        ([ $served[] as $a | select(($t | has($a)) | not)
           | { alias: $a,
               model: (($cfg[$a].model) // null),
               label: (($disp[$a]) // "") } ]) as $unlisted |
        # map/any, not index: a chain alias resolves to an ARRAY of model
        # strings, and index() on an array argument searches for a subsequence
        # rather than testing membership.
        ([ $unlisted[] | . as $u
           | $u + { verdict:
                   (if $u.model != null then
                        (if ($known_models | map(. == $u.model) | any)
                         then "twin" else "drift" end)
                    elif $u.label != ""
                         and ($known_labels | map(. == $u.label) | any) then
                        "twin"
                    else "unknown" end) } ]) as $judged |
        {
          missing_from_table: [ $judged[] | select(.verdict == "drift") | .alias ],
          unknown_resolution: [ $judged[] | select(.verdict == "unknown") | .alias ],
          missing_window: [ $t | to_entries[]
                            | select((.value.context_window // null) == null)
                            | .key ],
          model_drift: [ $t | to_entries[] as $e
                         | ($cfg[$e.key] // null)
                         | select(. != null)
                         | select(.model != $e.value.model)
                         | {alias: $e.key, recorded: $e.value.model, current: .model} ]
        } | strip_display_deep')"

    models_view="$(jq -nc --argjson table "$tbl" "$SPAWN_SANITIZE_JQ_DEF"'
        [ ($table.aliases // {}) | to_entries[]
          | {alias: .key,
             context_window: (.value.context_window // null),
             source: (.value.source // null),
             model: (.value.model // null),
             chain: (.value.chain // false)} ]
        | strip_display_deep')"

    running=false
    [ $prc -eq $EX_OK ] && running=true

    # R23: `error` is the enum, and the probe's prose — which is a real answer
    # here, not a malfunction: exit 3 from `status` means "the gateway is down"
    # — travels in `detail`. This emit used to put that prose straight into
    # `error`, which is exactly the divergence a consumer's `.error` switch
    # tripped over.
    status_enum="$(spawn::enum_for_code "$prc")"

    # `|| die` because emit now refuses an empty payload: if either jq program
    # above ever errors again, this must become an honest non-zero failure rather
    # than a silent exit-0 with no object on stdout.
    emit "$(jq -nc \
        --argjson running "$running" \
        --argjson served "$PROBE_ALIASES_JSON" \
        --arg base "$BASE_URL" \
        --arg install "${INSTALL_DIR:-}" \
        --arg bin "${SPAWN_BIN:-}" \
        --arg cfg "${CONFIG_PATH:-}" \
        --arg log "$LOGFILE" \
        --arg pidfile "$PIDFILE" \
        --arg pid "${pid:-}" \
        --argjson pid_verified "$pid_ok" \
        --arg install_error "$(spawn::sanitize_for_display "${install_note:-}")" \
        --argjson drift "$drift" \
        --argjson models "$models_view" \
        --arg detail "$(spawn::sanitize_for_display "${PROBE_DETAIL:-}")" \
        --arg errenum "$status_enum" \
        --arg rem "$(remedy_for "$status_enum")" \
        --argjson c "$prc" \
        "$(spawn::envelope_jq plugin)"' + {ok: ($c == 0), verb:"status", running:$running, base_url:$base,
          install_dir:(if $install == "" then null else $install end),
          binary:(if $bin == "" then null else $bin end),
          config:(if $cfg == "" then null else $cfg end),
          install_dir_error:(if $install_error == "" then null else $install_error end),
          log:$log, pidfile:$pidfile,
          pid:(if $pid == "" then null else ($pid|tonumber) end),
          pid_verified:$pid_verified,
          served_aliases:$served, models:$models, drift:$drift,
          error:(if $errenum == "" then null else $errenum end),
          detail:(if $detail == "" then null else $detail end),
          remedy:(if $rem == "" then null else $rem end),
          exit_code:$c}')" \
        || die "$EX_USAGE" "could not encode the status object (models table at $MODELS_JSON may be malformed)"
    exit $prc
    ;;
esac
