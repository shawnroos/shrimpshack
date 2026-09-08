#!/usr/bin/env bats
# U4 — config migration and token retirement.
#
# What this file is about: after setup runs, the promoted gateway.yaml carries
# NO token entry of any shape, the operator's own config survives forward
# byte-for-byte otherwise, and every plugin command can still authenticate
# against the gateway that config describes.
#
# THREE FALSE-GREEN TRAPS IT IS WRITTEN AGAINST
#   1. "the token is gone" is vacuously true of a config that was regenerated,
#      truncated, or never written at all. Every migration assertion below is a
#      BYTE DIFF against a hand-written expected file — the deletion and the
#      preservation are one assertion, so neither can pass alone.
#   2. "no token line" is also vacuously true if the strip removed the whole
#      server block. The expected files keep `bind:` and the commented token
#      shapes, so an over-broad strip is as red as an absent one.
#   3. A migration that reads correct but is never REACHED. The acquire path
#      runs end-to-end through the seams here, and every assertion about the
#      promoted tree is paired with proof the path ran (a recorded build, or an
#      action:"skipped" that names the branch taken).
#
# NO REAL SECRET IS USED OR NEEDED. Retirement is deletion: setup never reads
# the old literal, so the fixtures' "tokens" are short synthetic strings chosen
# to carry no credential-shaped prefix — the repo-wide secret scan in
# run-tests.sh reads this file too.

setup() {
    FIX="$(cd "$BATS_TEST_DIRNAME/../fixtures" && pwd)"
    LIB="$(cd "$BATS_TEST_DIRNAME/../../lib" && pwd)"
    SETUP="$LIB/setup.sh"
    CTL="$LIB/spawnctl.sh"
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/gw-cfg.XXXXXX")"
    WORK="$(cd "$WORK" && pwd -P)"
    . "$BATS_TEST_DIRNAME/../lib/sweep.bash"
    GW_PID=""

    export SPAWN_SEARCH_ROOT="$WORK/root"
    mkdir -p "$SPAWN_SEARCH_ROOT"
    export SPAWN_STATE_HOME="$WORK"
    export SPAWN_BASE_URL="http://127.0.0.1:1/anthropic"
    export SPAWN_CONNECT_TIMEOUT=2
    export SPAWN_PROBE_TIMEOUT=5
    export SPAWN_START_TIMEOUT=10
    unset SPAWN_INSTALL_DIR SPAWN_CONFIG SPAWN_MODELS_JSON

    # Fetch and build seams (U2's fixtures).
    export SPAWN_CURL_BIN="$FIX/fake-curl.sh"
    export SPAWN_CARGO_BIN="$FIX/fake-cargo.sh"
    export FAKE_CURL_RECORD_DIR="$WORK/rec-curl"
    export FAKE_CARGO_RECORD_DIR="$WORK/rec-cargo"
    export FAKE_CURL_MODE=ok
    export FAKE_CARGO_MODE=ok
    export FAKE_CURL_TAG="v9.9.9"
    export FAKE_CURL_SHA="abc1234abc1234abc1234abc1234abc1234abc12"
    export FAKE_CURL_TARBALL="$WORK/src.tar.gz"

    # Keychain seam (U1's fixture). Setup's R9 gate and spawnctl's R27 fallback
    # both consult it, so no test in this file may reach the login keychain.
    export SPAWN_SECURITY_BIN="$FIX/fake-security.sh"
    export FAKE_SECURITY_STORE_DIR="$WORK/kc-store"
    export FAKE_SECURITY_RECORD_DIR="$WORK/kc-record"
    mkdir -p "$FAKE_SECURITY_STORE_DIR" "$FAKE_SECURITY_RECORD_DIR"
    export SPAWN_KEYCHAIN_SERVICE="spawn-gateway-test"
    export FAKE_SECURITY_MODE=ok
    # An operator with their own token exported would otherwise decide the
    # precedence assertions for us.
    unset OPENROUTER_API_KEY GATEWAY_TOKEN

    DEST="$SPAWN_SEARCH_ROOT/gateway-9.9.9"
    OLD="$SPAWN_SEARCH_ROOT/gateway-0.1.0"
    STORED_TOKEN="stored-tok-a1b2c3"

    OUT="$WORK/out.json"
    ERR="$WORK/err.txt"
    RC=0

    make_tarball
    seed_keychain gateway-token "$STORED_TOKEN"
}

teardown() {
    if [ -n "${GW_PID:-}" ]; then
        kill "$GW_PID" 2>/dev/null || true
        wait "$GW_PID" 2>/dev/null || true
    fi
    local p
    sweep_work
    rm -rf "$WORK"
    return 0
}

# --- helpers ---------------------------------------------------------------

seed_keychain() {
    printf '%s\n%s\n' "$2" "$2" \
        | "$SPAWN_SECURITY_BIN" add-generic-password -a "$1" -s "$SPAWN_KEYCHAIN_SERVICE" -U -w
}

# The upstream template, reproduced in the shape that matters: an ACTIVE token
# line followed by the two COMMENTED alternatives. Both halves are load-bearing
# — the active line is what must go, the comments are what must stay.
template_config() {
    cat <<'EOF'
# gateway.yaml
server:
  bind: "127.0.0.1:4000"        # default; non-localhost requires a token
  token: upstream-shipped-tok   # accepted as Bearer or x-api-key
  # tokens: [token-a, token-b]  # multiple tokens
  # token: "${GATEWAY_TOKEN}"   # or from the environment

models:
  alpha:
    model: openrouter/alpha
EOF
}

# make_tarball — a real gzipped tar in GitHub's shape, carrying the template
# above at the repo root. Real rather than stubbed so --strip-components=1 is
# actually exercised.
make_tarball() {
    local src="$WORK/tarsrc" root
    rm -rf "$src"
    root="$src/superagent-ai-gateway-abc1234"
    mkdir -p "$root/src"
    printf '[package]\nname = "gateway"\nversion = "9.9.9"\n' > "$root/Cargo.toml"
    printf 'fn main() {}\n' > "$root/src/main.rs"
    template_config > "$root/gateway.yaml"
    tar czf "$FAKE_CURL_TARBALL" -C "$src" superagent-ai-gateway-abc1234
    rm -rf "$src"
}

# make_install <dir> — a complete, runnable install. Its gateway.yaml is
# written by the caller.
make_install() {
    local dir="$1"
    mkdir -p "$dir/target/release"
    cat > "$dir/target/release/gateway" <<'EOS'
#!/usr/bin/env bash
case "${1:-}" in
  --version) printf 'gateway (fixture install)\n' ;;
  *)         printf 'fixture install binary\n' ;;
esac
exit 0
EOS
    chmod +x "$dir/target/release/gateway"
}

run_acquire() {
    local script="${1:-$SETUP}"
    rm -f "$OUT" "$ERR"
    RC=0
    bash "$script" acquire >"$OUT" 2>"$ERR" || RC=$?
    return 0
}

assert_one_json() {
    [ -s "$OUT" ]
    [ "$(grep -c . "$OUT")" -eq 1 ]
    jq -e . "$OUT" >/dev/null
    jq -e 'has("ok") and has("error") and has("exit_code")' "$OUT" >/dev/null
}

cargo_calls() { grep -c -- '--- invocation ---' "$FAKE_CARGO_RECORD_DIR/argv" 2>/dev/null || printf '0'; }

staging_dirs() { find "$SPAWN_SEARCH_ROOT" -maxdepth 1 -name '.gateway-staging.*' 2>/dev/null; }

# mutant <file> <sed-expression> — a copy of the whole lib with ONE script
# mutated (the directory is copied whole because the scripts source each other
# relative to their own location). Prints the mutated script's path.
mutant() {
    local file="$1" expr="$2" dir="$WORK/mutlib"
    rm -rf "$dir"
    mkdir -p "$dir"
    cp "$LIB"/*.sh "$dir/"
    [ -f "$LIB/models.json" ] && cp "$LIB/models.json" "$dir/"
    sed -i '' "$expr" "$dir"/*.sh
    printf '%s' "$dir/$file"
}

# migrate_and_diff <previous-config-file> <expected-file> — plant the previous
# install carrying <previous-config-file>, acquire, and assert the promoted
# config is byte-identical to <expected-file>.
migrate_and_diff() {
    local prev="$1" expected="$2"
    make_install "$OLD"
    cp "$prev" "$OLD/gateway.yaml"

    run_acquire
    [ "$RC" -eq 0 ]
    assert_one_json
    [ "$(jq -r '.action' "$OUT")" = "installed" ]
    # Proof the path RAN rather than short-circuiting somewhere harmless.
    [ "$(cargo_calls)" -eq 1 ]
    [ -f "$DEST/gateway.yaml" ]

    if ! diff -u "$expected" "$DEST/gateway.yaml"; then
        printf 'migrated config differs from expected (above)\n' >&2
        return 1
    fi
}

# --- the three token shapes ------------------------------------------------

@test "R23: a literal server.token is removed and every other line survives byte-identical" {
    cat > "$WORK/prev.yaml" <<'EOF'
# my gateway
server:
  bind: "127.0.0.1:4000"
  token: prev-literal-tok-9z        # trailing comment
  # tokens: [token-a, token-b]

models:
  mine:
    model: openrouter/mine
    display_name: "Mine"
EOF
    cat > "$WORK/expected.yaml" <<'EOF'
# my gateway
server:
  bind: "127.0.0.1:4000"
  # tokens: [token-a, token-b]

models:
  mine:
    model: openrouter/mine
    display_name: "Mine"
EOF
    migrate_and_diff "$WORK/prev.yaml" "$WORK/expected.yaml"
}

@test "R23: the server.tokens BLOCK-list form is removed, list items and all" {
    cat > "$WORK/prev.yaml" <<'EOF'
server:
  bind: "127.0.0.1:4000"
  tokens:
    - prev-list-tok-one
    - prev-list-tok-two
  timeout: 30

models:
  mine:
    model: openrouter/mine
EOF
    cat > "$WORK/expected.yaml" <<'EOF'
server:
  bind: "127.0.0.1:4000"
  timeout: 30

models:
  mine:
    model: openrouter/mine
EOF
    migrate_and_diff "$WORK/prev.yaml" "$WORK/expected.yaml"
}

@test "R23: the server.tokens FLOW-list form is removed" {
    cat > "$WORK/prev.yaml" <<'EOF'
server:
  bind: "127.0.0.1:4000"
  tokens: [prev-flow-tok-a, prev-flow-tok-b]

models:
  mine:
    model: openrouter/mine
EOF
    cat > "$WORK/expected.yaml" <<'EOF'
server:
  bind: "127.0.0.1:4000"

models:
  mine:
    model: openrouter/mine
EOF
    migrate_and_diff "$WORK/prev.yaml" "$WORK/expected.yaml"
}

@test "KD5: a \${GATEWAY_TOKEN} REFERENCE is removed too — delivery replaces it" {
    # The reference shape looks harmless and is not. KD5 settles that the token
    # arrives as an environment variable the gateway merges into its auth list,
    # so a config reference is a second, silently-drifting source of the same
    # value — and one that reads as "configured" while resolving to empty in
    # any shell that lacks the export.
    cat > "$WORK/prev.yaml" <<'EOF'
server:
  bind: "127.0.0.1:4000"
  token: "${GATEWAY_TOKEN}"

models:
  mine:
    model: openrouter/mine
EOF
    cat > "$WORK/expected.yaml" <<'EOF'
server:
  bind: "127.0.0.1:4000"

models:
  mine:
    model: openrouter/mine
EOF
    migrate_and_diff "$WORK/prev.yaml" "$WORK/expected.yaml"
}

@test "R10/R23: the retired literal appears nowhere in staging or the promoted install" {
    local literal="retired-tok-q7w8e9"
    make_install "$OLD"
    cat > "$OLD/gateway.yaml" <<EOF
server:
  bind: "127.0.0.1:4000"
  token: $literal

models:
  mine:
    model: openrouter/mine
EOF
    # Guard the guard: the literal must really be there first, or "it is gone"
    # is a statement about an empty search.
    grep -rqF -- "$literal" "$SPAWN_SEARCH_ROOT"

    run_acquire
    [ "$RC" -eq 0 ]
    [ "$(jq -r '.action' "$OUT")" = "installed" ]

    # Scope, per the plan's scenario: staging and the PROMOTED directory. The
    # previous version's own directory is left exactly as it was — setup
    # promotes a new install, it does not reach back and rewrite an old one.
    [ -z "$(staging_dirs)" ]
    run grep -rF -- "$literal" "$DEST"
    [ "$status" -ne 0 ]
    # Not in the emitted object or the diagnostics either — setup never reads
    # the value, so it has nothing to print.
    run grep -F -- "$literal" "$OUT" "$ERR"
    [ "$status" -ne 0 ]
    [ -z "$(staging_dirs)" ]
}

# --- bare machine ----------------------------------------------------------

@test "bare machine: the upstream template is staged with its ACTIVE token gone and its comments intact" {
    # The upstream template ships an active token line whose placeholder value
    # is published in a public repository (and is what this machine's install is
    # still running on). "The template as shipped" governs where the content
    # comes from, not whether a live token rides along with it.
    [ ! -d "$OLD" ]

    run_acquire
    [ "$RC" -eq 0 ]
    [ "$(jq -r '.action' "$OUT")" = "installed" ]

    local cfg="$DEST/gateway.yaml"
    [ -f "$cfg" ]
    # No ACTIVE token entry of any shape, and no ${VAR} auth reference.
    run grep -nE '^[ \t]+tokens?:' "$cfg"
    [ "$status" -ne 0 ]
    run grep -nE '^[ \t]+token:.*\$\{' "$cfg"
    [ "$status" -ne 0 ]
    run grep -F 'upstream-shipped-tok' "$cfg"
    [ "$status" -ne 0 ]

    # ...and the strip was surgical: the commented shapes and the rest of the
    # template are still there. Without these, deleting the whole file would
    # pass every assertion above.
    grep -qF '# tokens: [token-a, token-b]' "$cfg"
    grep -qF '# token: "${GATEWAY_TOKEN}"' "$cfg"
    grep -qF 'bind: "127.0.0.1:4000"' "$cfg"
    grep -qE '^  alpha:$' "$cfg"
}

# --- R9's static half ------------------------------------------------------

@test "R9: promotion is refused when the config carries no token and none is stored" {
    # The gateway's auth check passes EVERYTHING when its token list is empty,
    # so a token-free config with nothing to deliver is not a locked-down
    # gateway — it is an open proxy to a paid provider. Refused while the
    # staged tree is still invisible to the glob.
    "$SPAWN_SECURITY_BIN" delete-generic-password \
        -a gateway-token -s "$SPAWN_KEYCHAIN_SERVICE" >/dev/null 2>&1

    run_acquire
    [ "$RC" -eq 2 ]
    assert_one_json
    [ "$(jq -r '.ok' "$OUT")" = "false" ]
    jq -e '.error | test("open proxy")' "$OUT" >/dev/null

    # The path really ran (so this is not a vacuous refusal from an earlier
    # step), and nothing became visible to the glob.
    [ "$(cargo_calls)" -eq 1 ]
    [ ! -d "$DEST" ]
    [ -z "$(staging_dirs)" ]
}

@test "R9: with a stored token the same acquire promotes" {
    # The other half of the pair. A refusal test alone cannot distinguish "the
    # gate works" from "acquire is broken for everyone".
    run_acquire
    [ "$RC" -eq 0 ]
    [ "$(jq -r '.action' "$OUT")" = "installed" ]
    [ -f "$DEST/gateway.yaml" ]
}

# --- the skip path ---------------------------------------------------------

@test "R23: an already-installed latest release still has its token retired, in place" {
    # This is the state the machine this requirement was written for is in: the
    # newest release is already installed and its config holds the literal. A
    # skip that skipped retirement too would never satisfy R23 there.
    make_install "$DEST"
    cat > "$DEST/gateway.yaml" <<'EOF'
server:
  bind: "127.0.0.1:4000"
  token: installed-tok-k3k3

models:
  mine:
    model: openrouter/mine
EOF
    cat > "$WORK/expected.yaml" <<'EOF'
server:
  bind: "127.0.0.1:4000"

models:
  mine:
    model: openrouter/mine
EOF

    run_acquire
    [ "$RC" -eq 0 ]
    assert_one_json
    [ "$(jq -r '.action' "$OUT")" = "skipped" ]
    [ "$(cargo_calls)" -eq 0 ]
    diff -u "$WORK/expected.yaml" "$DEST/gateway.yaml"
    run grep -rF -- "installed-tok-k3k3" "$SPAWN_SEARCH_ROOT"
    [ "$status" -ne 0 ]
    # No temp file left beside the config.
    [ -z "$(find "$DEST" -maxdepth 1 -name 'gateway.yaml.retiring.*' 2>/dev/null)" ]
}

@test "R9: the skip path refuses to retire the token when nothing is stored" {
    make_install "$DEST"
    cat > "$DEST/gateway.yaml" <<'EOF'
server:
  bind: "127.0.0.1:4000"
  token: installed-tok-k3k3

models:
  mine:
    model: openrouter/mine
EOF
    "$SPAWN_SECURITY_BIN" delete-generic-password \
        -a gateway-token -s "$SPAWN_KEYCHAIN_SERVICE" >/dev/null 2>&1

    run_acquire
    [ "$RC" -eq 2 ]
    assert_one_json
    jq -e '.error | test("open proxy")' "$OUT" >/dev/null
    # Refusing means LEAVING IT ALONE: a half-retired install that authenticates
    # against nothing is strictly worse than one still holding its literal.
    grep -qF 'token: installed-tok-k3k3' "$DEST/gateway.yaml"
}

# --- G3: the strip is proven by mutating the code --------------------------

@test "G3 self-test: a pass-through strip_server_token makes the migration assertion go red" {
    # A pass-through, not a skip: what has to be load-bearing is the DELETION,
    # not the copy. With the awk replaced by `cat`, the config still arrives in
    # the staged tree — complete, well-formed, and carrying the token.
    local script
    script="$(mutant setup.sh 's|^strip_server_token() {$|strip_server_token() { cp "$1" "$2"; return 0|')"
    grep -rq 'strip_server_token() { cp "$1" "$2"; return 0' "$(dirname "$script")"

    make_install "$OLD"
    cat > "$OLD/gateway.yaml" <<'EOF'
server:
  bind: "127.0.0.1:4000"
  token: mutant-tok-m4m4

models:
  mine:
    model: openrouter/mine
EOF

    run_acquire "$script"
    # The self-check inside stage_config catches the pass-through, so acquire
    # refuses rather than promoting a token-carrying config. Either way the
    # invariant this suite asserts is violated and the run is not green: no
    # promoted install, and the literal is still only in the old one.
    [ "$RC" -ne 0 ]
    [ ! -f "$DEST/gateway.yaml" ]
}

@test "G3 self-test: a strip that deletes the whole server block is caught by the byte diff" {
    # The over-broad mutation, which every "no token line" assertion would
    # happily pass. Only the expected-file diff sees it.
    local script
    script="$(mutant setup.sh 's|.*{ drop = 1; next }|        sec == "server" { next }|')"
    grep -rq 'sec == "server" { next }' "$(dirname "$script")"

    make_install "$OLD"
    cat > "$OLD/gateway.yaml" <<'EOF'
server:
  bind: "127.0.0.1:4000"
  token: mutant-tok-w9w9

models:
  mine:
    model: openrouter/mine
EOF
    cat > "$WORK/expected.yaml" <<'EOF'
server:
  bind: "127.0.0.1:4000"

models:
  mine:
    model: openrouter/mine
EOF

    run_acquire "$script"
    [ "$RC" -eq 0 ]
    run diff -u "$WORK/expected.yaml" "$DEST/gateway.yaml"
    [ "$status" -ne 0 ]
}

# --- R27: the steady state setup leaves behind ------------------------------

start_fixture() {
    local token="$1" portfile="$WORK/port"
    python3 "$FIX/fake-gateway.py" \
        --token "$token" --aliases alpha --scenario healthy \
        --port-file "$portfile" >"$WORK/gw.out" 2>"$WORK/gw.err" &
    GW_PID=$!
    local i
    for i in $(seq 1 100); do
        [ -s "$portfile" ] && break
        sleep 0.05
    done
    PORT="$(cat "$portfile")"
    [ -n "$PORT" ]
    export SPAWN_BASE_URL="http://127.0.0.1:$PORT/anthropic"
}

# A token-less install, exactly the shape setup now leaves behind.
make_retired_install() {
    make_install "$WORK/install"
    cat > "$WORK/install/gateway.yaml" <<'EOF'
server:
  bind: "127.0.0.1:4000"

models:
  alpha:
    model: openrouter/alpha
    display_name: "alpha"
EOF
    export SPAWN_INSTALL_DIR="$WORK/install"
    export SPAWN_CONFIG="$WORK/install/gateway.yaml"
}

@test "R27: status authenticates from the stored credential when the config carries none" {
    # THE GAP U3 LEFT. The Keychain fallback lived inside do_start_locked, so
    # every command that is not `start` resolved an empty token out of a
    # retired config and got 7 from the gateway setup had just configured.
    start_fixture "$STORED_TOKEN"
    make_retired_install

    run bash -c 'bash "$1" status 2>/dev/null' _ "$CTL"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.running')" = "true" ]
    [ "$(echo "$output" | jq -r '.served_aliases|join(",")')" = "alpha" ]
}

@test "R27: lens authenticates from the stored credential too" {
    start_fixture "$STORED_TOKEN"
    make_retired_install

    run bash -c 'bash "$1" ensure alpha 2>/dev/null' _ "$CTL"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.ok')" = "true" ]
}

@test "R27 precedence: an inherited GATEWAY_TOKEN is used, and the Keychain is not consulted" {
    # KTD15 puts the token in the shell by reference, so it is already in hand.
    # A second Keychain call for a value we hold is a needless unlock-capable
    # read — and the fixture's argv record is what proves it does not happen.
    start_fixture "env-tok-z1z2z3"
    make_retired_install
    export GATEWAY_TOKEN="env-tok-z1z2z3"

    # setup()'s own seeding wrote to this record; the assertion below is about
    # what the STATUS call does, so the slate is cleared first.
    rm -rf "$FAKE_SECURITY_RECORD_DIR"
    mkdir -p "$FAKE_SECURITY_RECORD_DIR"

    run bash -c 'bash "$1" status 2>/dev/null' _ "$CTL"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.running')" = "true" ]

    # Guard the guard: the stored token is DIFFERENT, so presenting it would
    # have come back 7 — exit 0 above can only mean the env value was used.
    [ "$STORED_TOKEN" != "env-tok-z1z2z3" ]
    run grep -rF -- "find-generic-password" "$FAKE_SECURITY_RECORD_DIR"
    [ "$status" -ne 0 ]
}

@test "R27: a config token still wins over both" {
    start_fixture "config-tok-c4c4"
    make_install "$WORK/install"
    cat > "$WORK/install/gateway.yaml" <<'EOF'
server:
  bind: "127.0.0.1:4000"
  token: config-tok-c4c4

models:
  alpha:
    model: openrouter/alpha
    display_name: "alpha"
EOF
    export SPAWN_INSTALL_DIR="$WORK/install"
    export SPAWN_CONFIG="$WORK/install/gateway.yaml"
    export GATEWAY_TOKEN="env-tok-z1z2z3"

    run bash -c 'bash "$1" status 2>/dev/null' _ "$CTL"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.running')" = "true" ]
}

@test "G3 self-test: reverting the shared fallback makes status go red on 7" {
    # The proof that the fallback is load-bearing rather than decorative:
    # neutralise resolve_token_fallback and run the same scenario. This is the
    # exact behaviour a successful setup would leave behind without step 5.
    local script
    script="$(mutant spawnctl.sh 's|^resolve_token_fallback() {$|resolve_token_fallback() { return 0|')"
    grep -rq 'resolve_token_fallback() { return 0' "$(dirname "$script")"

    start_fixture "$STORED_TOKEN"
    make_retired_install

    run bash -c 'bash "$1" status 2>/dev/null' _ "$script"
    [ "$status" -eq 7 ]
}
