#!/usr/bin/env bats
# U3 — the vendored Keychain, dialog and sanitiser primitives.
#
# Everything here runs against fixtures. The real Keychain is out of the test
# path by decision: a suite that wrote to this machine's login keychain would
# either raise an unlock prompt (turning a headless run into a hang) or leave a
# real Linear key behind, and both of those are how a green suite stops meaning
# anything. The two seams — HERDR_LINEAR_SECURITY_BIN and
# HERDR_LINEAR_OSASCRIPT_BIN — are how the whole path redirects.
#
# The load-bearing assertion in this file is the argv one. R27's claim is that
# the credential never appears in a process argument, and the ONLY thing between
# that claim and a comfortable fiction is the fixture's append-only argv record
# plus the two plants at the end of this file, which are seen going red.

# `run --separate-stderr` is a 1.5.0 flag, and the "nothing on stderr"
# assertion is the whole point of the dialog and xtrace tests — without the
# split, a leaked diagnostic would land in $output and read as a passing value.
bats_require_minimum_version 1.5.0

# A `!`-negated command is exempt from errexit under POSIX, and bats scores a
# test by errexit or the final command's status -- so `! grep -q X` anywhere but
# the last line detects the defect and lets the test pass anyway. Every absence
# assertion goes through this instead: it returns non-zero on a match, which is
# a plain command failure and does fail the test wherever it sits.
refute_match() {   # refute_match <grep-args...> -- fails when grep MATCHES
    if grep "$@"; then
        printf 'refute_match: unexpectedly matched: %s\n' "$*" >&2
        return 1
    fi
    return 0
}

setup() {
    LIB="$(cd "$BATS_TEST_DIRNAME/../../lib" && pwd)"
    FIX="$(cd "$BATS_TEST_DIRNAME/../fixtures" && pwd)"
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/hl-sec.XXXXXX")"
    # /tmp is a symlink on macOS, so the raw mktemp path and the path a
    # subprocess reports back differ; resolve once here.
    WORK="$(cd "$WORK" && pwd -P)"

    export HERDR_LINEAR_SECURITY_BIN="$FIX/fake-security.sh"
    # The dialog stub is written per-run rather than committed: U3 owns one
    # fixture file, and a dialog stand-in that only this file uses has no reason
    # to be a shared artifact.
    export HERDR_LINEAR_OSASCRIPT_BIN="$WORK/fake-osascript.sh"
    cat > "$HERDR_LINEAR_OSASCRIPT_BIN" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
REC="${FAKE_OSASCRIPT_RECORD_DIR:?}"
mkdir -p "$REC"
for a in "$@"; do printf '%s\n' "$a"; done >> "$REC/argv"
case "${FAKE_OSASCRIPT_MODE:-ok}" in
  # osascript reports a user Cancel as error -128 on stderr, exiting 1 — the
  # same exit status as a scripting failure, which is why the caller has to
  # read stderr to tell the two apart.
  cancel) printf '%s\n' "execution error: User canceled. (-128)" >&2; exit 1 ;;
  error)  printf '%s\n' "execution error: something else (-1728)" >&2; exit 1 ;;
  empty)  printf '\n'; exit 0 ;;
  *)      printf '%s\n' "${FAKE_OSASCRIPT_ANSWER:-default-answer}"; exit 0 ;;
esac
STUB
    chmod +x "$HERDR_LINEAR_OSASCRIPT_BIN"

    # Store and records live under this test's own dir, so no two tests (and no
    # two concurrent runs of the harness) share fixture state.
    export FAKE_SECURITY_STORE_DIR="$WORK/store"
    export FAKE_SECURITY_RECORD_DIR="$WORK/rec"
    export FAKE_OSASCRIPT_RECORD_DIR="$WORK/rec-osa"
    export FAKE_SECURITY_MODE=ok
    export FAKE_OSASCRIPT_MODE=ok

    SERVICE="herdr-linear-test-service"
    ACCOUNT="herdr-linear-test-account"

    # A deliberately hostile value: command substitution, backticks, a command
    # separator, quotes and spaces. It is short and carries no credential-shaped
    # prefix on purpose — the repo-wide secret scan in run-tests.sh reads this
    # file too, and a `lin_api_`-shaped literal here would fail it.
    # ...plus a tab, a C0 control and DEL, because "byte-exact" is only worth
    # asserting over bytes a naive pipeline would eat. NUL is absent because a
    # bash variable cannot hold one, and a NEWLINE is absent because the write
    # path refuses one outright — see its own test below.
    HOSTILE='p@ss $(whoami) `id` ; rm -rf / "quoted" '"'"'single'"'"' end'$'\t\x01\x7f'

    # shellcheck source=../../lib/secrets.sh
    . "$LIB/secrets.sh"
    # shellcheck source=../../lib/sanitize.sh
    . "$LIB/sanitize.sh"
}

teardown() {
    [ -n "${WORK:-}" ] && rm -rf "$WORK"
    return 0
}

argv_record() { cat "$WORK/rec/argv" 2>/dev/null; }

# The write path

@test "a hostile secret round-trips byte-exact and no fragment of it reaches argv" {
    run herdr_linear::keychain_write "$SERVICE" "$ACCOUNT" "$HOSTILE"
    [ "$status" -eq 0 ]

    run herdr_linear::keychain_read "$SERVICE" "$ACCOUNT"
    [ "$status" -eq 0 ]
    [ "$output" = "$HOSTILE" ]

    # Not "the whole string is absent" — a fragment is the realistic leak shape,
    # and the whole-string form passes over a value the store mangled.
    record="$(argv_record)"
    [ -n "$record" ]
    refute_match -q 'whoami' <<<"$record"
    refute_match -q 'quoted' <<<"$record"
    refute_match -qF 'p@ss' <<<"$record"
}

@test "the write is fed on stdin to a TRAILING bare -w, with -U and without -T/-A/-g" {
    herdr_linear::keychain_write "$SERVICE" "$ACCOUNT" "value-one"

    add_args="$(awk '/^--- invocation ---$/{n++} n==1' "$WORK/rec/argv" | tail -n +2)"
    [ "$(printf '%s\n' "$add_args" | head -n 1)" = "add-generic-password" ]
    # -w is LAST. Anything after it is swallowed as the password value, which is
    # how a positional argument disappears silently.
    [ "$(printf '%s\n' "$add_args" | tail -n 1)" = "-w" ]
    printf '%s\n' "$add_args" | grep -qx -- '-U'
    refute_match -qx -- '-T' < <(printf '%s\n' "$add_args")
    refute_match -qx -- '-A' < <(printf '%s\n' "$add_args")
    refute_match -qx -- '-g' < <(printf '%s\n' "$add_args")
    refute_match -q 'value-one' < <(printf '%s\n' "$add_args")
}

@test "silent-empty: the store takes an empty password and exits 0; the write reports FAILURE" {
    export FAKE_SECURITY_MODE=silent_empty

    run herdr_linear::keychain_write "$SERVICE" "$ACCOUNT" "should-not-survive"
    [ "$status" -ne 0 ]

    # The store really did accept it and report success — the read-back compare
    # is the only thing that noticed.
    run "$HERDR_LINEAR_SECURITY_BIN" add-generic-password -a "$ACCOUNT" -s "$SERVICE" -U -w <<<"one-line-only"
    [ "$status" -eq 0 ]
    run "$HERDR_LINEAR_SECURITY_BIN" find-generic-password -a "$ACCOUNT" -s "$SERVICE" -w
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "a single-fed bare -w stores empty and exits 0 — the trap the double feed exists for" {
    # Straight at the fixture, no library: this pins the behaviour the write
    # path is shaped around, so a fixture that ever smoothed it over goes red
    # here rather than making the library's care look unnecessary.
    export FAKE_SECURITY_MODE=ok
    run bash -c 'printf "%s\n" "just-once" | "$HERDR_LINEAR_SECURITY_BIN" add-generic-password -a "$1" -s "$2" -U -w' _ "$ACCOUNT" "$SERVICE"
    [ "$status" -eq 0 ]
    run "$HERDR_LINEAR_SECURITY_BIN" find-generic-password -a "$ACCOUNT" -s "$SERVICE" -w
    [ -z "$output" ]
}

@test "an empty secret is refused rather than stored" {
    run herdr_linear::keychain_write "$SERVICE" "$ACCOUNT" ""
    [ "$status" -eq 2 ]
    run herdr_linear::keychain_exists "$SERVICE" "$ACCOUNT"
    [ "$status" -ne 0 ]
}

@test "a newline-bearing secret is refused up front, leaving no item behind" {
    # The write feeds the value and its confirmation as two printf lines, so a
    # newline inside the value splits into four and the confirmation mismatches.
    # The store would then keep an EMPTY item and exit 0, and keychain_exists
    # would afterwards report the credential as configured. Refusing at the door
    # is the only shape where a rejected paste leaves the store as it was.
    run herdr_linear::keychain_write "$SERVICE" "$ACCOUNT" $'one\ntwo'
    [ "$status" -eq 4 ]
    # The store was never invoked at all — checked before the probe below, which
    # is itself an invocation and would create the record.
    [ ! -e "$WORK/rec/argv" ]
    run herdr_linear::keychain_exists "$SERVICE" "$ACCOUNT"
    [ "$status" -ne 0 ]
}

@test "a read of a missing item fails and prints nothing" {
    run herdr_linear::keychain_read "$SERVICE" "no-such-account"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

# The xtrace guard

@test "under set -x the library traces no secret of its own" {
    # The caller's own call line traces its expanded arguments — that occurrence
    # is the harness's, not the library's, and it is why this counts rather than
    # asserting absence. With the `local -; set +x` guard the count is exactly
    # that one line; without it the builtin printf and the read-back compare
    # trace the value too.
    run --separate-stderr bash -x -c '. "$1"; herdr_linear::keychain_write s a "$2"' \
        _ "$LIB/secrets.sh" "$HOSTILE"
    [ "$status" -eq 0 ]
    n="$(printf '%s\n' "$stderr" | grep -cF 'p@ss' || true)"
    [ "$n" -eq 1 ]
}

# The existence probe

@test "the existence probe answers yes/no without the value ever being produced" {
    run herdr_linear::keychain_exists "$SERVICE" "$ACCOUNT"
    [ "$status" -ne 0 ]

    herdr_linear::keychain_write "$SERVICE" "$ACCOUNT" "$HOSTILE"

    run herdr_linear::keychain_exists "$SERVICE" "$ACCOUNT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    # The probe's own invocation — the LAST one recorded — carries no -w, so the
    # fixture had nothing to print even if the caller had captured it.
    probe_args="$(awk '/^--- invocation ---$/{n = NR} END { for (i = n + 1; i <= NR; i++) print rec[i] } { rec[NR] = $0 }' "$WORK/rec/argv")"
    [ "$(printf '%s\n' "$probe_args" | head -n 1)" = "find-generic-password" ]
    refute_match -qx -- '-w' < <(printf '%s\n' "$probe_args")
}

# The delete loop

@test "delete removes duplicate items and stops at not-found" {
    # Duplicates are possible in the real store, so the fixture's duplicate mode
    # adds a new item instead of updating. The value is the same each time
    # because the write path's read-back compare reads the FIRST match — which
    # is exactly why duplicates are dangerous and have to be deleted, not
    # overwritten.
    export FAKE_SECURITY_MODE=duplicate
    herdr_linear::keychain_write "$SERVICE" "$ACCOUNT" "dup-value"
    herdr_linear::keychain_write "$SERVICE" "$ACCOUNT" "dup-value"
    herdr_linear::keychain_write "$SERVICE" "$ACCOUNT" "dup-value"
    [ "$(find "$WORK/store" -type f | wc -l | tr -d ' ')" -eq 3 ]

    run herdr_linear::keychain_delete "$SERVICE" "$ACCOUNT"
    [ "$status" -eq 0 ]
    [ "$(find "$WORK/store" -type f | wc -l | tr -d ' ')" -eq 0 ]

    # ...and deleting nothing is still success: the post-condition is "clean".
    run herdr_linear::keychain_delete "$SERVICE" "$ACCOUNT"
    [ "$status" -eq 0 ]
}

# The dialog

@test "the dialog yields its value on stdout, asks for a HIDDEN answer, and says nothing on stderr" {
    export FAKE_OSASCRIPT_ANSWER='dialog-value $(whoami) end'

    run --separate-stderr herdr_linear::prompt_secret "Linear setup" "Paste the Linear key"
    [ "$status" -eq 0 ]
    [ "$output" = 'dialog-value $(whoami) end' ]
    [ -z "$stderr" ]

    grep -q 'with hidden answer' "$WORK/rec-osa/argv"
    # The prompt and title go in as arguments; nothing else does.
    grep -qx 'Paste the Linear key' "$WORK/rec-osa/argv"
    grep -qx 'Linear setup' "$WORK/rec-osa/argv"
}

@test "Cancel fails distinctly from a dialog error, and neither prints a value" {
    export FAKE_OSASCRIPT_MODE=cancel
    run --separate-stderr herdr_linear::prompt_secret "t" "p"
    [ "$status" -eq 3 ]
    [ -z "$output" ]
    [ -z "$stderr" ]

    export FAKE_OSASCRIPT_MODE=error
    run --separate-stderr herdr_linear::prompt_secret "t" "p"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [ -z "$stderr" ]

    export FAKE_OSASCRIPT_MODE=empty
    run herdr_linear::prompt_secret "t" "p"
    [ "$status" -eq 2 ]
    [ -z "$output" ]
}

@test "a dialog value writes through to the Keychain without touching argv" {
    export FAKE_OSASCRIPT_ANSWER='handed-over-secret'
    key="$(herdr_linear::prompt_secret "t" "p")"
    herdr_linear::keychain_write "$SERVICE" "$ACCOUNT" "$key"

    run herdr_linear::keychain_read "$SERVICE" "$ACCOUNT"
    [ "$output" = 'handed-over-secret' ]
    refute_match -q 'handed-over-secret' "$WORK/rec/argv"
    refute_match -q 'handed-over-secret' "$WORK/rec-osa/argv"
}

# Display sanitising (R28, the sink half)

# Control characters are written as $'...' escapes rather than as literal bytes:
# a literal ESC in this file is one editor accident away from being invisible in
# every diff that touches it.
@test "an ANSI escape and a Unicode direction override are stripped, and prose survives" {
    dirty=$'\033[2Jtitle'$'\xe2\x80\xae'$'evil\ttabbed\nsecond \xc3\xa9 \xe2\x96\xb8 line\r'
    run herdr_linear::sanitize_for_display "$dirty"
    [ "$status" -eq 0 ]

    # The escape byte itself is gone, so no CSI or OSC sequence can survive.
    refute_match -q $'\033' < <(printf '%s' "$output")
    refute_match -q $'\r' < <(printf '%s' "$output")
    refute_match -qF $'\xe2\x80\xae' < <(printf '%s' "$output")

    # ...and the strip is not "remove everything unusual": a strip-all-non-ASCII
    # bug would pass every assertion above.
    printf '%s' "$output" | grep -qF 'title'
    printf '%s' "$output" | grep -qF $'\xc3\xa9'
    printf '%s' "$output" | grep -qF $'\xe2\x96\xb8'
    printf '%s' "$output" | grep -qF $'\t'
    [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 2 ]
}

@test "the stream filter strips the same sequences from piped output" {
    printf 'a\033[31mred\nb\xe2\x80\xaeflip\n' > "$WORK/log"
    run bash -c '. "$1"; herdr_linear::sanitize_stream < "$2"' _ "$LIB/sanitize.sh" "$WORK/log"
    [ "$status" -eq 0 ]
    refute_match -q $'\033' < <(printf '%s' "$output")
    refute_match -qF $'\xe2\x80\xae' < <(printf '%s' "$output")
    printf '%s' "$output" | grep -qF 'red'
    printf '%s' "$output" | grep -qF 'flip'
}

# Identifier construction (R28, the validation half)

@test "an identifier is CLOSED against [A-Za-z0-9._-], not filtered by denylist" {
    for good in "WEB-2757" "herdr_linear" "v1.2.3" "a" "ABC-1_x.y"; do
        run herdr_linear::is_safe_identifier "$good"
        [ "$status" -eq 0 ]
    done
    # Empty, path separators, traversal, shell metacharacters, whitespace, an
    # escape byte and a direction override. A denylist would have to enumerate
    # every one of these; the closed charset refuses them all by construction,
    # which is why a NEW hostile shape needs no new rule here.
    for bad in "" ".." "a/b" "a b" 'a$b' 'a`b' 'a;b' 'a|b' "a*b" $'a\033b' $'a\xe2\x80\xaeb' $'a\nb' "a'b" 'a"b'; do
        run herdr_linear::is_safe_identifier "$bad"
        [ "$status" -ne 0 ]
    done
}

# Source-level guards

@test "secrets.sh never uses find-generic-password -g, and never exits" {
    refute_match -q 'find-generic-password.*-g\b' "$LIB/secrets.sh"
    # A sourced library that calls exit kills its caller mid-setup.
    refute_match -qE '^[[:space:]]*exit[[:space:]]' "$LIB/secrets.sh"
    # The shell BUILTIN printf on the secret-bearing pipe: an external
    # /usr/bin/printf would put the value straight into the process table.
    # Comments are stripped first — this file explains the trap by name.
    refute_match -q '/usr/bin/printf' < <(sed 's/#.*$//' "$LIB/secrets.sh")
}

@test "secrets.sh prints nothing to stderr on any path (the pure-helper shape)" {
    refute_match -qE '>&2|/dev/stderr|/dev/tty' "$LIB/secrets.sh"
}

@test "the helpers source nothing from another plugin -- vendored, not sourced" {
    # The vendoring is the point: a runtime source of plugins/spawn would make
    # this plugin unusable from a checkout that does not carry it. Comments are
    # stripped first -- both files name the decision in prose, and naming it is
    # not depending on it.
    refute_match -q 'plugins/spawn' < <(sed 's/#.*$//' "$LIB/secrets.sh")
    refute_match -q 'plugins/spawn' < <(sed 's/#.*$//' "$LIB/sanitize.sh")
    refute_match -qE '^[[:space:]]*(\.|source)[[:space:]]' "$LIB/secrets.sh"
    refute_match -qE '^[[:space:]]*(\.|source)[[:space:]]' "$LIB/sanitize.sh"
}

# The detector, seen failing. Twice, for two different reasons.

@test "self-test A: the argv assertion goes RED when the fixture leaks the secret into its record" {
    # Baseline first, so the red below is attributable to the plant rather than
    # to the assertion never having been green.
    herdr_linear::keychain_write "$SERVICE" "$ACCOUNT" "$HOSTILE"
    run grep -q 'whoami' "$WORK/rec/argv"
    [ "$status" -ne 0 ]

    export FAKE_SECURITY_MODE=leak_argv
    herdr_linear::keychain_write "$SERVICE" "$ACCOUNT" "$HOSTILE"
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
        herdr_linear::keychain_write "$SERVICE" "$ACCOUNT" "mutant-secret-value"
    )
    # The write still "succeeds" — read-back passes, because the value did land.
    # What changed is that it landed via argv, and the record says so.
    run grep -q 'mutant-secret-value' "$WORK/rec/argv"
    [ "$status" -eq 0 ]
}
