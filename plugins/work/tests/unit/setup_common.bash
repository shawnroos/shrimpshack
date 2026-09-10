# Shared test isolation. Every suite loads this before its own exports.
#
# The libraries and hooks read roughly ninety environment seams. Naming one of
# them per suite is how ten suites came to carry a hand-written
# `unset HERDR_LINEAR_SLATE_ROOT` while the seams that actually decide a test's
# answer -- the tuning knobs nobody exports -- stayed open. So the NAMESPACE is
# cleared rather than any member of it named, and a seam added later is covered
# the day it is written.
#
# Clearing alone is not enough. An unset seam falls back to a default, and the
# defaults are $HOME/.secrets, $HOME/.claude/work, /usr/bin/security,
# /usr/bin/osascript, real curl against the live API and real gh. Every seam
# that would otherwise leave this test's own directory is pointed back inside
# it. HERDR_LINEAR_GIT_BIN is the one exception: the suites build real
# repositories, so git stays the machine's own.

herdr_linear_test::isolate() {
    local v
    for v in $(compgen -e | grep -E '^(HERDR_|LINEAR_|FAKE_|CLAUDE_SESSION_ID$)' || true); do
        unset "$v"
    done

    local sandbox="${BATS_TEST_TMPDIR:-${BATS_SUITE_TMPDIR:-$(mktemp -d)}}/isolate"
    mkdir -p "$sandbox"

    export HERDR_LINEAR_PROJECTS_ROOT="$sandbox/projects"
    export HERDR_LINEAR_STORE_DIR="$sandbox/store"
    export HERDR_LINEAR_PIN_DIR="$sandbox/pin"
    export HERDR_LINEAR_JOURNAL_DIR="$sandbox/layouts"
    export HERDR_LINEAR_DESC_BACKUP_DIR="$sandbox/descriptions"
    export HERDR_LINEAR_SHADOW_LOG="$sandbox/shadow.log"
    export LINEAR_CACHE_DIR="$sandbox/cache"
    export LINEAR_SECRETS_FILE="$sandbox/secrets"

    # Deliberately absent paths rather than the fixtures: a suite that forgot to
    # install its own stub must fail, not pass against a stand-in it never asked
    # for. A path that is not there refuses every call.
    export HERDR_LINEAR_CURL_BIN="$sandbox/absent/curl"
    export HERDR_LINEAR_SECURITY_BIN="$sandbox/absent/security"
    export HERDR_LINEAR_OSASCRIPT_BIN="$sandbox/absent/osascript"
    export HERDR_LINEAR_GH_BIN="$sandbox/absent/gh"
    export HERDR_BIN="$sandbox/absent/herdr"

    # Set-but-empty, never unset: the reader spells this ${VAR-default}, so only
    # an empty value stops the scan reaching this machine's real install paths.
    export HERDR_LINEAR_BIN_PATHS=""
}

herdr_linear_test::isolate
