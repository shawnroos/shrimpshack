#!/usr/bin/env bats

load setup_common

# The credential migration.
#
# Nothing here touches the real Keychain, the real ~/.secrets, or the real
# Linear API. The Keychain goes through tests/fixtures/fake-security.sh and the
# network through tests/fixtures/fake-linear.sh, which stands in for curl.
#
# The second substitution is what makes `verify` testable. An earlier refresh
# script passed the key as `-H "Authorization: $KEY"`, and sampling `ps` caught
# the real credential in process argv in 6 of 9 samples. fake-linear.sh exits 98
# the moment a credential shape appears in argv, so a regression to `-H` in
# `verify` fails the suite instead of quietly leaking.

bats_require_minimum_version 1.5.0

setup() {
    BIN="${BATS_TEST_DIRNAME}/../../bin"
    FIX="${BATS_TEST_DIRNAME}/../fixtures"
    WORK="$(mktemp -d)"

    export HERDR_LINEAR_SECURITY_BIN="$FIX/fake-security.sh"
    export HERDR_LINEAR_CURL_BIN="$FIX/fake-linear.sh"
    export FAKE_SECURITY_STORE_DIR="$WORK/keychain"
    export FAKE_SECURITY_RECORD_DIR="$WORK/security-record"
    export FAKE_OSASCRIPT_RECORD_DIR="$WORK/osascript-record"
    export HERDR_LINEAR_OSASCRIPT_BIN="$WORK/fake-osascript.sh"
    cat > "$HERDR_LINEAR_OSASCRIPT_BIN" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
mkdir -p "$FAKE_OSASCRIPT_RECORD_DIR"
for a in "$@"; do printf '%s\n' "$a"; done >> "$FAKE_OSASCRIPT_RECORD_DIR/argv"
case "${FAKE_OSASCRIPT_MODE:-ok}" in
  cancel) printf '%s\n' "execution error: User canceled. (-128)" >&2; exit 1 ;;
  *)      printf '%s\n' "${FAKE_OSASCRIPT_ANSWER:?}"; exit 0 ;;
esac
STUB
    chmod +x "$HERDR_LINEAR_OSASCRIPT_BIN"
    export FAKE_LINEAR_RECORD_DIR="$WORK/linear-record"
    export LINEAR_SECRETS_FILE="$WORK/secrets"
    mkdir -p "$FAKE_LINEAR_RECORD_DIR"

    # Assembled at runtime: written whole it is a credential shape the repo's
    # own secret scan refuses to have anywhere in the tree.
    KEYLIKE="lin_api""_MIGRATEMIGRATEMIGRATE"
    printf 'MODAL_KEY=abc\nLINEAR_API_KEY=%s\nUNIFI_USER=someone\n' "$KEYLIKE" > "$LINEAR_SECRETS_FILE"
    chmod 600 "$LINEAR_SECRETS_FILE"

    FRESHKEY="lin_api""_FRESHFRESHFRESHFRESH"
    export FAKE_OSASCRIPT_ANSWER="$FRESHKEY"
}

teardown() { [ -n "${WORK:-}" ] && rm -rf "$WORK"; }

# The real `security ... -w` reads the value AND its confirmation, two lines.
# Seeding with one line stores an empty item that exits 0 -- the exact silent
# failure lib/secrets.sh has a read-back compare to catch.
seed_keychain() {
    printf '%s\n%s\n' "$KEYLIKE" "$KEYLIKE" \
        | "$HERDR_LINEAR_SECURITY_BIN" add-generic-password \
            -a linear-api-key -s work-linear -U -w >/dev/null 2>&1
}

stored_key() {
    "$HERDR_LINEAR_SECURITY_BIN" find-generic-password -a linear-api-key -s work-linear -w 2>/dev/null
}

# ---------------------------------------------------------------- store

@test "store saves the pasted key where the board reads it, then verifies it" {
    run --separate-stderr bash -c "FAKE_LINEAR_MODE=viewer bash '$BIN/migrate-credential.sh' store"
    [ "$status" -eq 0 ]
    [[ "$output" == *"authenticates as: Example User"* ]]
    [ "$(stored_key)" = "$FRESHKEY" ]
}

@test "a cancelled prompt stores nothing" {
    run --separate-stderr bash -c "FAKE_OSASCRIPT_MODE=cancel FAKE_LINEAR_MODE=viewer bash '$BIN/migrate-credential.sh' store"
    [ "$status" -ne 0 ]
    [[ "$stderr" == *"cancelled"* ]]
    # The dialog must have been reached: a store that dies before prompting also
    # stores nothing and says "cancelled".
    [ -s "$FAKE_OSASCRIPT_RECORD_DIR/argv" ]
    run stored_key
    [ "$status" -eq 44 ]
}

@test "store never puts the key in any process argv" {
    run bash -c "FAKE_LINEAR_MODE=viewer bash '$BIN/migrate-credential.sh' store"
    [ "$status" -eq 0 ]
    [ -s "$FAKE_SECURITY_RECORD_DIR/argv" ]
    run grep -c "$FRESHKEY" "$FAKE_SECURITY_RECORD_DIR/argv"
    [ "$output" = "0" ]
    run grep -c "$FRESHKEY" "$FAKE_OSASCRIPT_RECORD_DIR/argv"
    [ "$output" = "0" ]
    run grep -c "$FRESHKEY" "$FAKE_LINEAR_RECORD_DIR/argv"
    [ "$output" = "0" ]
}

# ---------------------------------------------------------------- the leak

@test "verify sends the credential on stdin, never on argv" {
    seed_keychain
    run bash -c "FAKE_LINEAR_MODE=viewer bash '$BIN/migrate-credential.sh' verify"
    [ "$status" -eq 0 ]
    # "yes" means an Authorization header arrived on stdin, and the fixture
    # writes that line only after its argv guard has let the call through.
    [ "$(tail -1 "$FAKE_LINEAR_RECORD_DIR/auth_on_stdin")" = "yes" ]
}

@test "reverting to -H would be caught -- the guard is reachable from this path" {
    # Proves the assertion above is load-bearing rather than vacuous: the same
    # fixture, handed the old script's argument shape, refuses it.
    run bash -c "printf '' | '$HERDR_LINEAR_CURL_BIN' -H 'Authorization: $KEYLIKE' -d '{}'"
    [ "$status" -eq 98 ]
}

@test "the recorded argv holds no fragment of the credential" {
    seed_keychain
    run bash -c "FAKE_LINEAR_MODE=viewer bash '$BIN/migrate-credential.sh' verify"
    [ "$status" -eq 0 ]
    [ -s "$FAKE_LINEAR_RECORD_DIR/argv" ]
    run grep -c "$KEYLIKE" "$FAKE_LINEAR_RECORD_DIR/argv"
    [ "$output" = "0" ]
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

@test "after removal the report calls the plaintext copy gone" {
    seed_keychain
    run bash -c "FAKE_LINEAR_MODE=viewer bash '$BIN/migrate-credential.sh' remove-plaintext"
    [ "$status" -eq 0 ]
    run bash "$BIN/migrate-credential.sh" report
    [[ "$output" == *"plaintext $LINEAR_SECRETS_FILE : gone"* ]]
}

@test "an unknown verb exits 2 rather than doing something" {
    run bash "$BIN/migrate-credential.sh" nonsense
    [ "$status" -eq 2 ]
}
