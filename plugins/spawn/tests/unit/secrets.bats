#!/usr/bin/env bats
# U1 — the Keychain and dialog primitives.
#
# Everything here runs against fixtures. The real Keychain is out of the test
# path by decision: a suite that wrote to this machine's login keychain would
# either raise an unlock prompt (turning a headless run into a hang) or leave
# real items behind, and both of those are how a green suite stops meaning
# anything. The two seams — SPAWN_SECURITY_BIN and SPAWN_OSASCRIPT_BIN — are how
# the whole path redirects (KTD8, the SPAWN_CLAUDE_BIN precedent).
#
# The load-bearing assertion in this file is the argv one. KTD10's claim is that
# a secret never appears in a process argument, and the ONLY thing standing
# between that claim and a comfortable fiction is the fixture's append-only argv
# record plus the two plants at the end of this file, which are seen going red.

# `run --separate-stderr` is a 1.5.0 flag, and the "nothing on stderr" assertion
# is the whole point of the dialog test — without the split, a leaked
# diagnostic would land in $output and read as a passing value.
bats_require_minimum_version 1.5.0

setup() {
    FIX="$(cd "$BATS_TEST_DIRNAME/../fixtures" && pwd)"
    LIB="$(cd "$BATS_TEST_DIRNAME/../../lib" && pwd)"
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/gw-sec.XXXXXX")"
    WORK="$(cd "$WORK" && pwd -P)"

    export SPAWN_SECURITY_BIN="$FIX/fake-security.sh"
    export SPAWN_OSASCRIPT_BIN="$FIX/fake-osascript.sh"
    # Store and records live under this test's own dir, so no two tests (and no
    # two concurrent runs of the harness) share fixture state.
    export FAKE_SECURITY_STORE_DIR="$WORK/store"
    export FAKE_SECURITY_RECORD_DIR="$WORK/rec"
    export FAKE_OSASCRIPT_RECORD_DIR="$WORK/rec-osa"
    export FAKE_SECURITY_MODE=ok
    export FAKE_OSASCRIPT_MODE=ok

    SERVICE="spawn-test-service"
    ACCOUNT="spawn-test-account"

    # A deliberately hostile value: command substitution, backticks, a command
    # separator, quotes and spaces. It is short and carries no credential-shaped
    # prefix on purpose — the repo-wide secret scan in run-tests.sh reads this
    # file too.
    HOSTILE='p@ss $(whoami) `id` ; rm -rf / "quoted" '"'"'single'"'"' end'

    # shellcheck source=../../lib/secrets.sh
    . "$LIB/secrets.sh"
}

teardown() {
    [ -n "${WORK:-}" ] && rm -rf "$WORK"
    return 0
}

# Every recorded argv line from every subcommand, as one blob.
argv_record() { cat "$WORK/rec/argv" 2>/dev/null; }

# ---------------------------------------------------------------------------
# The write path
# ---------------------------------------------------------------------------

@test "a hostile secret round-trips byte-exact and no fragment of it reaches argv" {
    run spawn::keychain_write "$SERVICE" "$ACCOUNT" "$HOSTILE"
    [ "$status" -eq 0 ]

    run spawn::keychain_read "$SERVICE" "$ACCOUNT"
    [ "$status" -eq 0 ]
    [ "$output" = "$HOSTILE" ]

    # Not "the whole string is absent" — a fragment is the realistic leak shape,
    # and the whole-string form passes over a value the store mangled.
    record="$(argv_record)"
    [ -n "$record" ]
    ! grep -q 'whoami' <<<"$record"
    ! grep -q 'quoted' <<<"$record"
    ! grep -qF 'p@ss' <<<"$record"
}

@test "the write is fed on stdin to a TRAILING bare -w, with -U and without -T/-A/-g" {
    spawn::keychain_write "$SERVICE" "$ACCOUNT" "value-one"

    # The add invocation's argument list, in order.
    add_args="$(awk '/^--- invocation ---$/{n++} n==1' "$WORK/rec/argv" | tail -n +2)"
    [ "$(printf '%s\n' "$add_args" | head -n 1)" = "add-generic-password" ]
    # -w is LAST. Anything after it is swallowed as the password value, which is
    # how a positional argument disappears silently.
    [ "$(printf '%s\n' "$add_args" | tail -n 1)" = "-w" ]
    printf '%s\n' "$add_args" | grep -qx -- '-U'
    ! printf '%s\n' "$add_args" | grep -qx -- '-T'
    ! printf '%s\n' "$add_args" | grep -qx -- '-A'
    ! printf '%s\n' "$add_args" | grep -qx -- '-g'
    # ...and the value is nowhere in it.
    ! printf '%s\n' "$add_args" | grep -q 'value-one'
}

@test "silent-empty: the store takes an empty password and exits 0; the write reports FAILURE" {
    export FAKE_SECURITY_MODE=silent_empty

    run spawn::keychain_write "$SERVICE" "$ACCOUNT" "should-not-survive"
    [ "$status" -ne 0 ]

    # The store really did accept it and report success — the read-back compare
    # is the only thing that noticed.
    run "$SPAWN_SECURITY_BIN" add-generic-password -a "$ACCOUNT" -s "$SERVICE" -U -w <<<"one-line-only"
    [ "$status" -eq 0 ]
    run "$SPAWN_SECURITY_BIN" find-generic-password -a "$ACCOUNT" -s "$SERVICE" -w
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "a single-fed bare -w stores empty and exits 0 — the trap the double feed exists for" {
    # Straight at the fixture, no library: this pins the behaviour the write
    # path is shaped around, so a fixture that ever smoothed it over goes red
    # here rather than making the library's care look unnecessary.
    export FAKE_SECURITY_MODE=ok
    run bash -c 'printf "%s\n" "just-once" | "$SPAWN_SECURITY_BIN" add-generic-password -a "$1" -s "$2" -U -w' _ "$ACCOUNT" "$SERVICE"
    [ "$status" -eq 0 ]
    run "$SPAWN_SECURITY_BIN" find-generic-password -a "$ACCOUNT" -s "$SERVICE" -w
    [ -z "$output" ]
}

@test "an empty secret is refused rather than stored" {
    run spawn::keychain_write "$SERVICE" "$ACCOUNT" ""
    [ "$status" -eq 2 ]
    run spawn::keychain_exists "$SERVICE" "$ACCOUNT"
    [ "$status" -ne 0 ]
}

@test "a read of a missing item fails and prints nothing" {
    run spawn::keychain_read "$SERVICE" "no-such-account"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# The existence probe
# ---------------------------------------------------------------------------

@test "the existence probe answers yes/no without the value ever being produced" {
    run spawn::keychain_exists "$SERVICE" "$ACCOUNT"
    [ "$status" -ne 0 ]

    spawn::keychain_write "$SERVICE" "$ACCOUNT" "$HOSTILE"

    run spawn::keychain_exists "$SERVICE" "$ACCOUNT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    # The probe's own invocation — the LAST one recorded — carries no -w, so the
    # fixture had nothing to print even if the caller had captured it.
    probe_args="$(awk '/^--- invocation ---$/{n = NR} END { for (i = n + 1; i <= NR; i++) print rec[i] } { rec[NR] = $0 }' "$WORK/rec/argv")"
    [ "$(printf '%s\n' "$probe_args" | head -n 1)" = "find-generic-password" ]
    ! printf '%s\n' "$probe_args" | grep -qx -- '-w'
}

# ---------------------------------------------------------------------------
# The delete loop
# ---------------------------------------------------------------------------

@test "delete removes duplicate items and stops at not-found" {
    # Duplicates are possible in the real store, so the fixture's duplicate mode
    # adds a new item instead of updating. The value is the same each time
    # because the write path's read-back compare reads the FIRST match — which
    # is exactly why duplicates are dangerous and have to be deleted, not
    # overwritten.
    export FAKE_SECURITY_MODE=duplicate
    spawn::keychain_write "$SERVICE" "$ACCOUNT" "dup-value"
    spawn::keychain_write "$SERVICE" "$ACCOUNT" "dup-value"
    spawn::keychain_write "$SERVICE" "$ACCOUNT" "dup-value"
    [ "$(find "$WORK/store" -type f | wc -l | tr -d ' ')" -eq 3 ]

    run spawn::keychain_delete "$SERVICE" "$ACCOUNT"
    [ "$status" -eq 0 ]
    [ "$(find "$WORK/store" -type f | wc -l | tr -d ' ')" -eq 0 ]

    # ...and deleting nothing is still success: the post-condition is "clean".
    run spawn::keychain_delete "$SERVICE" "$ACCOUNT"
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# The dialog
# ---------------------------------------------------------------------------

@test "the dialog yields its value on stdout, asks for a HIDDEN answer, and says nothing on stderr" {
    export FAKE_OSASCRIPT_ANSWER='dialog-value $(whoami) end'

    run --separate-stderr spawn::prompt_secret "Gateway setup" "Paste the provider key"
    [ "$status" -eq 0 ]
    [ "$output" = 'dialog-value $(whoami) end' ]
    [ -z "$stderr" ]

    grep -q 'with hidden answer' "$WORK/rec-osa/argv"
    # The prompt and title go in as arguments; nothing else does.
    grep -qx 'Paste the provider key' "$WORK/rec-osa/argv"
    grep -qx 'Gateway setup' "$WORK/rec-osa/argv"
}

@test "Cancel fails distinctly from a dialog error, and neither prints a value" {
    export FAKE_OSASCRIPT_MODE=cancel
    run --separate-stderr spawn::prompt_secret "t" "p"
    [ "$status" -eq 3 ]
    [ -z "$output" ]
    [ -z "$stderr" ]

    export FAKE_OSASCRIPT_MODE=error
    run --separate-stderr spawn::prompt_secret "t" "p"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [ -z "$stderr" ]

    export FAKE_OSASCRIPT_MODE=empty
    run spawn::prompt_secret "t" "p"
    [ "$status" -eq 2 ]
    [ -z "$output" ]
}

@test "a dialog value writes through to the Keychain without touching argv" {
    export FAKE_OSASCRIPT_ANSWER='handed-over-secret'
    key="$(spawn::prompt_secret "t" "p")"
    spawn::keychain_write "$SERVICE" "$ACCOUNT" "$key"

    run spawn::keychain_read "$SERVICE" "$ACCOUNT"
    [ "$output" = 'handed-over-secret' ]
    ! grep -q 'handed-over-secret' "$WORK/rec/argv"
    ! grep -q 'handed-over-secret' "$WORK/rec-osa/argv"
}

# ---------------------------------------------------------------------------
# Token generation
# ---------------------------------------------------------------------------

@test "generated tokens differ, match the declared length and charset, and reach no argv" {
    a="$(spawn::generate_token)"
    b="$(spawn::generate_token)"
    [ -n "$a" ]
    [ "$a" != "$b" ]
    [ "${#a}" -eq 43 ]
    [ "${#b}" -eq 43 ]
    [[ "$a" =~ ^[A-Za-z0-9]+$ ]]
    [[ "$b" =~ ^[A-Za-z0-9]+$ ]]

    c="$(spawn::generate_token 16)"
    [ "${#c}" -eq 16 ]

    spawn::keychain_write "$SERVICE" "gateway-token" "$a"
    run spawn::keychain_read "$SERVICE" "gateway-token"
    [ "$output" = "$a" ]
    ! grep -qF "$a" "$WORK/rec/argv"

    # A malformed length is a failure, not a silently short token.
    run spawn::generate_token "abc"
    [ "$status" -ne 0 ]
    run spawn::generate_token 0
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Source-level guards
# ---------------------------------------------------------------------------

@test "secrets.sh never uses find-generic-password -g, and never exits" {
    ! grep -q 'find-generic-password.*-g\b' "$LIB/secrets.sh"
    # A sourced library that calls exit kills its caller mid-setup.
    ! grep -qE '^[[:space:]]*exit[[:space:]]' "$LIB/secrets.sh"
    # The shell BUILTIN printf on the secret-bearing pipe: an external
    # /usr/bin/printf would put the value straight into the process table.
    # Comments are stripped first — this file explains the trap by name.
    ! sed 's/#.*$//' "$LIB/secrets.sh" | grep -q '/usr/bin/printf'
}

@test "secrets.sh prints nothing to stderr on any path (the pure-helper shape)" {
    ! grep -qE '>&2|/dev/stderr|/dev/tty' "$LIB/secrets.sh"
}

# ---------------------------------------------------------------------------
# G3 — the detector, seen failing. Twice, for two different reasons.
# ---------------------------------------------------------------------------

@test "self-test A: the argv assertion goes RED when the fixture leaks the secret into its record" {
    # Baseline first, so the red below is attributable to the plant rather than
    # to the assertion never having been green.
    spawn::keychain_write "$SERVICE" "$ACCOUNT" "$HOSTILE"
    run grep -q 'whoami' "$WORK/rec/argv"
    [ "$status" -ne 0 ]

    export FAKE_SECURITY_MODE=leak_argv
    spawn::keychain_write "$SERVICE" "$ACCOUNT" "$HOSTILE"
    run grep -q 'whoami' "$WORK/rec/argv"
    [ "$status" -eq 0 ]
}

@test "self-test B: the argv assertion goes RED against a MUTATED secrets.sh that passes -w <value>" {
    # A fixture flag proves the assertion reads the record. Only mutating the
    # CODE proves it catches the real defect shape — the argv form of the write
    # this library exists to avoid.
    mkdir -p "$WORK/mutant"
    sed -e 's|printf .%s\\n%s\\n. "\$secret" "\$secret" \\|printf "" \\|' \
        -e 's|-U -w >/dev/null 2>\&1|-U -w "$secret" >/dev/null 2>\&1|' \
        "$LIB/secrets.sh" > "$WORK/mutant/secrets.sh"
    # The mutation must have actually applied — a sed that matched nothing would
    # make this whole test a green no-op.
    grep -q -- '-U -w "$secret"' "$WORK/mutant/secrets.sh"

    (
        . "$WORK/mutant/secrets.sh"
        spawn::keychain_write "$SERVICE" "$ACCOUNT" "mutant-secret-value"
    )
    # The write still "succeeds" — read-back passes, because the value did land.
    # What changed is that it landed via argv, and the record says so.
    run grep -q 'mutant-secret-value' "$WORK/rec/argv"
    [ "$status" -eq 0 ]
}
