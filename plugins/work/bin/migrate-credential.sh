#!/usr/bin/env bash
# Move the Linear credential from plaintext ~/.secrets into the login Keychain.
#
#   migrate-credential.sh            report the current state and do nothing
#   migrate-credential.sh store      prompt for a key and store it
#   migrate-credential.sh verify     prove the stored key works, read-only
#   migrate-credential.sh remove-plaintext   delete the LINEAR_API_KEY line
#
# A FRESH KEY, NOT THE OLD ONE.
# `store` asks for a newly issued key on purpose. The existing one has lived in
# a plaintext file that dotfile sync and Time Machine may have copied, and it
# spent every cache refresh in process argv where any process running as this
# user could read it (measured 2026-09-04: visible in 6 of 9 samples taken
# during one refresh). Moving that key to the Keychain carries the exposure
# along; issuing a new one and revoking the old one ends it.
#
# Issue one at https://linear.app/settings/api — a personal API key cannot be
# created through the API, so this step is a person at a browser and no
# automation replaces it.
#
# THE STEPS ARE SEPARATE ON PURPOSE.
# `remove-plaintext` edits a file this repo does not own, so it is never a side
# effect of storing. It refuses to run until a Keychain key is present AND has
# been proven to work, and it keeps a backup.

set -uo pipefail

SECRETS_FILE="${LINEAR_SECRETS_FILE:-$HOME/.secrets}"
CACHE="${LINEAR_CACHE_DIR:-$HOME/.claude/linear-cache}"
FALLBACK_MARKER="$CACHE/_plaintext_fallback_used"
KEYCHAIN_SERVICE="${HERDR_LINEAR_KEYCHAIN_SERVICE:-work-linear}"
KEYCHAIN_ACCOUNT="${HERDR_LINEAR_KEYCHAIN_ACCOUNT:-linear-api-key}"
CURL_BIN="${HERDR_LINEAR_CURL_BIN:-curl}"

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" 2>/dev/null && pwd -P)" || LIB_DIR=""
if [ -z "$LIB_DIR" ] || [ ! -r "$LIB_DIR/secrets.sh" ]; then
    printf 'cannot find lib/secrets.sh beside this script\n' >&2
    exit 1
fi
# shellcheck source=/dev/null
. "$LIB_DIR/secrets.sh"

plaintext_present() {
    grep -q '^LINEAR_API_KEY=' "$SECRETS_FILE" 2>/dev/null
}

report() {
    printf 'Linear credential\n'
    if herdr_linear::keychain_exists "$KEYCHAIN_SERVICE" "$KEYCHAIN_ACCOUNT"; then
        printf '  Keychain (%s/%s) : present\n' "$KEYCHAIN_SERVICE" "$KEYCHAIN_ACCOUNT"
    else
        printf '  Keychain (%s/%s) : ABSENT\n' "$KEYCHAIN_SERVICE" "$KEYCHAIN_ACCOUNT"
    fi
    if plaintext_present; then
        printf '  plaintext %s : STILL PRESENT\n' "$SECRETS_FILE"
    else
        printf '  plaintext %s : gone\n' "$SECRETS_FILE"
    fi
    # The marker is the honest signal. The refresh script runs detached, so its
    # stderr warning reaches nobody; this file is how a fallback read stays
    # visible after the fact.
    if [ -f "$FALLBACK_MARKER" ]; then
        printf '  plaintext fallback last used : %s\n' "$(cat "$FALLBACK_MARKER")"
        printf '  -> something still reads the plaintext copy; the migration is not finished\n'
    else
        printf '  plaintext fallback : never used since the marker was last cleared\n'
    fi
}

# A read-only call that proves the stored key is accepted by Linear. The
# credential goes in on stdin; `viewer` is the cheapest authenticated query and
# writes nothing.
verify_key() (
    set +x
    local key resp
    key="$(herdr_linear::keychain_read "$KEYCHAIN_SERVICE" "$KEYCHAIN_ACCOUNT")" || {
        printf 'no key in the Keychain to verify\n' >&2
        return 1
    }
    [ -n "$key" ] || { printf 'the Keychain item is empty\n' >&2; return 1; }
    resp="$(printf 'header = "Authorization: %s"\nheader = "Content-Type: application/json"\nurl = "https://api.linear.app/graphql"\n' "$key" \
        | "$CURL_BIN" -s --max-time 20 --config - -X POST -d '{"query":"{ viewer { id name } }"}')"
    case "$resp" in
        *AUTHENTICATION_ERROR*)
            printf 'Linear refused the stored key\n' >&2
            return 1
            ;;
        *'"viewer"'*)
            # Print the account name, which is not a secret, so the operator can
            # see WHICH account the key belongs to before retiring the old one.
            printf 'the stored key authenticates as: %s\n' \
                "$(printf '%s' "$resp" | jq -r '.data.viewer.name // "unknown"' 2>/dev/null)"
            return 0
            ;;
        *)
            printf 'unexpected response while verifying; not treating this as success\n' >&2
            return 1
            ;;
    esac
)

store() {
    printf 'Issue a FRESH key at https://linear.app/settings/api, then paste it.\n'
    printf 'It is read without echo and never printed.\n'
    local secret rc
    secret="$(herdr_linear::prompt_secret 'Linear API key')" || {
        printf 'cancelled; nothing was stored\n' >&2
        return 1
    }
    herdr_linear::keychain_write "$KEYCHAIN_SERVICE" "$KEYCHAIN_ACCOUNT" "$secret"
    rc=$?
    unset secret
    case "$rc" in
        0) printf 'stored, and read back byte-for-byte\n' ;;
        2) printf 'refused: an empty value is not a credential\n' >&2; return 1 ;;
        4) printf 'refused: that value cannot survive a Keychain write (a newline or a non-printable byte)\n' >&2; return 1 ;;
        *) printf 'the Keychain write failed\n' >&2; return 1 ;;
    esac
    verify_key
}

remove_plaintext() {
    if ! herdr_linear::keychain_exists "$KEYCHAIN_SERVICE" "$KEYCHAIN_ACCOUNT"; then
        printf 'refusing: there is no Keychain key to fall back on\n' >&2
        return 1
    fi
    if ! verify_key >/dev/null 2>&1; then
        printf 'refusing: the Keychain key does not authenticate, so removing the plaintext copy would leave nothing working\n' >&2
        return 1
    fi
    if ! plaintext_present; then
        printf 'already gone: no LINEAR_API_KEY line in %s\n' "$SECRETS_FILE"
        return 0
    fi

    local backup
    backup="$SECRETS_FILE.bak.$(date -u +%Y%m%dT%H%M%SZ)"
    cp -p "$SECRETS_FILE" "$backup" || { printf 'could not back up %s\n' "$SECRETS_FILE" >&2; return 1; }
    chmod 600 "$backup"

    # Written through a temporary file in the same directory and renamed, so an
    # interrupted edit cannot leave the secrets file truncated.
    local tmp
    tmp="$(mktemp "$(dirname "$SECRETS_FILE")/.secrets.XXXXXX")" || return 1
    chmod 600 "$tmp"
    grep -v '^LINEAR_API_KEY=' "$SECRETS_FILE" >"$tmp" || true
    mv -f "$tmp" "$SECRETS_FILE" || { rm -f "$tmp"; return 1; }

    rm -f "$FALLBACK_MARKER"
    printf 'removed the LINEAR_API_KEY line; backup at %s\n' "$backup"
    printf 'the backup STILL CONTAINS the old key -- delete it once you have revoked that key in Linear\n'
    return 0
}

case "${1:-report}" in
    report)           report ;;
    store)            store ;;
    verify)           verify_key ;;
    remove-plaintext) remove_plaintext ;;
    *)
        printf 'usage: %s [report|store|verify|remove-plaintext]\n' "$(basename "$0")" >&2
        exit 2
        ;;
esac
