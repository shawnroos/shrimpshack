#!/usr/bin/env bats
# U5 — the gw rewrite.
#
# What this file is about: `setup.sh gw` turns ~/.local/bin/gw into a wrapper
# that keeps its six verbs and its three shared state paths, delegates its
# control verbs to the plugin instead of reimplementing them, reads its token
# from the Keychain at run time — and refuses to touch a wrapper it did not
# write until the operator says so.
#
# FALSE-GREEN TRAPS IT IS WRITTEN AGAINST
#   1. "the emitted file has no token" is vacuously true of an empty file, a
#      truncated one, or one that was never written. Every credential assertion
#      is paired with a functional one: the wrapper is RUN, and the token it
#      hands Claude Code is read back out of a fake Keychain.
#   2. "it asked for consent" is vacuously true of a run that failed earlier for
#      an unrelated reason. The consent tests assert the exit code, the JSON's
#      consent_required field, AND that the file is byte-identical afterwards.
#   3. A delegation that reads correct and is never reached. `gw start` is run
#      against a recording stand-in for spawnctl.sh, and the record is the proof.
#
# NO REAL CREDENTIAL IS USED OR NEEDED. Every token below is a short synthetic
# string with no credential-shaped prefix — the repo-wide secret scan in
# run-tests.sh reads this file too. The whole point of R23 is that the emitted
# wrapper carries no literal at all.

setup() {
    FIX="$(cd "$BATS_TEST_DIRNAME/../fixtures" && pwd)"
    LIB="$(cd "$BATS_TEST_DIRNAME/../../lib" && pwd)"
    PLUGIN="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SETUP="$LIB/setup.sh"
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/gw-wrap.XXXXXX")"
    WORK="$(cd "$WORK" && pwd -P)"

    # THE SAFETY RAIL. Every run in this file writes here and nowhere else; the
    # operator's real ~/.local/bin/gw is rewritten once, by hand, during the
    # live smoke — never by a suite.
    export SPAWN_GW_PATH="$WORK/bin/gw"

    # The delegation target, faked so "did it delegate?" is answerable.
    export SPAWN_SPAWNCTL_PATH="$WORK/fake-spawnctl.sh"
    CTL_RECORD="$WORK/ctl-argv"
    cat > "$SPAWN_SPAWNCTL_PATH" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CTL_RECORD"
case "${1:-}" in
  ensure) printf '{"ok":true,"verb":"ensure","base_url":"%s","error":null,"exit_code":0}\n' "$FAKE_BASE_URL" ;;
  *)      printf '{"ok":true,"verb":"%s","error":null,"exit_code":0}\n' "$1" ;;
esac
exit 0
EOS
    chmod +x "$SPAWN_SPAWNCTL_PATH"
    export CTL_RECORD
    export FAKE_BASE_URL="http://127.0.0.1:4321/anthropic"

    # Keychain seam (U1's fixture). Nothing here may reach the login keychain.
    export SPAWN_SECURITY_BIN="$FIX/fake-security.sh"
    export FAKE_SECURITY_STORE_DIR="$WORK/kc-store"
    export FAKE_SECURITY_RECORD_DIR="$WORK/kc-record"
    mkdir -p "$FAKE_SECURITY_STORE_DIR" "$FAKE_SECURITY_RECORD_DIR"
    export FAKE_SECURITY_MODE=ok
    export SPAWN_KEYCHAIN_SERVICE="spawn-gateway-test"
    export SPAWN_KEYCHAIN_ACCOUNT_TOKEN="gateway-token"
    unset GATEWAY_TOKEN OPENROUTER_API_KEY

    # State paths pointed at the sandbox: a `gw log` under test must not read
    # the operator's real ~/.gateway.log.
    export SPAWN_STATE_HOME="$WORK/state"
    mkdir -p "$SPAWN_STATE_HOME"

    STORED_TOKEN="stored-tok-a1b2c3"
    seed_keychain gateway-token "$STORED_TOKEN"

    # A fake `claude` on PATH, so the wrapper's last line is exercised rather
    # than read. It records the two env values it was handed.
    mkdir -p "$WORK/bin"
    CLAUDE_RECORD="$WORK/claude-env"
    export CLAUDE_RECORD
    cat > "$WORK/bin/claude" <<'EOS'
#!/usr/bin/env bash
{
    printf 'base=%s\n' "${ANTHROPIC_BASE_URL:-}"
    printf 'token=%s\n' "${ANTHROPIC_AUTH_TOKEN:-}"
    printf 'args=%s\n' "$*"
} >> "$CLAUDE_RECORD"
exit 0
EOS
    chmod +x "$WORK/bin/claude"
    PATH="$WORK/bin:$PATH"
    export PATH

    OUT="$WORK/out.json"
    ERR="$WORK/err.txt"
    RC=0
}

teardown() {
    rm -rf "$WORK"
    return 0
}

# --- helpers ---------------------------------------------------------------

seed_keychain() {
    printf '%s\n%s\n' "$2" "$2" \
        | "$SPAWN_SECURITY_BIN" add-generic-password -a "$1" -s "$SPAWN_KEYCHAIN_SERVICE" -U -w
}

run_gw() {   # run_gw [--script <path>] [flags...]
    local script="$SETUP"
    if [ "${1:-}" = "--script" ]; then script="$2"; shift 2; fi
    rm -f "$OUT" "$ERR"
    RC=0
    bash "$script" gw "$@" >"$OUT" 2>"$ERR" || RC=$?
    return 0
}

assert_one_json() {
    [ -s "$OUT" ]
    [ "$(grep -c . "$OUT")" -eq 1 ]
    jq -e . "$OUT" >/dev/null
    jq -e 'has("ok") and has("error") and has("exit_code")' "$OUT" >/dev/null
}

sha_of() { shasum -a 256 "$1" | awk '{print $1}'; }

# The generated wrapper's own recognition header, recomputed independently of
# the code under test: the marker, then a hash over everything below the hash
# line. A generator that wrote a hash of the wrong bytes would pass a
# "the hash line exists" check and fail this one.
assert_marker_and_hash() {
    local f="$1" declared actual
    grep -qF '# spawn-setup: generated wrapper' "$f"
    declared="$(awk '/^# spawn-setup-body-sha256: / { print $3; exit }' "$f")"
    [ -n "$declared" ]
    actual="$(awk 'seen { print } /^# spawn-setup-body-sha256: / { seen = 1 }' "$f" | shasum -a 256 | awk '{print $1}')"
    [ "$declared" = "$actual" ]
}

# A wrapper in the shape the real machine's is in TODAY: no marker, and a token
# literal on two lines. The literal here is synthetic — setup never reads the
# old value, it deletes it.
FIXTURE_LITERAL="fixture-tok-r7r7"
plant_markerless_gw() {
    mkdir -p "$(dirname "$SPAWN_GW_PATH")"
    cat > "$SPAWN_GW_PATH" <<EOF
#!/usr/bin/env bash
# gw — hand-rolled gateway control
TOKEN="$FIXTURE_LITERAL"
case "\${1:-status}" in
  start) echo start ;;
  claude) ANTHROPIC_AUTH_TOKEN="$FIXTURE_LITERAL" claude "\$@" ;;
esac
EOF
    chmod +x "$SPAWN_GW_PATH"
}

# mutant <file> <sed-expression> — a copy of the whole lib with ONE script
# mutated (the scripts source each other relative to their own location).
# Prints the mutated script's path.
mutant() {
    local file="$1" expr="$2" dir="$WORK/mutlib"
    rm -rf "$dir"
    mkdir -p "$dir"
    cp "$LIB"/*.sh "$dir/"
    [ -f "$LIB/models.json" ] && cp "$LIB/models.json" "$dir/"
    sed -i '' "$expr" "$dir"/*.sh
    printf '%s' "$dir/$file"
}

# --- KTD11's recognition matrix --------------------------------------------

@test "R19: a machine with no gw gets one written, with a marker and a matching hash" {
    [ ! -e "$SPAWN_GW_PATH" ]

    run_gw
    [ "$RC" -eq 0 ]
    assert_one_json
    [ "$(jq -r '.action' "$OUT")" = "created" ]
    [ "$(jq -r '.state_before' "$OUT")" = "absent" ]

    [ -x "$SPAWN_GW_PATH" ]
    assert_marker_and_hash "$SPAWN_GW_PATH"
    bash -n "$SPAWN_GW_PATH"
}

@test "KTD11: a wrapper setup wrote, unedited, is rewritten with no consent and no exit 8" {
    run_gw
    [ "$RC" -eq 0 ]
    local first
    first="$(sha_of "$SPAWN_GW_PATH")"

    run_gw
    [ "$RC" -eq 0 ]
    assert_one_json
    [ "$(jq -r '.state_before' "$OUT")" = "generated" ]
    [ "$(jq -r '.action' "$OUT")" = "rewritten" ]
    # The generator is deterministic, so a clean re-run reproduces the file —
    # which is also what makes the hash a usable recognition key.
    [ "$(sha_of "$SPAWN_GW_PATH")" = "$first" ]
}

@test "AE6/R20: a hand-edited wrapper (marker, wrong hash) exits 8 and is left byte-identical" {
    run_gw
    [ "$RC" -eq 0 ]
    printf '\n# the operator added this line\n' >> "$SPAWN_GW_PATH"
    local before
    before="$(sha_of "$SPAWN_GW_PATH")"

    run_gw
    [ "$RC" -eq 8 ]
    assert_one_json
    [ "$(jq -r '.ok' "$OUT")" = "false" ]
    [ "$(jq -r '.consent_required' "$OUT")" = "overwrite-gw" ]
    [ "$(jq -r '.state_before' "$OUT")" = "modified" ]
    jq -e '.path | test("/gw$")' "$OUT" >/dev/null

    # Refusing means touching NOTHING — including leaving no temp file behind.
    [ "$(sha_of "$SPAWN_GW_PATH")" = "$before" ]
    grep -qF '# the operator added this line' "$SPAWN_GW_PATH"
    [ -z "$(find "$(dirname "$SPAWN_GW_PATH")" -maxdepth 1 -name 'gw.spawn-setup.*' 2>/dev/null)" ]
}

@test "R20/R23: the markerless wrapper (this machine's shape) exits 8, then consent rewrites it and the old literal is gone" {
    plant_markerless_gw
    local before
    before="$(sha_of "$SPAWN_GW_PATH")"
    # Guard the guard: the literal really is in there first, or "it is gone" is
    # a statement about an empty search.
    grep -qF -- "$FIXTURE_LITERAL" "$SPAWN_GW_PATH"

    run_gw
    [ "$RC" -eq 8 ]
    assert_one_json
    [ "$(jq -r '.state_before' "$OUT")" = "foreign" ]
    [ "$(jq -r '.consent_required' "$OUT")" = "overwrite-gw" ]
    [ "$(sha_of "$SPAWN_GW_PATH")" = "$before" ]

    run_gw --consent-overwrite-gw
    [ "$RC" -eq 0 ]
    assert_one_json
    [ "$(jq -r '.action' "$OUT")" = "rewritten" ]
    [ "$(jq -r '.state_before' "$OUT")" = "foreign" ]
    assert_marker_and_hash "$SPAWN_GW_PATH"

    # R23: the retired literal is gone from the wrapper, and setup never read it
    # — so it is not in the emitted object or the diagnostics either.
    run grep -F -- "$FIXTURE_LITERAL" "$SPAWN_GW_PATH" "$OUT" "$ERR"
    [ "$status" -ne 0 ]
}

# --- KTD14: the six verbs, the three shared paths, and the delegation --------

@test "R19: all six verbs and the three shared state paths survive the rewrite" {
    run_gw
    [ "$RC" -eq 0 ]

    # The verb line itself, not six loose mentions in a comment.
    grep -qE '^ *start\|stop\|restart\|status\)' "$SPAWN_GW_PATH"
    grep -qE '^ *log\)' "$SPAWN_GW_PATH"
    grep -qE '^ *claude\)' "$SPAWN_GW_PATH"
    # The bare-invocation default is part of the surface that is in muscle memory.
    grep -qF 'case "${1:-status}" in' "$SPAWN_GW_PATH"

    # KTD4 of the plugin plan: the same three paths, so the two control surfaces
    # never double-start against each other.
    grep -qF '.gateway.pid' "$SPAWN_GW_PATH"
    grep -qF '.gateway.log' "$SPAWN_GW_PATH"
    grep -qF '.gateway.lock' "$SPAWN_GW_PATH"
}

@test "KTD14: gw start delegates to the baked spawnctl, and gw log does not" {
    run_gw
    [ "$RC" -eq 0 ]
    # The delegation target is baked ABSOLUTE, not looked up on PATH.
    grep -qF "SPAWNCTL=\"$SPAWN_SPAWNCTL_PATH\"" "$SPAWN_GW_PATH"

    run bash "$SPAWN_GW_PATH" start
    [ "$status" -eq 0 ]
    grep -qx 'start' "$CTL_RECORD"

    run bash "$SPAWN_GW_PATH" stop
    [ "$status" -eq 0 ]
    grep -qx 'stop' "$CTL_RECORD"

    # `log` is local: with no log file yet it says so and exits, without ever
    # reaching the control layer.
    rm -f "$CTL_RECORD"
    run bash "$SPAWN_GW_PATH" log
    [ "$status" -eq 0 ]
    [ ! -f "$CTL_RECORD" ]
    # ...and the follow path is a plain tail of the shared log.
    grep -qF 'tail -f "$LOGFILE"' "$SPAWN_GW_PATH"
}

@test "KTD14/R23: gw claude resolves the token from the Keychain at RUN time, and no value is in the file" {
    run_gw
    [ "$RC" -eq 0 ]

    # By reference, in the file text: a Keychain read, no literal.
    grep -qF 'find-generic-password' "$SPAWN_GW_PATH"
    run grep -F -- "$STORED_TOKEN" "$SPAWN_GW_PATH"
    [ "$status" -ne 0 ]

    # ...and functionally: run it, and read back what Claude Code was handed.
    run bash "$SPAWN_GW_PATH" claude --model kimi
    [ "$status" -eq 0 ]
    grep -qx "base=$FAKE_BASE_URL" "$CLAUDE_RECORD"
    grep -qx "token=$STORED_TOKEN" "$CLAUDE_RECORD"
    grep -qx 'args=--model kimi' "$CLAUDE_RECORD"
    # The base url came from the control layer rather than a baked port.
    grep -qx 'ensure' "$CTL_RECORD"
}

@test "R23: gw claude refuses when nothing is stored, rather than launching unauthenticated" {
    run_gw
    [ "$RC" -eq 0 ]
    "$SPAWN_SECURITY_BIN" delete-generic-password \
        -a gateway-token -s "$SPAWN_KEYCHAIN_SERVICE" >/dev/null 2>&1

    run bash "$SPAWN_GW_PATH" claude
    [ "$status" -eq 9 ]
    [ ! -f "$CLAUDE_RECORD" ]
}

# --- R10: neither the template nor an emitted sample carries a credential ----

@test "R10: the generator's template and an emitted wrapper both pass the credential-prefix scan" {
    run_gw
    [ "$RC" -eq 0 ]
    # Layer 2 of run-tests.sh's secret scan, applied to both the source of the
    # emitted text and the emitted text itself.
    local pat='sk-ant-[A-Za-z0-9_-]{16,}|sk-or-v1-[A-Za-z0-9]{16,}|sk-[A-Za-z0-9]{32,}|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{30,}|xox[baprs]-[A-Za-z0-9-]{10,}|-----BEGIN [A-Z ]*PRIVATE KEY-----'
    run grep -nEo "$pat" "$SETUP"
    [ "$status" -ne 0 ]
    run grep -nEo "$pat" "$SPAWN_GW_PATH"
    [ "$status" -ne 0 ]

    # And the broader claim R23 rests on: no assignment of an auth env var to a
    # literal anywhere in the emitted file — every value is a reference.
    run grep -nE 'ANTHROPIC_AUTH_TOKEN=("?[A-Za-z0-9_-]{8,})' "$SPAWN_GW_PATH"
    [ "$status" -ne 0 ]
}

# --- KTD7: the shipped text no longer contradicts the rewrite ---------------

@test "KTD7: no shipped surface still claims the plugin leaves gw untouched" {
    # Scope is the SHIPPED surfaces. tests/ is excluded because this very file
    # has to name the phrases in order to search for them.
    #
    # Each path is asserted to EXIST first. A grep over a path that is not there
    # exits non-zero for the wrong reason, and this assertion would then pass on
    # a plugin whose every claim was still false.
    local p
    for p in README.md .claude-plugin skills commands; do
        [ -e "$PLUGIN/$p" ]
    done
    run grep -rniE 'leaves (it|the existing gw wrapper|gw) (untouched|alone)|unrelated binary|gw wrapper untouched' \
        "$PLUGIN/README.md" "$PLUGIN/.claude-plugin" "$PLUGIN/skills" "$PLUGIN/commands"
    if [ "$status" -eq 0 ]; then
        printf 'still claimed:\n%s\n' "$output" >&2
    fi
    [ "$status" -ne 0 ]
}

# --- G3: the assertions are proven by mutating the code ---------------------

@test "G3 self-test: a generator that bakes the stored token makes the credential-free assertion go red" {
    # The defect this suite exists to catch: the wrapper's convenience wins and
    # the token is resolved at WRITE time into the emitted text — which is
    # exactly the shape the file being replaced had.
    local script
    script="$(mutant setup.sh 's|^# credentials are NEVER baked into this file.*|ANTHROPIC_AUTH_TOKEN="$(spawn::keychain_read "$KEYCHAIN_SERVICE" "$KEYCHAIN_ACCOUNT_TOKEN")"|')"
    grep -rq 'ANTHROPIC_AUTH_TOKEN="\$(spawn::keychain_read' "$(dirname "$script")"

    run_gw --script "$script"
    [ "$RC" -eq 0 ]
    # The mutation is live: the literal really is in the emitted wrapper...
    grep -qF -- "$STORED_TOKEN" "$SPAWN_GW_PATH"
    # ...so the assertion the healthy suite makes is now false.
    run grep -F -- "$STORED_TOKEN" "$SPAWN_GW_PATH"
    [ "$status" -eq 0 ]
}

@test "G3 self-test: recognition that ignores a hash MISMATCH makes AE6's assertion go red" {
    # The other half of the recognition matrix, and AE6's exact case: the marker
    # is there, so only the hash can tell a wrapper setup wrote from one the
    # operator has since edited. With the mismatch arm answering "generated",
    # their edit is silently discarded.
    local script
    script="$(mutant setup.sh 's|        GW_STATE="modified"|        GW_STATE="generated"|')"
    grep -rq 'GW_STATE="generated"$' "$(dirname "$script")"

    run_gw
    [ "$RC" -eq 0 ]
    printf '\n# the operator added this line\n' >> "$SPAWN_GW_PATH"
    local before
    before="$(sha_of "$SPAWN_GW_PATH")"

    run_gw --script "$script"
    [ "$RC" -eq 0 ]
    [ "$(sha_of "$SPAWN_GW_PATH")" != "$before" ]
    run grep -qF '# the operator added this line' "$SPAWN_GW_PATH"
    [ "$status" -ne 0 ]
}

@test "G3 self-test: recognition that accepts a markerless wrapper makes the consent assertion go red" {
    local script
    script="$(mutant setup.sh 's|GW_STATE="foreign"; return 0|GW_STATE="generated"; return 0|')"
    grep -rq 'GW_STATE="generated"; return 0; }' "$(dirname "$script")"

    plant_markerless_gw
    local before
    before="$(sha_of "$SPAWN_GW_PATH")"

    run_gw --script "$script"
    # Healthy behaviour is exit 8 with the file untouched. With recognition
    # broken, the operator's wrapper is overwritten without being asked.
    [ "$RC" -eq 0 ]
    [ "$(sha_of "$SPAWN_GW_PATH")" != "$before" ]
    run grep -F -- "$FIXTURE_LITERAL" "$SPAWN_GW_PATH"
    [ "$status" -ne 0 ]
}
