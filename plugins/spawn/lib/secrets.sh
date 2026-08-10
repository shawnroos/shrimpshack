#!/usr/bin/env bash
# secrets.sh — the gateway plugin's only toucher of the Keychain and the
# password dialog (plan U1).
#
# WHY THIS EXISTS
# ---------------
# Every function below is a one-line shell command with a trap in it. Written
# inline at each call site, each trap would have to be re-avoided every time,
# and the plugin already has the scar to prove that does not happen: three
# byte-identical `server.token` parsers, one of which drifted. So `security` and
# `osascript` are touched HERE and nowhere else, and the traps are closed once.
#
# THE TRAPS, ALL VERIFIED AGAINST THE REAL BINARIES (KTD10, KTD2)
# ---------------------------------------------------------------
#   * `security add-generic-password -w <value>` puts the secret in ARGV, which
#     any same-user process reads out of the process table. The write path feeds
#     the value on STDIN to a TRAILING BARE `-w` instead. Nothing may ever be
#     placed after that bare `-w` — it swallows the next argument as the value,
#     silently eating a positional flag.
#   * the bare form wants the value TWICE (value, then confirmation). Fed once,
#     the real binary stores an EMPTY password and STILL EXITS 0. Exit status is
#     therefore worthless: every write reads back and byte-compares before it
#     reports success. That compare is the only proof a write happened.
#   * reads use `find-generic-password -w`, which prints only the password on
#     stdout. `-g` is FORBIDDEN: it writes the value to stderr.
#   * `-T` and `-A` are both omitted on add. The default ACL reads silently and
#     never raises a prompt.
#   * `-U` is always passed: without it, adding an item that already exists
#     fails with exit 45. Exit 44 means no such item. Delete removes ONE match
#     per call, so it loops until 44 — duplicate items are possible.
#   * every pipe carrying a secret uses the SHELL BUILTIN printf. A builtin
#     never execs, so the value never reaches the process table at all; the
#     external /usr/bin/printf would put it straight into argv.
#
# WHAT THIS BUYS, AND WHAT IT DOES NOT (KTD9)
# -------------------------------------------
# The default ACL authenticates the READER BINARY (/usr/bin/security), not the
# calling process, so any same-user process can read these items silently —
# roughly a mode-0600 file as far as same-user agents are concerned. The real
# wins are encryption at rest, protection while the keychain is locked,
# cross-user isolation, and staying out of dotfile backups. Closing the
# same-user hole needs a code-signed reader binary plus a partition list, and is
# deliberately out of scope. This is documented, not solved.
#
# SHAPE
# -----
# This file is SOURCED, so it never calls `exit` — that would kill the caller —
# and it reads every optional environment variable with `${VAR:-}` because its
# callers run under `set -u`. Like common.sh it prints NOTHING to stderr and
# holds no diagnostics, which is why it does not source sanitize.sh: it has no
# terminal sink to defend, and a say() here would be dead code satisfying a
# lint rather than protecting anything. The escapes.bats sink lint still scans
# this file — see the annotated carve-out there, which exempts it from the three
# STRUCTURAL checks only. Callers own their own diagnostics, and must not print
# a returned value.
#
# RETURN CODES are local to this file and named below; they are not the plugin's
# exit-code enum, and no caller should pass one through as a process exit code
# without mapping it.

# ---------------------------------------------------------------------------
# Seams (KTD8). Same shape as SPAWN_CLAUDE_BIN in launch.sh: every external
# entry point is env-overridable so a test can point the whole path at a
# fixture. A test that touched the real Keychain would either prompt for an
# unlock or write to this machine's login keychain, and both of those are how a
# "passing" suite stops meaning anything.
# ---------------------------------------------------------------------------
SPAWN_SECURITY_BIN="${SPAWN_SECURITY_BIN:-/usr/bin/security}"
SPAWN_OSASCRIPT_BIN="${SPAWN_OSASCRIPT_BIN:-/usr/bin/osascript}"

# Return codes.
SPAWN_SECRET_OK=0
SPAWN_SECRET_FAIL=1       # the store or the dialog failed
SPAWN_SECRET_EMPTY=2      # refused: an empty value is not a secret
SPAWN_SECRET_CANCELLED=3  # the operator pressed Cancel

# Generated-token shape. 43 characters of [A-Za-z0-9] is ~256 bits, and the
# charset is URL- and shell-safe so the value can never need quoting anywhere it
# travels (KD4: a value no human types has no shell history and no paste buffer).
SPAWN_TOKEN_LEN="${SPAWN_TOKEN_LEN:-43}"

# ---------------------------------------------------------------------------
# xtrace guard. A caller running with `set -x` would echo every secret-bearing
# command — including the builtin printf whose entire purpose is keeping the
# value out of sight. `bash -x lib/setup.sh` while debugging, or a parent that
# exported SHELLOPTS=xtrace, is enough to spray a pasted API key across stderr,
# which in an agent harness is a transcript.
#
# Every secret-touching function opens with `local -`, which snapshots the
# shell options and lets bash restore them on return — including on an early
# return, with no paired call to forget. The obvious hand-rolled version,
#
#     xt="$(spawn::xtrace_off)"      # WRONG
#
# does nothing at all: command substitution forks a subshell, so the `set +x`
# applies to that subshell and dies with it while the caller keeps tracing.
# That shape shipped here once and traced the secret five times over.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# spawn::keychain_read <service> <account>
# Prints the stored password on stdout. Returns 1 when there is no such item.
#
# `-w` prints ONLY the password, with a trailing newline that the caller's
# command substitution strips. `-g` would print it to stderr, where it would
# land in a log or a transcript; it is never used here, and secrets.bats asserts
# that against this source.
# ---------------------------------------------------------------------------
spawn::keychain_read() {
    local -
    set +x
    local service="$1" account="$2" out rc
    out="$("$SPAWN_SECURITY_BIN" find-generic-password -a "$account" -s "$service" -w 2>/dev/null)"
    rc=$?
    if [ "$rc" -eq 0 ]; then
        printf '%s' "$out"
    fi
    [ "$rc" -eq 0 ] && return "$SPAWN_SECRET_OK"
    return "$SPAWN_SECRET_FAIL"
}

# ---------------------------------------------------------------------------
# spawn::keychain_exists <service> <account>
# Yes/no, without the value ever being produced. Deliberately omits `-w`: the
# attribute dump carries the account and service names and no password, so a
# caller asking "is it configured?" never has the secret in a variable it might
# print. Exit 44 from the real binary is "no such item"; any non-zero is treated
# as absent, since a store that cannot answer is not one we can read from.
# ---------------------------------------------------------------------------
spawn::keychain_exists() {
    local service="$1" account="$2"
    "$SPAWN_SECURITY_BIN" find-generic-password -a "$account" -s "$service" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# spawn::keychain_write <service> <account> <secret>
# Stores the secret and PROVES it landed. Returns 0 only after a read-back byte
# compare, because the bare-`-w` write exits 0 having stored an empty password
# whenever stdin came up short (KTD10, verified).
#
# The trailing bare `-w` is the LAST argument on purpose: anything after it is
# consumed as the password value. `-U` is present because an add over an
# existing item fails 45 without it. `-T`/`-A` are absent so the default ACL
# applies and reads never prompt.
#
# An empty secret is refused up front rather than stored: storing one produces
# exactly the state a failed write leaves behind, and the two would then be
# indistinguishable on the next read.
# ---------------------------------------------------------------------------
spawn::keychain_write() {
    local -
    set +x
    local service="$1" account="$2" secret="$3" rc back rc_back

    [ -n "$secret" ] || return "$SPAWN_SECRET_EMPTY"

    local -
    set +x
    # Builtin printf, twice, newline-terminated. No external command, so the
    # value never reaches an argv anywhere in this pipeline.
    printf '%s\n%s\n' "$secret" "$secret" \
        | "$SPAWN_SECURITY_BIN" add-generic-password -a "$account" -s "$service" -U -w >/dev/null 2>&1
    rc=$?

    if [ "$rc" -eq 0 ]; then
        back="$("$SPAWN_SECURITY_BIN" find-generic-password -a "$account" -s "$service" -w 2>/dev/null)"
        rc_back=$?
        if [ "$rc_back" -ne 0 ] || [ "$back" != "$secret" ]; then
            rc=1
        fi
    else
        rc=1
    fi
    back=""

    [ "$rc" -eq 0 ] && return "$SPAWN_SECRET_OK"
    return "$SPAWN_SECRET_FAIL"
}

# ---------------------------------------------------------------------------
# spawn::keychain_delete <service> <account>
# Removes every matching item. The real binary deletes ONE match per call and
# duplicates are possible (the same service/account pair can be added more than
# once by anything that did not pass -U), so this loops until it is told 44 —
# "no such item" — which is the only answer that means the store is clean.
#
# The loop is bounded. An unbounded one turns a store that keeps answering 0
# without deleting anything into a hang, and a hang inside setup is worse than a
# named failure.
# ---------------------------------------------------------------------------
spawn::keychain_delete() {
    local service="$1" account="$2" i rc
    for ((i = 0; i < 32; i++)); do
        "$SPAWN_SECURITY_BIN" delete-generic-password -a "$account" -s "$service" >/dev/null 2>&1
        rc=$?
        [ "$rc" -eq 44 ] && return "$SPAWN_SECRET_OK"
        [ "$rc" -ne 0 ] && return "$SPAWN_SECRET_FAIL"
    done
    return "$SPAWN_SECRET_FAIL"
}

# ---------------------------------------------------------------------------
# spawn::prompt_secret <title> <prompt>
# Puts up the macOS password dialog and prints the typed value on stdout
# (KTD2). The value travels dialog -> shell variable -> Keychain, touching no
# argv and no file.
#
# The prompt and title go in as AppleScript ARGUMENTS rather than being
# interpolated into the script text: interpolation would let a quote in either
# one rewrite the script, and the values are not secret so argv is the right
# place for them.
#
# Cancel and a scripting failure both exit 1, so stderr is captured SEPARATELY
# (never merged into the stdout capture, which would corrupt the returned value)
# and read for the -128 code that means the operator pressed Cancel. That file
# holds no answer on any failing path, so it is never secret-bearing; it is
# removed either way.
#
# Returns: 0 with the value on stdout · 3 cancelled · 2 empty answer ·
#          1 any other dialog failure. Nothing is printed to stderr, ever —
#          the caller owns diagnostics and must not echo the value.
# ---------------------------------------------------------------------------
spawn::prompt_secret() {
    local -
    set +x
    local title="$1" prompt="$2" errfile answer rc ret

    errfile="$(umask 077; mktemp "${TMPDIR:-/tmp}/gwdlg.XXXXXX")" || return "$SPAWN_SECRET_FAIL"

    local -
    set +x
    answer="$("$SPAWN_OSASCRIPT_BIN" \
        -e 'on run argv' \
        -e 'set d to display dialog (item 1 of argv) with title (item 2 of argv) default answer "" with hidden answer buttons {"Cancel", "OK"} default button "OK"' \
        -e 'return text returned of d' \
        -e 'end run' \
        -- "$prompt" "$title" 2>"$errfile")"
    rc=$?

    if [ "$rc" -ne 0 ]; then
        if grep -q -- '-128' "$errfile" 2>/dev/null; then
            ret="$SPAWN_SECRET_CANCELLED"
        else
            ret="$SPAWN_SECRET_FAIL"
        fi
    elif [ -z "$answer" ]; then
        ret="$SPAWN_SECRET_EMPTY"
    else
        printf '%s' "$answer"
        ret="$SPAWN_SECRET_OK"
    fi
    answer=""
    rm -f "$errfile" 2>/dev/null
    return "$ret"
}

# ---------------------------------------------------------------------------
# spawn::generate_token [length]
# Prints a fresh gateway token (KD4: setup generates it, so no human ever types,
# pastes, or records a token value).
#
# Random bytes are filtered to [A-Za-z0-9], which keeps 62 of 256 byte values —
# about 24% — so the draw is oversampled 8x rather than 4x: at 4x the expected
# yield is BELOW the requested length and the function would fail more often
# than it succeeded. The result is length-checked rather than assumed, because a
# short read from /dev/urandom would otherwise mint a weak token silently.
#
# `head -c` bounds the read at the SOURCE instead of closing the pipe on `tr`.
# The pipe-closing form raises SIGPIPE, which `set -o pipefail` in every calling
# script turns into a non-zero status for a pipeline that actually worked.
# ---------------------------------------------------------------------------
spawn::generate_token() {
    local len="${1:-$SPAWN_TOKEN_LEN}" raw
    case "$len" in
        ''|*[!0-9]*) return "$SPAWN_SECRET_FAIL" ;;
    esac
    [ "$len" -gt 0 ] || return "$SPAWN_SECRET_FAIL"

    raw="$(head -c "$((len * 8))" /dev/urandom 2>/dev/null | LC_ALL=C tr -dc 'A-Za-z0-9')"
    [ "${#raw}" -ge "$len" ] || return "$SPAWN_SECRET_FAIL"
    printf '%s' "${raw:0:len}"
}

# ---------------------------------------------------------------------------
# spawn::token_fallback <service> <account>
# The gateway-token fallback chain, shared by every surface that authenticates
# against the gateway: env GATEWAY_TOKEN, then the Keychain. Sets
# SPAWN_TOKEN_VALUE and SPAWN_TOKEN_SOURCE; returns 1 having set neither when
# no token is stored.
#
# WHY THIS IS SHARED WHEN THE PARSERS ARE NOT
# -------------------------------------------
# common.sh deliberately keeps the three `server.token` awk parsers duplicated.
# This is the other half of the resolution and it must NOT be: R27 added the
# Keychain step to spawnctl's probe and left lens.sh and launch.sh reading the
# config alone, so once setup retired the config token the probe authenticated
# and the lens 401'd. lens.sh:615 had already written down why that is the
# worst possible split ("undebuggable from the outside") — it just could not
# enforce it. One chain, one place, is the enforcement.
#
# It ASSIGNS rather than prints: a `$(...)` caller would run this in a subshell
# and silently drop SPAWN_TOKEN_SOURCE, which is exactly the kind of quiet
# half-working result this branch exists to stop shipping. Assigning also keeps
# the value out of one more process's memory.
#
# keychain_exists runs first because it never produces the value, so a machine
# with no stored credential never performs a read at all.
# ---------------------------------------------------------------------------
spawn::token_fallback() {
    local -
    set +x
    local service="$1" account="$2" tok
    if [ -n "${GATEWAY_TOKEN:-}" ]; then
        SPAWN_TOKEN_VALUE="$GATEWAY_TOKEN"
        SPAWN_TOKEN_SOURCE="env"
        return 0
    fi
    if spawn::keychain_exists "$service" "$account"; then
        tok="$(spawn::keychain_read "$service" "$account")"
        if [ -n "$tok" ]; then
            SPAWN_TOKEN_VALUE="$tok"
            SPAWN_TOKEN_SOURCE="keychain"
            tok=""
            return 0
        fi
    fi
    return 1
}

# ---------------------------------------------------------------------------
# spawn::resolve_token — the LAST MILE of token resolution, shared.
#
# Sets TOKEN in the caller's scope when the env/Keychain chain yields one, and
# leaves it untouched when it does not (a config-derived token the caller
# already found must win over nothing).
#
# WHY IT IS HERE AND NOT COPY-PASTED. It was copy-pasted: lens.sh and launch.sh
# each carried a byte-identical `resolve_token_from_fallback`, differing only in
# their comments — in the two files that both already source THIS one, directly
# below the header that states the rule for exactly this case ("One chain, one
# place, is the enforcement"). The chain was shared and its last mile was not.
#
# The `local -` wrapper is the load-bearing part, not ceremony: this assigns a
# CREDENTIAL, and at top level there is no scope to confine `set +x` to, so a
# caller running the script under `bash -x` would trace the token out. `local -`
# restores the caller's own xtrace setting on return. Two copies of that guard
# meant the next hardening of it would land in one surface.
#   spawn::resolve_token <service> <account>
spawn::resolve_token() {
    local -
    set +x
    SPAWN_TOKEN_VALUE=""
    if spawn::token_fallback "$1" "$2"; then
        TOKEN="$SPAWN_TOKEN_VALUE"
    fi
    SPAWN_TOKEN_VALUE=""
}
