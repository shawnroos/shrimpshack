#!/usr/bin/env bats

load setup_common

# U1 — the settings inventory. The document is checked against the code in both
# directions, so neither a row for a setting that does not exist nor a setting
# added later without a row can pass.

bats_require_minimum_version 1.5.0

setup() {
    ROOT="${BATS_TEST_DIRNAME}/../.."
    DOC="$ROOT/docs/settings.md"
    RUNNER="$ROOT/tests/run-tests.sh"
}

# Every name read with a default under lib/, whether or not a person may set it.
all_env_reads() {
    grep -ohE '\$\{(HERDR_|LINEAR_)[A-Za-z0-9_]+:?-' "$ROOT"/lib/*.sh \
        | sed -E 's/^\$\{//; s/:?-$//' \
        | sort -u
}

# The subset the document must carry. The excluded classes are test and operator
# seams, not conventions: executable paths, lock/retry/poll/timeout tuning, and
# the identifiers herdr exports into a pane it owns.
#
# The deprecated root spelling is derived from the warning that has to spell it,
# never written here — the brand scan rejects the literal, and an exclusion that
# outlives the fallback it excuses would silently stop requiring a row.
code_knobs() {
    local deprecated
    deprecated="$(grep -m1 'is deprecated' "$ROOT/lib/contain.sh" \
        | grep -oE 'HERDR_[A-Z_]+' | head -1)"
    all_env_reads \
        | grep -vE '_BIN$' \
        | grep -vE '^HERDR_((PANE|TAB|WORKSPACE)_ID|SOCKET_PATH)$' \
        | grep -vE '^HERDR_LINEAR_(LOCK_|RETRY_|PANE_POLL_|TIMEOUT_)' \
        | grep -vE '^HERDR_LINEAR_(CANDIDATE_LIMIT|MIN_SUITES)$' \
        | { if [ -n "$deprecated" ]; then grep -vxF "$deprecated" || true; else cat; fi; }
}

doc_knobs() {
    awk -F'|' '/^\| `/ { gsub(/[ \t`]/, "", $2); print $2 }' "$DOC" | sort -u
}

# Column c of the row naming $1, backticks and padding removed.
doc_col() {
    awk -F'|' -v want="$1" -v c="$2" '
        /^\| `/ {
            name = $2; gsub(/[ \t`]/, "", name)
            if (name != want) next
            f = $(c + 1)
            gsub(/^[ \t]+|[ \t]+$/, "", f); gsub(/`/, "", f)
            print f
        }' "$DOC"
}

@test "the settings document exists" {
    [ -r "$DOC" ]
}

@test "every documented setting is a real environment read under lib/" {
    local reads name
    reads="$(all_env_reads)"
    [ -n "$(doc_knobs)" ]
    while read -r name; do
        [ -n "$name" ] || continue
        printf '%s\n' "$reads" | grep -qxF "$name" \
            || { printf 'documented but never read under lib/: %s\n' "$name" >&2; return 1; }
    done <<<"$(doc_knobs)"
}

@test "every user-settable knob under lib/ is documented" {
    local documented name
    documented="$(doc_knobs)"
    [ -n "$(code_knobs)" ]
    while read -r name; do
        [ -n "$name" ] || continue
        printf '%s\n' "$documented" | grep -qxF "$name" \
            || { printf 'read under lib/ but missing from %s: %s\n' "docs/settings.md" "$name" >&2; return 1; }
    done <<<"$(code_knobs)"
}

@test "empty-versus-unset matches the operator in the defining file" {
    local name file claim
    [ -n "$(doc_knobs)" ]
    while read -r name; do
        [ -n "$name" ] || continue
        file="$ROOT/$(doc_col "$name" 4)"
        claim="$(doc_col "$name" 5)"
        [ -r "$file" ] || { printf 'row %s names an unreadable file: %s\n' "$name" "$file" >&2; return 1; }
        case "$claim" in
            yes)
                grep -qF "\${$name-" "$file" \
                    || { printf '%s is documented as distinguishing empty from unset, but %s does not read it with ${X-default}\n' "$name" "$file" >&2; return 1; } ;;
            no)
                grep -qF "\${$name:-" "$file" \
                    || { printf '%s is documented as collapsing empty to the default, but %s does not read it with ${X:-default}\n' "$name" "$file" >&2; return 1; } ;;
            *)
                printf 'row %s does not say yes or no for empty-versus-unset: %s\n' "$name" "$claim" >&2; return 1 ;;
        esac
    done <<<"$(doc_knobs)"
}

@test "the default named in a row appears in the file the row names" {
    local name file default
    [ -n "$(doc_knobs)" ]
    while read -r name; do
        [ -n "$name" ] || continue
        file="$ROOT/$(doc_col "$name" 4)"
        default="$(doc_col "$name" 2)"
        [ -n "$default" ] || { printf 'row %s carries no default\n' "$name" >&2; return 1; }
        case "$default" in
            "(none)") continue ;;
        esac
        grep -qF "$default" "$file" \
            || { printf 'row %s claims default %s, which does not appear in %s\n' "$name" "$default" "$file" >&2; return 1; }
    done <<<"$(doc_knobs)"
}

@test "the document carries nothing the brand scan rejects" {
    local pattern
    [ -r "$DOC" ]
    pattern="$(sed -n "s/^BRAND_PATTERN='\(.*\)'\$/\1/p" "$RUNNER")"
    [ -n "$pattern" ]
    run grep -nE "$pattern" "$DOC"
    [ "$status" -ne 0 ]
}

@test "the old root spelling is reached by pointing at the file that carries it" {
    grep -qF 'lib/contain.sh' "$DOC"
}
