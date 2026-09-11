#!/usr/bin/env bats

load setup_common

# The unit test for setup_common.bash itself.
#
# Every other suite proves something about the plugin; none of them can prove
# the fixture worked, because a leaked seam looks exactly like a pass. These
# assertions read the environment the shared setup leaves behind, so a narrowing
# of the sweep -- to `^HERDR_LINEAR_`, say, which is where this started -- turns
# a line here red instead of quietly reopening the hole.

@test "the deprecated root name does not survive the sweep" {
    [ -z "${HERDR_LINEAR_SLATE_ROOT:-}" ]
}

@test "the herdr position seams do not survive the sweep" {
    # Set for real in any session launched by herdr, which is where this suite
    # usually runs. Outside ^HERDR_LINEAR_, so a namespace-narrowing breaks here.
    [ -z "${HERDR_PANE_ID:-}" ]
    [ -z "${HERDR_TAB_ID:-}" ]
    [ -z "${HERDR_WORKSPACE_ID:-}" ]
}

@test "the session identifier does not survive the sweep" {
    [ -z "${CLAUDE_SESSION_ID:-}" ]
}

@test "the tuning knobs do not survive the sweep" {
    # These decide answers rather than paths, and no suite overrides them.
    [ -z "${HERDR_LINEAR_BRANCH_PREFIX:-}" ]
    [ -z "${HERDR_LINEAR_LOCK_WAIT_SECONDS:-}" ]
    [ -z "${HERDR_LINEAR_KEYCHAIN_SERVICE:-}" ]
    [ -z "${HERDR_LINEAR_KEYCHAIN_ACCOUNT:-}" ]
}

@test "every path seam that defaults into the home directory points at the fixture" {
    local sandbox v
    sandbox="${BATS_TEST_TMPDIR:?}/isolate"
    for v in "$HERDR_LINEAR_STORE_DIR" "$HERDR_LINEAR_PIN_DIR" \
             "$HERDR_LINEAR_JOURNAL_DIR" "$HERDR_LINEAR_DESC_BACKUP_DIR" \
             "$HERDR_LINEAR_SHADOW_LOG" "$LINEAR_CACHE_DIR" \
             "$LINEAR_SECRETS_FILE" "$HERDR_LINEAR_PROJECTS_ROOT"; do
        [ "${v#"$sandbox"/}" != "$v" ]
    done
}

@test "every external binary seam names a path that is not there" {
    local v
    for v in "$HERDR_LINEAR_CURL_BIN" "$HERDR_LINEAR_SECURITY_BIN" \
             "$HERDR_LINEAR_OSASCRIPT_BIN" "$HERDR_LINEAR_GH_BIN" "$HERDR_BIN"; do
        [ -n "$v" ]
        [ ! -e "$v" ]
    done
}

@test "the herdr search path is empty rather than unset" {
    # `${HERDR_LINEAR_BIN_PATHS-default}` is a dash, not a colon-dash: unset
    # reaches this machine's real /opt/homebrew/bin, and only empty stops it.
    [ -n "${HERDR_LINEAR_BIN_PATHS+set}" ]
    [ -z "$HERDR_LINEAR_BIN_PATHS" ]
}
