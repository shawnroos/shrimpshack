#!/usr/bin/env bats
# U12 — the credential migration and the in-tree cache refresh.
#
# Nothing here touches the real Keychain, the real ~/.secrets, or the real
# Linear API. The Keychain goes through tests/fixtures/fake-security.sh and the
# network through tests/fixtures/fake-linear.sh, which stands in for curl.
#
# THAT SECOND SUBSTITUTION IS THE POINT OF THE FILE.
# The defect this unit exists to fix was measured, not supposed: the previous
# copy of the refresh script passed the key as `-H "Authorization: $KEY"`, and
# sampling `ps` during one single-issue refresh caught the real credential in
# process argv in 6 of 9 samples. fake-linear.sh exits 98 the moment a
# credential shape appears in argv, so a regression to `-H` fails the suite
# instead of quietly leaking on every statusline cache miss.

bats_require_minimum_version 1.5.0

setup() {
    BIN="${BATS_TEST_DIRNAME}/../../bin"
    FIX="${BATS_TEST_DIRNAME}/../fixtures"
    WORK="$(mktemp -d)"

    export HERDR_LINEAR_SECURITY_BIN="$FIX/fake-security.sh"
    export HERDR_LINEAR_CURL_BIN="$FIX/fake-linear.sh"
    export FAKE_SECURITY_STORE_DIR="$WORK/keychain"
    export FAKE_LINEAR_RECORD_DIR="$WORK/linear-record"
    export LINEAR_SECRETS_FILE="$WORK/secrets"
    export LINEAR_CACHE_DIR="$WORK/cache"
    mkdir -p "$FAKE_LINEAR_RECORD_DIR" "$LINEAR_CACHE_DIR"

    # Assembled at runtime: written whole it is a credential shape the repo's
    # own secret scan refuses to have anywhere in the tree.
    KEYLIKE="lin_api""_MIGRATEMIGRATEMIGRATE"
    printf 'MODAL_KEY=abc\nLINEAR_API_KEY=%s\nUNIFI_USER=someone\n' "$KEYLIKE" > "$LINEAR_SECRETS_FILE"
    chmod 600 "$LINEAR_SECRETS_FILE"
}

teardown() { [ -n "${WORK:-}" ] && rm -rf "$WORK"; }

# The real `security ... -w` reads the value AND its confirmation, two lines.
# Seeding with one line stores an empty item that exits 0 -- the exact silent
# failure lib/secrets.sh has a read-back compare to catch.
seed_keychain() {
    printf '%s\n%s\n' "$KEYLIKE" "$KEYLIKE" \
        | "$HERDR_LINEAR_SECURITY_BIN" add-generic-password \
            -a linear-api-key -s herdr-linear -U -w >/dev/null 2>&1
}

# ---------------------------------------------------------------- the leak

@test "the refresh sends the credential on stdin, never on argv" {
    run bash -c "FAKE_LINEAR_MODE=found_child bash '$BIN/linear-cache-refresh.sh' WEB-3318"
    # NOT asserted on $status. curl runs inside a command substitution whose
    # pipeline ends in wc, and the script exits from a later echo, so the
    # fixture's 98 never reaches here -- an exit-code assertion would pass
    # whether the credential leaked or not. The record is what carries this
    # test: "yes" means an Authorization header arrived on stdin, and the
    # fixture writes that line only after its argv guard has let the call
    # through. A revert to `-H` was mutation-tested and turns this red.
    [ "$(tail -1 "$FAKE_LINEAR_RECORD_DIR/auth_on_stdin")" = "yes" ]
}

@test "reverting to -H would be caught -- the guard is reachable from this path" {
    # Proves the assertion above is load-bearing rather than vacuous: the same
    # fixture, handed the old script's argument shape, refuses it.
    run bash -c "printf '' | FAKE_LINEAR_MODE=found_child '$HERDR_LINEAR_CURL_BIN' -H 'Authorization: $KEYLIKE' -d '{}'"
    [ "$status" -eq 98 ]
}

@test "the recorded argv holds no fragment of the credential" {
    run bash -c "FAKE_LINEAR_MODE=found_child bash '$BIN/linear-cache-refresh.sh' WEB-3318"
    run grep -c "$KEYLIKE" "$FAKE_LINEAR_RECORD_DIR/argv"
    [ "$output" = "0" ]
}

# ------------------------------------------------------- the source of truth

@test "the Keychain is preferred over the plaintext copy, and no fallback marker appears" {
    seed_keychain
    run bash -c "FAKE_LINEAR_MODE=found_child bash '$BIN/linear-cache-refresh.sh' WEB-3318"
    [ "$status" -eq 0 ]
    [ ! -f "$LINEAR_CACHE_DIR/_plaintext_fallback_used" ]
}

# The refresh runs detached from the statusline, so its stderr reaches nobody.
# A warning alone would make a plaintext read invisible; the marker is what
# keeps it detectable after the fact.
@test "a plaintext fallback read is recorded in a marker, not only on stderr" {
    run --separate-stderr bash -c "FAKE_LINEAR_MODE=found_child bash '$BIN/linear-cache-refresh.sh' WEB-3318"
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"read the Linear key from plaintext"* ]]
    [ -f "$LINEAR_CACHE_DIR/_plaintext_fallback_used" ]
}

@test "with no credential anywhere the refresh fails loudly instead of calling Linear unauthenticated" {
    rm -f "$LINEAR_SECRETS_FILE"
    run --separate-stderr bash -c "FAKE_LINEAR_MODE=found_child bash '$BIN/linear-cache-refresh.sh' WEB-3318"
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"no Linear credential"* ]]
    # The decisive part: it never reached the network at all.
    [ ! -s "$FAKE_LINEAR_RECORD_DIR/argv" ] || [ ! -f "$FAKE_LINEAR_RECORD_DIR/argv" ]
}

# ------------------------------------------------------------- the migration

@test "report names both sources without printing either value" {
    run bash "$BIN/migrate-credential.sh" report
    [ "$status" -eq 0 ]
    [[ "$output" == *"ABSENT"* ]]
    [[ "$output" == *"STILL PRESENT"* ]]
    run grep -c "$KEYLIKE" <<< "$output"
    [ "$output" = "0" ]
}

@test "report calls the migration unfinished while the fallback marker exists" {
    date -u > "$LINEAR_CACHE_DIR/_plaintext_fallback_used"
    run bash "$BIN/migrate-credential.sh" report
    [[ "$output" == *"the migration is not finished"* ]]
}

@test "verify proves the stored key is accepted, and names the account" {
    seed_keychain
    run bash -c "FAKE_LINEAR_MODE=viewer bash '$BIN/migrate-credential.sh' verify"
    [ "$status" -eq 0 ]
    [[ "$output" == *"authenticates as: Example User"* ]]
}

@test "verify fails when Linear refuses the key" {
    seed_keychain
    run bash -c "FAKE_LINEAR_MODE=auth_error bash '$BIN/migrate-credential.sh' verify"
    [ "$status" -ne 0 ]
}

@test "verify fails when there is nothing stored, rather than reporting success" {
    run bash -c "FAKE_LINEAR_MODE=viewer bash '$BIN/migrate-credential.sh' verify"
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------- removing the plaintext

@test "remove-plaintext refuses while nothing is in the Keychain" {
    run --separate-stderr bash -c "FAKE_LINEAR_MODE=viewer bash '$BIN/migrate-credential.sh' remove-plaintext"
    [ "$status" -ne 0 ]
    [[ "$stderr" == *"no Keychain key to fall back on"* ]]
    run grep -c '^LINEAR_API_KEY=' "$LINEAR_SECRETS_FILE"
    [ "$output" = "1" ]
}

# The dangerous case: a key IS stored but does not work. Removing the plaintext
# then leaves nothing functional, which is worse than not migrating at all.
@test "remove-plaintext refuses when the stored key does not authenticate" {
    seed_keychain
    run --separate-stderr bash -c "FAKE_LINEAR_MODE=auth_error bash '$BIN/migrate-credential.sh' remove-plaintext"
    [ "$status" -ne 0 ]
    [[ "$stderr" == *"does not authenticate"* ]]
    run grep -c '^LINEAR_API_KEY=' "$LINEAR_SECRETS_FILE"
    [ "$output" = "1" ]
}

@test "remove-plaintext drops only the Linear line and keeps the other secrets" {
    seed_keychain
    run bash -c "FAKE_LINEAR_MODE=viewer bash '$BIN/migrate-credential.sh' remove-plaintext"
    [ "$status" -eq 0 ]
    run grep -c '^LINEAR_API_KEY=' "$LINEAR_SECRETS_FILE"
    [ "$output" = "0" ]
    run grep -c '^MODAL_KEY=' "$LINEAR_SECRETS_FILE"
    [ "$output" = "1" ]
    run grep -c '^UNIFI_USER=' "$LINEAR_SECRETS_FILE"
    [ "$output" = "1" ]
}

@test "remove-plaintext leaves a 0600 backup and says the old key is still in it" {
    seed_keychain
    run bash -c "FAKE_LINEAR_MODE=viewer bash '$BIN/migrate-credential.sh' remove-plaintext"
    [ "$status" -eq 0 ]
    [[ "$output" == *"STILL CONTAINS the old key"* ]]
    backup="$(ls "$LINEAR_SECRETS_FILE".bak.* 2>/dev/null | head -1)"
    [ -n "$backup" ]
    [ "$(stat -f %Lp "$backup")" = "600" ]
    run grep -c '^LINEAR_API_KEY=' "$backup"
    [ "$output" = "1" ]
}

@test "a second remove-plaintext is a no-op that reports the state, not a failure" {
    seed_keychain
    run bash -c "FAKE_LINEAR_MODE=viewer bash '$BIN/migrate-credential.sh' remove-plaintext"
    [ "$status" -eq 0 ]
    run bash -c "FAKE_LINEAR_MODE=viewer bash '$BIN/migrate-credential.sh' remove-plaintext"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already gone"* ]]
}

@test "after removal the Keychain is the only source and no fallback occurs" {
    seed_keychain
    run bash -c "FAKE_LINEAR_MODE=viewer bash '$BIN/migrate-credential.sh' remove-plaintext"
    [ "$status" -eq 0 ]
    run bash -c "FAKE_LINEAR_MODE=found_child bash '$BIN/linear-cache-refresh.sh' WEB-3318"
    [ "$status" -eq 0 ]
    [ ! -f "$LINEAR_CACHE_DIR/_plaintext_fallback_used" ]
    run bash "$BIN/migrate-credential.sh" report
    [[ "$output" == *"plaintext $LINEAR_SECRETS_FILE : gone"* ]]
}

@test "an unknown verb exits 2 rather than doing something" {
    run bash "$BIN/migrate-credential.sh" nonsense
    [ "$status" -eq 2 ]
}
