#!/usr/bin/env bats
# U2 — fetch, build and promote the gateway release.
#
# Everything here runs against fixtures. A suite that fetched from GitHub and
# ran a real `cargo build --release` would be slow, rate-limited and dependent
# on what upstream published this morning, and all three are how a green suite
# stops meaning anything. The two seams — SPAWN_CURL_BIN and SPAWN_CARGO_BIN —
# are how the whole path redirects (KTD8, the SPAWN_CLAUDE_BIN precedent).
#
# THE ASSERTION THIS FILE EXISTS FOR is the mid-build one: while a build is in
# flight, spawnctl.sh's resolve_install_dir must still select the PRE-EXISTING
# older install, because a half-made ~/gateway-<newer> bricks every concurrent
# status, lens and launch with exit 3 (and, once the binary lands but the config
# has not, misreports a token failure as exit 7). It is followed immediately by
# its own deliberate-fail proof: the same assertion run against a MUTATED
# setup.sh that stages inside the glob, seen going red (G3).
#
# TWO FALSE-GREEN TRAPS THIS FILE IS WRITTEN AGAINST
#   1. bats' own `run` MERGES stdout and stderr, and this script prints
#      progress to stderr. Merged, every `jq` assertion below would be parsing
#      diagnostics — so stdout and stderr are captured to SEPARATE files.
#   2. "no version directory was created" is vacuously true if the acquire
#      never got far enough to try. Every such assertion is paired with one
#      that proves the path DID run (a recorded curl call, a recorded build).

setup() {
    FIX="$(cd "$BATS_TEST_DIRNAME/../fixtures" && pwd)"
    LIB="$(cd "$BATS_TEST_DIRNAME/../../lib" && pwd)"
    SETUP="$LIB/setup.sh"
    CTL="$LIB/spawnctl.sh"
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/gw-acq.XXXXXX")"
    WORK="$(cd "$WORK" && pwd -P)"

    # The search root is redirected into $WORK so no test can discover — or
    # promote over — this machine's real ~/gateway-0.1.1 install.
    export SPAWN_SEARCH_ROOT="$WORK/root"
    mkdir -p "$SPAWN_SEARCH_ROOT"
    export SPAWN_STATE_HOME="$WORK"
    # spawnctl.sh is invoked below for its resolver; point its probe at a port
    # nothing serves so it can never reach the real gateway on 4000.
    export SPAWN_BASE_URL="http://127.0.0.1:1/anthropic"
    export SPAWN_CONNECT_TIMEOUT=1
    export SPAWN_PROBE_TIMEOUT=2
    unset SPAWN_INSTALL_DIR SPAWN_CONFIG SPAWN_MODELS_JSON

    export SPAWN_CURL_BIN="$FIX/fake-curl.sh"
    export SPAWN_CARGO_BIN="$FIX/fake-cargo.sh"
    export FAKE_CURL_RECORD_DIR="$WORK/rec-curl"
    export FAKE_CARGO_RECORD_DIR="$WORK/rec-cargo"
    export FAKE_CURL_MODE=ok
    export FAKE_CARGO_MODE=ok
    export FAKE_CURL_TAG="v9.9.9"
    export FAKE_CURL_SHA="abc1234abc1234abc1234abc1234abc1234abc12"
    export FAKE_CURL_TARBALL="$WORK/src.tar.gz"
    # The install the fixture tag promotes to, spelled once.
    DEST="$SPAWN_SEARCH_ROOT/gateway-9.9.9"
    OLD="$SPAWN_SEARCH_ROOT/gateway-0.1.0"

    # --- U4 isolation ------------------------------------------------------
    # Acquire now refuses to promote an install that can be authenticated by
    # nothing (R9): the config it stages carries no token, so a stored one has
    # to exist. That makes the Keychain part of EVERY acquire, including the
    # tests here that predate U4 — without a fake one they would query this
    # machine's login keychain. Same env-override discipline as the search root.
    export SPAWN_SECURITY_BIN="$FIX/fake-security.sh"
    export FAKE_SECURITY_STORE_DIR="$WORK/kc-store"
    export FAKE_SECURITY_RECORD_DIR="$WORK/kc-record"
    mkdir -p "$FAKE_SECURITY_STORE_DIR" "$FAKE_SECURITY_RECORD_DIR"
    export SPAWN_KEYCHAIN_SERVICE="spawn-gateway-test"
    export FAKE_SECURITY_MODE=ok

    OUT="$WORK/out.json"
    ERR="$WORK/err.txt"
    RC=0

    make_tarball "$FAKE_CURL_TARBALL"
    # The stored gateway token R9 requires. Its VALUE is never used here — the
    # R9 gate asks only whether one exists. setup-config.bats owns the refusal.
    printf 'acq-tok-x1y2z3\nacq-tok-x1y2z3\n' \
        | "$SPAWN_SECURITY_BIN" add-generic-password \
            -a gateway-token -s "$SPAWN_KEYCHAIN_SERVICE" -U -w
}

teardown() {
    # Any fake cargo left paused lives under $WORK, so its argv carries the
    # path and nothing outside this test can match.
    local p
    for p in $(pgrep -f "$WORK" 2>/dev/null); do
        [ "$p" = "$$" ] && continue
        kill -9 "$p" 2>/dev/null
    done
    rm -rf "$WORK"
    return 0
}

# --- helpers ---------------------------------------------------------------

# make_tarball <path> [--no-config] — a real gzipped tar in GitHub's shape: one
# generated top-level <owner>-<repo>-<sha> directory holding the repo root. Real
# rather than stubbed, so --strip-components=1 is actually exercised.
make_tarball() {
    local path="$1" no_config="${2:-}" src="$WORK/tarsrc"
    rm -rf "$src"
    mkdir -p "$src/superagent-ai-gateway-abc1234/src"
    printf '[package]\nname = "gateway"\nversion = "9.9.9"\n' \
        > "$src/superagent-ai-gateway-abc1234/Cargo.toml"
    printf 'fn main() {}\n' > "$src/superagent-ai-gateway-abc1234/src/main.rs"
    if [ "$no_config" != "--no-config" ]; then
        {
            printf 'server:\n'
            printf '  bind: "127.0.0.1:4000"\n'
            printf 'models:\n'
            printf '  alpha:\n'
            printf '    model: openrouter/alpha\n'
        } > "$src/superagent-ai-gateway-abc1234/gateway.yaml"
    fi
    tar czf "$path" -C "$src" superagent-ai-gateway-abc1234
    rm -rf "$src"
}

# make_install <dir> [broken] — a complete install the resolver accepts: a
# REGULAR, EXECUTABLE binary at the canonical path plus a config. `broken`
# writes a binary that resolves and then fails to execute, which is the state
# an interrupted build or a wrong-architecture copy actually leaves behind.
make_install() {
    local dir="$1" kind="${2:-ok}"
    mkdir -p "$dir/target/release"
    if [ "$kind" = "broken" ]; then
        cat > "$dir/target/release/gateway" <<'EOS'
#!/usr/bin/env bash
echo "cannot execute: fixture broken binary" >&2
exit 126
EOS
    else
        cat > "$dir/target/release/gateway" <<'EOS'
#!/usr/bin/env bash
case "${1:-}" in
  --version) printf 'gateway (fixture install)\n' ;;
  *)         printf 'fixture install binary\n' ;;
esac
exit 0
EOS
    fi
    chmod +x "$dir/target/release/gateway"
    printf 'server:\n  bind: "127.0.0.1:4000"\nmodels:\n  alpha:\n    model: openrouter/alpha\n' \
        > "$dir/gateway.yaml"
}

# Stdout and stderr to SEPARATE files: this script prints progress to stderr,
# and bats' `run` would merge it into the JSON every assertion below parses.
run_acquire() {
    local script="${1:-$SETUP}"
    rm -f "$OUT" "$ERR"
    RC=0
    bash "$script" acquire >"$OUT" 2>"$ERR" || RC=$?
    return 0
}

curl_urls()   { cat "$FAKE_CURL_RECORD_DIR/urls" 2>/dev/null; }
curl_calls()  { curl_urls | grep -c . ; }
# Prints a NUMBER on every path, including "the fixture was never invoked, so
# there is no record file at all" — a bare `grep -c` there prints nothing, and
# `[ "" -eq 0 ]` is a test error rather than the pass it looks like.
cargo_calls() { grep -c -- '--- invocation ---' "$FAKE_CARGO_RECORD_DIR/argv" 2>/dev/null || printf '0'; }

# The one JSON object on stdout, whatever the path.
assert_one_json() {
    [ -s "$OUT" ]
    [ "$(grep -c . "$OUT")" -eq 1 ]
    jq -e . "$OUT" >/dev/null
    jq -e 'has("ok") and has("error") and has("exit_code")' "$OUT" >/dev/null
}

# staging_dirs — every staging directory currently on disk under the search
# root, matched by the dot-prefixed name the script uses.
staging_dirs() {
    find "$SPAWN_SEARCH_ROOT" -maxdepth 1 -name '.gateway-staging.*' 2>/dev/null
}

# glob_dirs — exactly what spawnctl.sh's resolver globs for.
glob_dirs() {
    find "$SPAWN_SEARCH_ROOT" -maxdepth 1 -name 'gateway-*' 2>/dev/null | sort
}

# mutant <sed-expression> — a copy of the whole lib with setup.sh mutated. The
# whole directory is copied because setup.sh sources sanitize.sh and common.sh
# relative to its own location. Prints the mutated script's path.
mutant() {
    local expr="$1" dir="$WORK/mutlib"
    rm -rf "$dir"
    mkdir -p "$dir"
    cp "$LIB"/*.sh "$dir/"
    [ -f "$LIB/models.json" ] && cp "$LIB/models.json" "$dir/"
    sed -i '' "$expr" "$dir"/*.sh
    printf '%s' "$dir/setup.sh"
}

# ---------------------------------------------------------------------------
# The happy path (R1, R2)
# ---------------------------------------------------------------------------

@test "acquire fetches, builds and promotes to gateway-<version>, leaving no staging directory" {
    run_acquire
    [ "$RC" -eq 0 ]
    assert_one_json

    [ "$(jq -r '.ok' "$OUT")" = "true" ]
    [ "$(jq -r '.action' "$OUT")" = "installed" ]
    [ "$(jq -r '.install_dir' "$OUT")" = "$DEST" ]

    # A complete install: executable binary AND config.
    [ -f "$DEST/target/release/gateway" ]
    [ -x "$DEST/target/release/gateway" ]
    [ -f "$DEST/gateway.yaml" ]
    # ...and the source came out of the archive with the generated top-level
    # directory stripped, not nested inside it.
    [ -f "$DEST/Cargo.toml" ]

    # Nothing left behind, under either name.
    [ -z "$(staging_dirs)" ]
    [ -z "$(find "$SPAWN_SEARCH_ROOT" -maxdepth 1 -name '.gateway-replaced.*' 2>/dev/null)" ]
}

@test "the release is pinned by TAG and identified by COMMIT SHA — no tarball checksum (KTD16)" {
    run_acquire
    [ "$RC" -eq 0 ]
    [ "$(jq -r '.tag' "$OUT")" = "v9.9.9" ]
    [ "$(jq -r '.commit' "$OUT")" = "$FAKE_CURL_SHA" ]

    # The tag is what the archive URL carries; the sha is recorded, never used
    # to gate the download, because GitHub source tarballs are generated on
    # demand and are not byte-stable.
    curl_urls | grep -q 'archive/refs/tags/v9.9.9.tar.gz'
    ! grep -qi 'checksum\|sha256' "$OUT"
}

@test "the build runs INSIDE the staging tree, not in the destination or the cwd" {
    run_acquire
    [ "$RC" -eq 0 ]
    # fake-cargo records its cwd. It must be a staging path — anything else
    # means the build wrote its artifacts somewhere the promotion never sees.
    grep -q '/\.gateway-staging\.' "$FAKE_CARGO_RECORD_DIR/cwd"
}

# ---------------------------------------------------------------------------
# KTD4 — the glob never sees a half-made install
# ---------------------------------------------------------------------------

@test "mid-build, resolve_install_dir still selects the pre-existing older install" {
    make_install "$OLD"
    export FAKE_CARGO_MODE=pause
    export FAKE_CARGO_RELEASE="$WORK/release-cargo"

    bash "$SETUP" acquire >"$OUT" 2>"$ERR" &
    local acq=$!

    # Wait for the build to actually be in flight, so the assertions below are
    # made against a staging directory that exists rather than one that has not
    # been created yet (which would pass vacuously).
    local i
    for ((i = 0; i < 200; i++)); do
        [ -s "$FAKE_CARGO_RECORD_DIR/started" ] && break
        sleep 0.1
    done
    [ -s "$FAKE_CARGO_RECORD_DIR/started" ]

    # THE ASSERTION: the resolver's glob sees only the old install, never the
    # build in flight. It is made BEFORE the staging-dir check below so that a
    # setup.sh which staged inside the glob fails HERE — on the property that
    # matters — rather than on a helper that stopped finding a renamed
    # directory.
    [ "$(glob_dirs)" = "$OLD" ]
    # ...and the staging directory really IS on disk right now, so the line
    # above was not passing over a build that had not started.
    [ -n "$(staging_dirs)" ]

    # The real thing, through spawnctl.sh rather than a re-implementation of its
    # resolver: a concurrent status resolves the OLD install, not a half-made
    # newer one. (Its exit code is 3 — nothing is listening on port 1 — but the
    # install_dir field is what this assertion is about.)
    run bash "$CTL" status
    local install_dir
    install_dir="$(printf '%s\n' "$output" | jq -r '.install_dir')"
    [ "$install_dir" = "$OLD" ]

    touch "$FAKE_CARGO_RELEASE"
    wait "$acq"
    [ -f "$DEST/target/release/gateway" ]
    [ -z "$(staging_dirs)" ]
}

@test "G3 self-test: staging INSIDE the glob makes that assertion go red (seen failing)" {
    make_install "$OLD"
    # The mutation is to the CODE, not to a test flag: staging is renamed into
    # the glob's namespace at a version that sorts above every real install —
    # exactly the shape KTD4 forbids.
    local script
    script="$(mutant 's|\.gateway-staging\.XXXXXX|gateway-99999.XXXXXX|')"
    grep -rq 'gateway-99999.XXXXXX' "$(dirname "$script")"

    export FAKE_CARGO_MODE=pause
    export FAKE_CARGO_RELEASE="$WORK/release-cargo"

    bash "$script" acquire >"$OUT" 2>"$ERR" &
    local acq=$!
    local i
    for ((i = 0; i < 200; i++)); do
        [ -s "$FAKE_CARGO_RECORD_DIR/started" ] && break
        sleep 0.1
    done
    [ -s "$FAKE_CARGO_RECORD_DIR/started" ]

    # RED, in both the direct and the through-spawnctl form: the glob now
    # matches the half-made staging directory...
    [ "$(glob_dirs)" != "$OLD" ]
    # ...and status no longer resolves the working older install. It resolves
    # NOTHING — the newest match holds no binary yet, and there is no fallback
    # past it, which is the exit-3 brick this unit exists to prevent.
    run bash "$CTL" status
    local install_dir
    install_dir="$(printf '%s\n' "$output" | jq -r '.install_dir')"
    [ "$install_dir" != "$OLD" ]
    [ "$install_dir" = "null" ]
    printf '%s\n' "$output" | jq -e '.install_dir_error | test("no executable")' >/dev/null

    touch "$FAKE_CARGO_RELEASE"
    wait "$acq" || true
}

# ---------------------------------------------------------------------------
# Promotion refusals and failure paths (R2, R18)
# ---------------------------------------------------------------------------

@test "promotion is refused when staging holds no gateway.yaml, and no version directory appears" {
    make_tarball "$FAKE_CURL_TARBALL" --no-config

    run_acquire
    [ "$RC" -ne 0 ]
    assert_one_json
    [ "$(jq -r '.ok' "$OUT")" = "false" ]
    jq -e '.error | test("config")' "$OUT" >/dev/null

    # The path really did run (not a vacuous "nothing happened") ...
    [ "$(cargo_calls)" -eq 1 ]
    # ... and still nothing became visible to the glob, and staging is gone.
    [ -z "$(glob_dirs)" ]
    [ -z "$(staging_dirs)" ]
}

@test "the promotion guard is INDEPENDENT: with the config staging step disabled, promotion still refuses" {
    # Two guards stand between a config-less build and the glob: stage_config
    # fails to find a template, and promote refuses a staged tree without one.
    # A single test cannot tell a redundant guard from an absent one — mutating
    # the FIRST one open and re-running the same scenario is what proves the
    # second is real rather than decorative (G3).
    make_tarball "$FAKE_CURL_TARBALL" --no-config
    local script
    script="$(mutant 's|^    return 1  # no template found$|    return 0  # MUTATED|')"
    grep -rq 'return 0  # MUTATED' "$(dirname "$script")"

    run_acquire "$script"
    [ "$RC" -ne 0 ]
    assert_one_json
    jq -e '.error | test("promote")' "$OUT" >/dev/null
    [ "$(cargo_calls)" -eq 1 ]
    [ -z "$(glob_dirs)" ]
    [ -z "$(staging_dirs)" ]
}

@test "a failed build removes staging by trap and creates no version directory" {
    export FAKE_CARGO_MODE=fail

    run_acquire
    [ "$RC" -eq 3 ]
    assert_one_json
    jq -e '.error | test("build")' "$OUT" >/dev/null

    [ "$(cargo_calls)" -eq 1 ]
    [ -z "$(glob_dirs)" ]
    [ -z "$(staging_dirs)" ]
}

@test "a failed download fails with a named step, one JSON object, and no staging left" {
    export FAKE_CURL_MODE=fail_download

    run_acquire
    [ "$RC" -eq 3 ]
    assert_one_json
    jq -e '.error | test("fetch")' "$OUT" >/dev/null
    [ "$(cargo_calls)" -eq 0 ]
    [ -z "$(staging_dirs)" ]
}

@test "an unusable release lookup fails before anything is created" {
    export FAKE_CURL_MODE=bad_release_json

    run_acquire
    [ "$RC" -eq 3 ]
    assert_one_json
    jq -e '.error | test("tag_name")' "$OUT" >/dev/null
    [ -z "$(staging_dirs)" ]
    [ -z "$(glob_dirs)" ]
}

# ---------------------------------------------------------------------------
# Prerequisites (R4)
# ---------------------------------------------------------------------------

@test "a missing cargo exits 9 naming cargo, before a single network call" {
    export SPAWN_CARGO_BIN="$WORK/no-such-cargo"

    run_acquire
    [ "$RC" -eq 9 ]
    assert_one_json
    jq -e '.error | test("cargo")' "$OUT" >/dev/null

    # The point of checking first: nothing was fetched, nothing was created.
    [ ! -f "$FAKE_CURL_RECORD_DIR/urls" ]
    [ -z "$(staging_dirs)" ]
}

@test "a missing curl exits 9 naming curl" {
    export SPAWN_CURL_BIN="$WORK/no-such-curl"

    run_acquire
    [ "$RC" -eq 9 ]
    jq -e '.error | test("curl")' "$OUT" >/dev/null
}

@test "G3 self-test: checking prerequisites AFTER the fetch makes the zero-network assertion go red" {
    export SPAWN_CARGO_BIN="$WORK/no-such-cargo"
    # Mutate the CODE: the prerequisite gate moves behind the release lookup,
    # which is the ordering R4 forbids.
    local script
    script="$(mutant 's|^    need_prereqs$|    resolve_latest_tag; need_prereqs|')"
    grep -rq 'resolve_latest_tag; need_prereqs' "$(dirname "$script")"

    run_acquire "$script"
    [ "$RC" -eq 9 ]
    # RED: the network call the original test proves absent has now happened.
    [ -f "$FAKE_CURL_RECORD_DIR/urls" ]
    [ "$(curl_calls)" -ge 1 ]
}

# ---------------------------------------------------------------------------
# Skip and rebuild (R3, F2)
# ---------------------------------------------------------------------------

@test "an install matching the latest tag whose binary runs is skipped after ONE network call" {
    make_install "$DEST"

    run_acquire
    [ "$RC" -eq 0 ]
    assert_one_json
    [ "$(jq -r '.action' "$OUT")" = "skipped" ]

    # Exactly the tag lookup: no commit lookup, no download, no build.
    [ "$(curl_calls)" -eq 1 ]
    curl_urls | grep -q 'releases/latest'
    [ "$(cargo_calls)" -eq 0 ]
    [ -z "$(staging_dirs)" ]
}

@test "an install matching the latest tag whose binary does NOT run is rebuilt, not skipped" {
    make_install "$DEST" broken
    # Proof the precondition is real: the resolver would accept this binary as
    # present, so "present" cannot be the test.
    [ -x "$DEST/target/release/gateway" ]
    run "$DEST/target/release/gateway" --version
    [ "$status" -ne 0 ]

    run_acquire
    [ "$RC" -eq 0 ]
    [ "$(jq -r '.action' "$OUT")" = "installed" ]
    [ "$(cargo_calls)" -eq 1 ]

    # The rebuild REPLACED the directory rather than nesting inside it: a bare
    # `mv staging dest` onto an existing directory produces
    # gateway-9.9.9/.gateway-staging.XXXX and an install that looks untouched.
    [ -z "$(find "$DEST" -maxdepth 1 -name '.gateway-staging.*' 2>/dev/null)" ]
    [ -z "$(find "$SPAWN_SEARCH_ROOT" -maxdepth 1 -name '.gateway-replaced.*' 2>/dev/null)" ]
    run "$DEST/target/release/gateway" --version
    [ "$status" -eq 0 ]
    [ -f "$DEST/gateway.yaml" ]
    # ...and the working install is the ONE thing the glob matches.
    [ "$(glob_dirs)" = "$DEST" ]
}

@test "an install matching the latest tag with no config is rebuilt rather than skipped" {
    make_install "$DEST"
    rm -f "$DEST/gateway.yaml"

    run_acquire
    [ "$RC" -eq 0 ]
    [ "$(jq -r '.action' "$OUT")" = "installed" ]
    [ -f "$DEST/gateway.yaml" ]
}

# ---------------------------------------------------------------------------
# Contract and drift
# ---------------------------------------------------------------------------

@test "an unknown verb still prints exactly one JSON object, on stdout" {
    rm -f "$OUT" "$ERR"
    RC=0
    bash "$SETUP" frobnicate >"$OUT" 2>"$ERR" || RC=$?
    [ "$RC" -eq 2 ]
    assert_one_json
    [ "$(jq -r '.ok' "$OUT")" = "false" ]
    # The usage text went to stderr, where diagnostics belong.
    grep -q 'usage: setup.sh' "$ERR"
}

