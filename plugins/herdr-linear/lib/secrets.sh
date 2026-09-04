#!/usr/bin/env bash
# secrets.sh — this plugin's only toucher of the Keychain and the password
# dialog. The credential it holds is a personal Linear API key (R27, KTD1).
#
# WHY THIS EXISTS
# Every function below is a one-line shell command with a trap in it. Written
# inline at each call site, each trap would have to be re-avoided every time,
# which is how one caller ends up with the careful form and the next with the
# obvious one. So `security` and `osascript` are touched HERE and nowhere else,
# and the traps are closed once.
#
# It is VENDORED, not sourced from plugins/spawn (KTD8): no plugin in this repo
# sources another's library, `${CLAUDE_PLUGIN_ROOT}` resolves only the current
# plugin, and this plugin's own runner must work from a checkout with no other
# plugin present.
#
# THE TRAPS, ALL VERIFIED AGAINST THE REAL BINARIES
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
# WHAT THIS BUYS, AND WHAT IT DOES NOT
# The default ACL authenticates the READER BINARY (/usr/bin/security), not the
# calling process, so any same-user process can read these items silently —
# roughly a mode-0600 file as far as same-user agents are concerned. The real
# wins are encryption at rest, protection while the keychain is locked,
# cross-user isolation, and staying out of dotfile backups. Closing the
# same-user hole needs a code-signed reader binary plus a partition list, and is
# deliberately out of scope. The improvement over the plaintext ~/.secrets this
# replaces is real but smaller than R27's wording suggests, so it is documented
# here rather than implied.
#
# SHAPE
# This file is SOURCED, so it never calls `exit` — that would kill the caller —
# and it reads every optional environment variable with `${VAR:-}` because its
# callers run under `set -u`. It prints NOTHING to stderr and holds no
# diagnostics, which is why it does not source sanitize.sh: it has no terminal
# sink to defend. Callers own their own diagnostics, and must not print a
# returned value.
#
# RETURN CODES are local to this file and named below; they are not the plugin's
# exit-code enum, and no caller should pass one through as a process exit code
# without mapping it.

# Seams (KTD8). Same shape as HERDR_LINEAR_SLATE_ROOT in contain.sh: every
# external entry point is env-overridable so a test can point the whole path at
# a fixture. A test that touched the real Keychain would either prompt for an
# unlock or write a real Linear key to this machine's login keychain, and both
# of those are how a "passing" suite stops meaning anything.
HERDR_LINEAR_SECURITY_BIN="${HERDR_LINEAR_SECURITY_BIN:-/usr/bin/security}"
HERDR_LINEAR_OSASCRIPT_BIN="${HERDR_LINEAR_OSASCRIPT_BIN:-/usr/bin/osascript}"

# Return codes.
HERDR_LINEAR_SECRET_OK=0
HERDR_LINEAR_SECRET_FAIL=1       # the store or the dialog failed
HERDR_LINEAR_SECRET_EMPTY=2      # refused: an empty value is not a secret
HERDR_LINEAR_SECRET_CANCELLED=3  # the operator pressed Cancel
HERDR_LINEAR_SECRET_MALFORMED=4  # refused: the value cannot survive the write

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
#     xt="$(herdr_linear::xtrace_off)"      # WRONG
#
# does nothing at all: command substitution forks a subshell, so the `set +x`
# applies to that subshell and dies with it while the caller keeps tracing.
# That shape shipped in the library this one is vendored from and traced the
# secret five times over.

# herdr_linear::keychain_read <service> <account>
# Prints the stored password on stdout. Returns 1 when there is no such item.
#
# `-w` prints ONLY the password, with a trailing newline that the caller's
# command substitution strips. `-g` would print it to stderr, where it would
# land in a log or a transcript; it is never used here, and secrets.bats asserts
# that against this source.
herdr_linear::keychain_read() {
    local -
    set +x
    local service="$1" account="$2" out rc
    out="$("$HERDR_LINEAR_SECURITY_BIN" find-generic-password -a "$account" -s "$service" -w 2>/dev/null)"
    rc=$?
    if [ "$rc" -eq 0 ]; then
        printf '%s' "$out"
    fi
    [ "$rc" -eq 0 ] && return "$HERDR_LINEAR_SECRET_OK"
    return "$HERDR_LINEAR_SECRET_FAIL"
}

# herdr_linear::keychain_exists <service> <account>
# Yes/no, without the value ever being produced. Deliberately omits `-w`: the
# attribute dump carries the account and service names and no password, so a
# caller asking "is it configured?" never has the secret in a variable it might
# print. Exit 44 from the real binary is "no such item"; any non-zero is treated
# as absent, since a store that cannot answer is not one we can read from.
herdr_linear::keychain_exists() {
    local service="$1" account="$2"
    "$HERDR_LINEAR_SECURITY_BIN" find-generic-password -a "$account" -s "$service" >/dev/null 2>&1
}

# herdr_linear::keychain_write <service> <account> <secret>
# Stores the secret and PROVES it landed. Returns 0 only after a read-back byte
# compare, because the bare-`-w` write exits 0 having stored an empty password
# whenever stdin came up short.
#
# The trailing bare `-w` is the LAST argument on purpose: anything after it is
# consumed as the password value. `-U` is present because an add over an
# existing item fails 45 without it. `-T`/`-A` are absent so the default ACL
# applies and reads never prompt.
#
# An empty secret is refused up front rather than stored: storing one produces
# exactly the state a failed write leaves behind, and the two would then be
# indistinguishable on the next read.
herdr_linear::keychain_write() {
    local -
    set +x
    local service="$1" account="$2" secret="$3" rc back rc_back

    [ -n "$secret" ] || return "$HERDR_LINEAR_SECRET_EMPTY"

    # A newline cannot survive this write. The value and its confirmation go in
    # as two printf lines, so an embedded newline makes four, the confirmation
    # mismatches, and the store keeps an EMPTY item having exited 0 — after
    # which keychain_exists reports the credential as configured. The read-back
    # compare below still catches it, but only after the store has been dirtied.
    # Refusing here is what leaves a rejected paste with the store untouched.
    case "$secret" in
        *$'\n'*) return "$HERDR_LINEAR_SECRET_MALFORMED" ;;
    esac

    # Builtin printf, twice, newline-terminated. No external command, so the
    # value never reaches an argv anywhere in this pipeline.
    printf '%s\n%s\n' "$secret" "$secret" \
        | "$HERDR_LINEAR_SECURITY_BIN" add-generic-password -a "$account" -s "$service" -U -w >/dev/null 2>&1
    rc=$?

    if [ "$rc" -eq 0 ]; then
        back="$("$HERDR_LINEAR_SECURITY_BIN" find-generic-password -a "$account" -s "$service" -w 2>/dev/null)"
        rc_back=$?
        if [ "$rc_back" -ne 0 ] || [ "$back" != "$secret" ]; then
            rc=1
        fi
    else
        rc=1
    fi
    back=""

    [ "$rc" -eq 0 ] && return "$HERDR_LINEAR_SECRET_OK"
    return "$HERDR_LINEAR_SECRET_FAIL"
}

# herdr_linear::keychain_delete <service> <account>
# Removes every matching item. The real binary deletes ONE match per call and
# duplicates are possible (the same service/account pair can be added more than
# once by anything that did not pass -U), so this loops until it is told 44 —
# "no such item" — which is the only answer that means the store is clean.
#
# The loop is bounded. An unbounded one turns a store that keeps answering 0
# without deleting anything into a hang, and a hang inside setup is worse than a
# named failure.
herdr_linear::keychain_delete() {
    local service="$1" account="$2" i rc
    for ((i = 0; i < 32; i++)); do
        "$HERDR_LINEAR_SECURITY_BIN" delete-generic-password -a "$account" -s "$service" >/dev/null 2>&1
        rc=$?
        [ "$rc" -eq 44 ] && return "$HERDR_LINEAR_SECRET_OK"
        [ "$rc" -ne 0 ] && return "$HERDR_LINEAR_SECRET_FAIL"
    done
    return "$HERDR_LINEAR_SECRET_FAIL"
}

# herdr_linear::prompt_secret <title> <prompt>
# Puts up the macOS password dialog and prints the typed value on stdout. The
# value travels dialog -> shell variable -> Keychain, touching no argv and no
# file, which is what lets R27 hold for a key the operator pastes.
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
herdr_linear::prompt_secret() {
    local -
    set +x
    local title="$1" prompt="$2" errfile answer rc ret

    errfile="$(umask 077; mktemp "${TMPDIR:-/tmp}/hldlg.XXXXXX")" || return "$HERDR_LINEAR_SECRET_FAIL"

    answer="$("$HERDR_LINEAR_OSASCRIPT_BIN" \
        -e 'on run argv' \
        -e 'set d to display dialog (item 1 of argv) with title (item 2 of argv) default answer "" with hidden answer buttons {"Cancel", "OK"} default button "OK"' \
        -e 'return text returned of d' \
        -e 'end run' \
        -- "$prompt" "$title" 2>"$errfile")"
    rc=$?

    if [ "$rc" -ne 0 ]; then
        if grep -q -- '-128' "$errfile" 2>/dev/null; then
            ret="$HERDR_LINEAR_SECRET_CANCELLED"
        else
            ret="$HERDR_LINEAR_SECRET_FAIL"
        fi
    elif [ -z "$answer" ]; then
        ret="$HERDR_LINEAR_SECRET_EMPTY"
    else
        printf '%s' "$answer"
        ret="$HERDR_LINEAR_SECRET_OK"
    fi
    answer=""
    rm -f "$errfile" 2>/dev/null
    return "$ret"
}
