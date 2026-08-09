#!/usr/bin/env bats
# U3 step 6 — the supervising launchd agent (R28, KTD21).
#
# What this file is about: a `launchd` agent is a THIRD control surface and it
# outranks both the plugin and `gw`. KeepAlive undoes a stop within seconds,
# RunAtLoad starts the gateway at login, and the relaunch carries a bare
# environment that never sees the transient delivery file — so once setup
# retires the token out of gateway.yaml, every launchd start comes up with an
# empty auth list, which that gateway serves as "no auth required". Setup
# therefore ADOPTS the agent: it repoints ProgramArguments at a launcher that
# reads the Keychain at start, and writes no credential anywhere new.
#
# FALSE-GREEN TRAPS IT IS WRITTEN AGAINST
#   1. "no credential in the plist" and "no credential in the launcher" are
#      vacuously true of a file that was never written, or of a run that failed
#      early. Every credential assertion here is paired with a functional one:
#      the launcher is RUN, and the token it hands the gateway is read back out
#      of the recorder the plist originally named.
#   2. "it reloaded the agent" is a claim about an ORDER. Asserted against the
#      launchctl fixture's append-only argv record, not against an exit code.
#   3. "nothing was written" is vacuously true of a directory nobody looked in.
#      The no-match and two-match tests snapshot the whole sandbox and assert
#      the file list is unchanged.
#   4. A detector that text-greps a plist reports "not supervised" on a machine
#      that is, because a LaunchAgent plist is often binary. One test converts
#      the fixture to binary1 with the real plutil first.
#
# NOTHING HERE TOUCHES THE OPERATOR'S REAL ~/Library/LaunchAgents, their real
# agent, or real launchd. Every seam points at this test's own temp directory.
#
# NO REAL CREDENTIAL IS USED OR NEEDED. Both values below are short synthetic
# strings with no credential-shaped prefix — the repo-wide secret scan in
# run-tests.sh reads this file too.

setup() {
    FIX="$(cd "$BATS_TEST_DIRNAME/../fixtures" && pwd)"
    LIB="$(cd "$BATS_TEST_DIRNAME/../../lib" && pwd)"
    SETUP="$LIB/setup.sh"
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/gw-sup.XXXXXX")"
    WORK="$(cd "$WORK" && pwd -P)"

    # THE SAFETY RAILS. All three of these default to the operator's real
    # machine surfaces; a run that forgot one would rewrite the agent that
    # supervises the box this suite is running on.
    export SPAWN_LAUNCH_AGENTS_DIR="$WORK/LaunchAgents"
    export SPAWN_GATEWAY_LAUNCHER="$WORK/dot-gateway/spawn-launch.sh"
    # FOURTH RAIL. The launcher now records its own pid so spawnctl can manage
    # a launchd-started gateway, and that path is BAKED into the generated
    # script at write time. Without this the tests below would bake — and, when
    # they run the launcher, write — the operator's real ~/.gateway.pid.
    export SPAWN_PIDFILE="$WORK/state/.gateway.pid"
    # The launcher's delivery file is transient by design; 1s keeps that real
    # while letting the cleaner test observe both states.
    export SPAWN_LAUNCHER_DELIVERY_TTL=1
    mkdir -p "$WORK/state"
    export SPAWN_STATE_HOME="$WORK/state"
    PIDFILE="$SPAWN_PIDFILE"
    mkdir -p "$SPAWN_LAUNCH_AGENTS_DIR"

    export SPAWN_PLUTIL_BIN="$FIX/fake-plutil.sh"
    export SPAWN_LAUNCHCTL_BIN="$FIX/fake-launchctl.sh"
    PLUTIL_RECORD="$WORK/plutil-argv"
    CTL_RECORD="$WORK/launchctl-argv"
    export FAKE_PLUTIL_RECORD="$PLUTIL_RECORD"
    export FAKE_LAUNCHCTL_RECORD="$CTL_RECORD"
    unset FAKE_PLUTIL_FAIL FAKE_LAUNCHCTL_UNLOAD_RC FAKE_LAUNCHCTL_LOAD_RC

    # Keychain seam (U1's fixture). Nothing here may reach the login keychain.
    export SPAWN_SECURITY_BIN="$FIX/fake-security.sh"
    export FAKE_SECURITY_STORE_DIR="$WORK/kc-store"
    export FAKE_SECURITY_RECORD_DIR="$WORK/kc-record"
    mkdir -p "$FAKE_SECURITY_STORE_DIR" "$FAKE_SECURITY_RECORD_DIR"
    export FAKE_SECURITY_MODE=ok
    export SPAWN_KEYCHAIN_SERVICE="spawn-gateway-test"
    export SPAWN_KEYCHAIN_ACCOUNT_TOKEN="gateway-token"
    export SPAWN_KEYCHAIN_ACCOUNT_OPENROUTER="openrouter-key"
    unset GATEWAY_TOKEN OPENROUTER_API_KEY SPAWN_INSTALL_DIR

    STORED_TOKEN="stored-tok-9f8e7d"
    STORED_KEY="stored-key-3c2b1a"
    seed_keychain gateway-token "$STORED_TOKEN"
    seed_keychain openrouter-key "$STORED_KEY"

    # The install the agent supervises, in the real shape: the binary sits at
    # target/release/gateway and the config beside it.
    INSTALL="$WORK/gateway-0.1.1"
    BIN="$INSTALL/target/release/gateway"
    mkdir -p "$(dirname "$BIN")"
    BIN_RECORD="$WORK/gateway-exec"
    export BIN_RECORD
    cat > "$BIN" <<'EOS'
#!/usr/bin/env bash
{
    printf 'cwd=%s\n' "$PWD"
    printf 'args=%s\n' "$*"
    printf 'token=%s\n' "${GATEWAY_TOKEN:-}"
    printf 'openrouter=%s\n' "${OPENROUTER_API_KEY:-<unset>}"
    # The delivery file AS IT IS AT EXEC. The launcher's cleaner removes it
    # shortly after, so a test that looked afterwards would see nothing and
    # could not tell "delivered then cleaned" from "never delivered".
    if [ -f "$PWD/.env.local" ]; then
        printf 'envlocal=%s\n' "$(cat "$PWD/.env.local")"
        printf 'envmode=%s\n' "$(stat -f '%Lp' "$PWD/.env.local" 2>/dev/null || stat -c '%a' "$PWD/.env.local" 2>/dev/null)"
    else
        printf 'envlocal=<absent>\n'
    fi
} >> "$BIN_RECORD"
exit 0
EOS
    chmod +x "$BIN"
    printf 'server:\n  port: 4000\n' > "$INSTALL/gateway.yaml"

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

run_supervisor() {   # run_supervisor [--script <path>] [flags...]
    local script="$SETUP"
    if [ "${1:-}" = "--script" ]; then script="$2"; shift 2; fi
    rm -f "$OUT" "$ERR"
    RC=0
    # Consent is granted by default here: every test below exercises what
    # adoption DOES, and re-asserting the gate in each one would only test the
    # gate 20 times. The gate itself has its own test, which calls the script
    # WITHOUT this flag.
    bash "$script" supervisor --consent-adopt-agent --install-dir "$INSTALL" "$@" >"$OUT" 2>"$ERR" || RC=$?
    return 0
}

assert_one_json() {
    [ -s "$OUT" ]
    [ "$(grep -c . "$OUT")" -eq 1 ]
    jq -e . "$OUT" >/dev/null
    jq -e 'has("ok") and has("error") and has("exit_code")' "$OUT" >/dev/null
}

# plant_agent <basename> [program-path] [install-dir] — an agent plist in the
# shape the build machine's really is in: KeepAlive, RunAtLoad, a
# WorkingDirectory, both log paths and a Label, all of which must survive.
#
# The third argument is the install the plist NAMES, which is the resolved one
# on every path except the upgrade tests: there it is an older sibling, so the
# --config argument and the WorkingDirectory point at that older tree the way a
# real operator-written plist would.
plant_agent() {
    local name="$1" prog="${2:-$BIN}" inst="${3:-}"
    # NOT `local INSTALL="${3:-$INSTALL}"`: bash creates the local first and the
    # right-hand side then reads the EMPTY local, not the caller's value.
    [ -n "$inst" ] || inst="$INSTALL"
    cat > "$SPAWN_LAUNCH_AGENTS_DIR/$name.plist" <<EOP
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.example.$name</string>
	<key>ProgramArguments</key>
	<array>
		<string>$prog</string>
		<string>--config</string>
		<string>$inst/gateway.yaml</string>
	</array>
	<key>KeepAlive</key>
	<true/>
	<key>RunAtLoad</key>
	<true/>
	<key>WorkingDirectory</key>
	<string>$inst</string>
	<key>StandardOutPath</key>
	<string>$WORK/agent.out.log</string>
	<key>StandardErrorPath</key>
	<string>$WORK/agent.err.log</string>
</dict>
</plist>
EOP
    printf '%s' "$SPAWN_LAUNCH_AGENTS_DIR/$name.plist"
}

sha_of() { shasum -a 256 "$1" | awk '{print $1}'; }

# The plist as data, with the one key this step is entitled to change removed.
# Read through the REAL plutil, independently of the code under test.
other_keys() { /usr/bin/plutil -convert json -o - "$1" | jq -S 'del(.ProgramArguments)'; }

# Every file on the two surfaces this step could possibly write: the agents
# directory and the launcher's own directory. Scoped to those rather than to
# the whole sandbox because the fixtures' own argv records live under $WORK too,
# and a snapshot that moved on every run would be asserting nothing.
file_list() {
    find "$SPAWN_LAUNCH_AGENTS_DIR" "$(dirname "$SPAWN_GATEWAY_LAUNCHER")" -type f 2>/dev/null \
        | sed "s|^$WORK||" | sort
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
    sed -i '' "$expr" "$dir/$file"
    printf '%s' "$dir/$file"
}

# --- R28: the adoption -----------------------------------------------------

@test "R28: the agent is repointed at the launcher, and NO credential value is anywhere in the plist" {
    local plist
    plist="$(plant_agent gateway)"
    # Guard the guard: the plist really does name the binary first, or "it was
    # repointed" is a statement about a file that never pointed anywhere.
    [ "$(/usr/bin/plutil -convert json -o - "$plist" | jq -r '.ProgramArguments[0]')" = "$BIN" ]

    run_supervisor
    [ "$RC" -eq 0 ]
    assert_one_json
    [ "$(jq -r '.action' "$OUT")" = "repointed" ]
    [ "$(jq -r '.plist' "$OUT")" = "$plist" ]
    [ "$(jq -r '.launcher' "$OUT")" = "$SPAWN_GATEWAY_LAUNCHER" ]

    # The one key that changed.
    [ "$(/usr/bin/plutil -convert json -o - "$plist" | jq -r '.ProgramArguments | length')" -eq 1 ]
    [ "$(/usr/bin/plutil -convert json -o - "$plist" | jq -r '.ProgramArguments[0]')" = "$SPAWN_GATEWAY_LAUNCHER" ]

    # KTD21's hard line: neither secret is in the plist, and neither is in the
    # emitted object or the diagnostics either.
    run grep -F -- "$STORED_TOKEN" "$plist" "$OUT" "$ERR"
    [ "$status" -ne 0 ]
    run grep -F -- "$STORED_KEY" "$plist" "$OUT" "$ERR"
    [ "$status" -ne 0 ]
    run grep -F 'EnvironmentVariables' "$plist"
    [ "$status" -ne 0 ]

    # KTD21's stated cost, in the output rather than absorbed: this step is an
    # escalation of what the plugin touches, and the object has to say so.
    jq -e '.detail | test("OWNS A STEP IN THE STARTUP PATH")' "$OUT" >/dev/null
}

@test "R28: every other key in the adopted plist survives unchanged" {
    local plist before
    plist="$(plant_agent gateway)"
    before="$(other_keys "$plist")"
    # Non-vacuous: the fixture really does carry the keys the operator's does.
    printf '%s' "$before" | jq -e '.KeepAlive == true and .RunAtLoad == true and (.WorkingDirectory | length > 0) and (.Label | length > 0) and (.StandardOutPath | length > 0) and (.StandardErrorPath | length > 0)' >/dev/null

    run_supervisor
    [ "$RC" -eq 0 ]
    [ "$(other_keys "$plist")" = "$before" ]
}

@test "R28: the plist's original file mode is preserved" {
    local plist
    plist="$(plant_agent gateway)"
    chmod 600 "$plist"

    run_supervisor
    [ "$RC" -eq 0 ]
    [ "$(stat -f '%Lp' "$plist")" = "600" ]
}

@test "KTD21: a BINARY plist is detected and rewritten, and stays binary" {
    local plist
    plist="$(plant_agent gateway)"
    /usr/bin/plutil -convert binary1 "$plist"
    # Non-vacuous: it really is binary now, so a text-grepping detector would
    # miss it.
    [ "$(head -c 8 "$plist")" = "bplist00" ]

    run_supervisor
    [ "$RC" -eq 0 ]
    [ "$(jq -r '.action' "$OUT")" = "repointed" ]
    [ "$(head -c 8 "$plist")" = "bplist00" ]
    [ "$(/usr/bin/plutil -convert json -o - "$plist" | jq -r '.ProgramArguments[0]')" = "$SPAWN_GATEWAY_LAUNCHER" ]
}

# --- the launcher ----------------------------------------------------------

@test "R28/KTD21: the launcher reads the Keychain, carries no credential value, and execs the original command" {
    plant_agent gateway >/dev/null

    run_supervisor
    [ "$RC" -eq 0 ]
    [ -x "$SPAWN_GATEWAY_LAUNCHER" ]
    bash -n "$SPAWN_GATEWAY_LAUNCHER"

    # By reference, in the file text: a Keychain read, no literal.
    grep -qF 'find-generic-password' "$SPAWN_GATEWAY_LAUNCHER"
    run grep -F -- "$STORED_TOKEN" "$SPAWN_GATEWAY_LAUNCHER"
    [ "$status" -ne 0 ]
    run grep -F -- "$STORED_KEY" "$SPAWN_GATEWAY_LAUNCHER"
    [ "$status" -ne 0 ]

    # ...and functionally: RUN it, and read back what the gateway was handed.
    # The binary is the one the plist ORIGINALLY named, with its own arguments.
    run bash "$SPAWN_GATEWAY_LAUNCHER"
    [ "$status" -eq 0 ]
    grep -qx "args=--config $INSTALL/gateway.yaml" "$BIN_RECORD"
    grep -qx "token=$STORED_TOKEN" "$BIN_RECORD"
    # CWD is the install dir, which is how the gateway's own .env.local (the
    # OpenRouter key) is found at all.
    grep -qx "cwd=$INSTALL" "$BIN_RECORD"
}

@test "R7: an inherited OPENROUTER_API_KEY does not reach the gateway's exec-time environment" {
    plant_agent gateway >/dev/null
    run_supervisor
    [ "$RC" -eq 0 ]

    OPENROUTER_API_KEY="inherited-key-5d4c" run bash "$SPAWN_GATEWAY_LAUNCHER"
    [ "$status" -eq 0 ]
    grep -qx 'openrouter=<unset>' "$BIN_RECORD"
    grep -qx "token=$STORED_TOKEN" "$BIN_RECORD"
}

@test "R9: with nothing stored the launcher refuses rather than starting an open gateway" {
    plant_agent gateway >/dev/null
    run_supervisor
    [ "$RC" -eq 0 ]
    "$SPAWN_SECURITY_BIN" delete-generic-password \
        -a gateway-token -s "$SPAWN_KEYCHAIN_SERVICE" >/dev/null 2>&1

    # `security` exits 44 for "no such item" — the trap the gw generator hit.
    run bash "$SPAWN_GATEWAY_LAUNCHER"
    [ "$status" -eq 9 ]
    [ ! -f "$BIN_RECORD" ]
}

# --- the refusals ----------------------------------------------------------

@test "R28: no matching agent is reported not-supervised, and NOTHING is written anywhere" {
    # A launchd agent that has nothing to do with the gateway. It must be swept
    # past, not adopted, and not damaged.
    plant_agent unrelated "/usr/bin/true" >/dev/null
    local before
    before="$(file_list)"
    local unrelated_sha
    unrelated_sha="$(sha_of "$SPAWN_LAUNCH_AGENTS_DIR/unrelated.plist")"

    run_supervisor
    [ "$RC" -eq 0 ]
    assert_one_json
    [ "$(jq -r '.action' "$OUT")" = "not-supervised" ]
    [ "$(jq -r '.plist' "$OUT")" = "null" ]

    [ ! -e "$SPAWN_GATEWAY_LAUNCHER" ]
    [ "$(file_list)" = "$before" ]
    [ "$(sha_of "$SPAWN_LAUNCH_AGENTS_DIR/unrelated.plist")" = "$unrelated_sha" ]
    # It never creates an agent, so launchd was never asked to load one either.
    [ ! -f "$CTL_RECORD" ]
}

@test "R28: two matching agents are a named refusal, and neither is touched" {
    local a b sha_a sha_b
    a="$(plant_agent gateway)"
    b="$(plant_agent gateway-copy)"
    sha_a="$(sha_of "$a")"
    sha_b="$(sha_of "$b")"

    run_supervisor
    [ "$RC" -eq 2 ]
    assert_one_json
    [ "$(jq -r '.ok' "$OUT")" = "false" ]
    jq -e '.error | test("2 launchd agents")' "$OUT" >/dev/null

    [ "$(sha_of "$a")" = "$sha_a" ]
    [ "$(sha_of "$b")" = "$sha_b" ]
    [ ! -e "$SPAWN_GATEWAY_LAUNCHER" ]
    [ ! -f "$CTL_RECORD" ]
}

@test "R4: a missing plutil or launchctl is exit 9 naming it, not a silent not-supervised" {
    plant_agent gateway >/dev/null
    local sha
    sha="$(sha_of "$SPAWN_LAUNCH_AGENTS_DIR/gateway.plist")"

    SPAWN_PLUTIL_BIN="$WORK/no-such-plutil" run_supervisor
    [ "$RC" -eq 9 ]
    assert_one_json
    jq -e '.error | test("plutil")' "$OUT" >/dev/null
    [ "$(sha_of "$SPAWN_LAUNCH_AGENTS_DIR/gateway.plist")" = "$sha" ]

    SPAWN_LAUNCHCTL_BIN="$WORK/no-such-launchctl" run_supervisor
    [ "$RC" -eq 9 ]
    jq -e '.error | test("launchctl")' "$OUT" >/dev/null
    [ "$(sha_of "$SPAWN_LAUNCH_AGENTS_DIR/gateway.plist")" = "$sha" ]
}

@test "a plist plutil cannot read is skipped, not fatal — the real agent is still adopted" {
    local plist
    plist="$(plant_agent gateway)"
    printf 'this is not a property list at all\n' > "$SPAWN_LAUNCH_AGENTS_DIR/broken.plist"
    # An agent with no ProgramArguments at all is the other skip case.
    cat > "$SPAWN_LAUNCH_AGENTS_DIR/noargs.plist" <<'EOP'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>Label</key><string>com.example.noargs</string></dict></plist>
EOP

    run_supervisor
    [ "$RC" -eq 0 ]
    [ "$(jq -r '.action' "$OUT")" = "repointed" ]
    [ "$(jq -r '.plist' "$OUT")" = "$plist" ]
}

# --- the reload ------------------------------------------------------------

@test "R28: launchctl is called to unload and then load, in that order" {
    plant_agent gateway >/dev/null

    run_supervisor
    [ "$RC" -eq 0 ]
    [ -f "$CTL_RECORD" ]
    [ "$(grep -c . "$CTL_RECORD")" -eq 2 ]
    [ "$(sed -n '1p' "$CTL_RECORD")" = "unload $SPAWN_LAUNCH_AGENTS_DIR/gateway.plist" ]
    [ "$(sed -n '2p' "$CTL_RECORD")" = "load $SPAWN_LAUNCH_AGENTS_DIR/gateway.plist" ]
}

@test "R28: an unload that fails (the job was not loaded) is tolerated, and the load still happens" {
    plant_agent gateway >/dev/null

    FAKE_LAUNCHCTL_UNLOAD_RC=1 run_supervisor
    [ "$RC" -eq 0 ]
    [ "$(jq -r '.action' "$OUT")" = "repointed" ]
    [ "$(sed -n '2p' "$CTL_RECORD")" = "load $SPAWN_LAUNCH_AGENTS_DIR/gateway.plist" ]
}

@test "R18: a load that fails is a named failure that says the plist was ALREADY repointed" {
    plant_agent gateway >/dev/null

    FAKE_LAUNCHCTL_LOAD_RC=1 run_supervisor
    [ "$RC" -eq 3 ]
    assert_one_json
    jq -e '.error | test("ALREADY been repointed")' "$OUT" >/dev/null
}

# --- re-runs ---------------------------------------------------------------

@test "R28: a re-run is idempotent — the plist is byte-identical and the original command survives" {
    local plist first_plist first_launcher
    plist="$(plant_agent gateway)"

    run_supervisor
    [ "$RC" -eq 0 ]
    first_plist="$(sha_of "$plist")"
    first_launcher="$(sha_of "$SPAWN_GATEWAY_LAUNCHER")"

    # The second run sees a plist that names the LAUNCHER, not the binary. It
    # must still recognise the agent (from the launcher's marker) and recover
    # the original command from the launcher's own record — a re-run that
    # re-baked the launcher's own path as the exec target would loop forever.
    run_supervisor
    [ "$RC" -eq 0 ]
    assert_one_json
    [ "$(jq -r '.action' "$OUT")" = "repointed" ]
    [ "$(sha_of "$plist")" = "$first_plist" ]
    [ "$(sha_of "$SPAWN_GATEWAY_LAUNCHER")" = "$first_launcher" ]

    run bash "$SPAWN_GATEWAY_LAUNCHER"
    [ "$status" -eq 0 ]
    grep -qx "args=--config $INSTALL/gateway.yaml" "$BIN_RECORD"
}

@test "R28: an agent pointing at a launcher that is GONE is a named failure, not a silent re-adoption" {
    local plist
    plist="$(plant_agent gateway)"
    run_supervisor
    [ "$RC" -eq 0 ]
    rm -f "$SPAWN_GATEWAY_LAUNCHER"
    local sha
    sha="$(sha_of "$plist")"

    run_supervisor
    [ "$RC" -eq 2 ]
    assert_one_json
    jq -e '.error | test("cannot be recovered")' "$OUT" >/dev/null
    [ "$(sha_of "$plist")" = "$sha" ]
}

# --- the upgrade path ------------------------------------------------------
#
# THE DEFECT THESE ARE WRITTEN AGAINST. Matching only the RESOLVED binary makes
# this whole step silently no-op the moment `acquire` installs a version newer
# than the one the operator wrote into the plist: the step reports
# "not-supervised", setup reports success, and launchd goes on starting the OLD
# binary — which, after token retirement, comes up with an empty auth list and
# serves as an open proxy. Every test below plants a plist naming a sibling
# install that DOES NOT EXIST, because promote() deletes a replaced install: a
# detector that stat'ed the path would go blind on exactly this case.

@test "R28: an agent naming an OLDER sibling install is adopted, and the launcher execs the RESOLVED build" {
    local old plist
    old="$WORK/gateway-0.1.0"
    plist="$(plant_agent gateway "$old/target/release/gateway" "$old")"
    # Non-vacuous in both directions: the plist really names the older tree, and
    # that tree really is gone.
    [ "$(/usr/bin/plutil -convert json -o - "$plist" | jq -r '.ProgramArguments[0]')" = "$old/target/release/gateway" ]
    [ ! -e "$old" ]

    run_supervisor
    [ "$RC" -eq 0 ]
    assert_one_json
    [ "$(jq -r '.action' "$OUT")" = "repointed" ]
    [ "$(jq -r '.rebased' "$OUT")" = "true" ]
    [ "$(jq -r '.rebased_from' "$OUT")" = "$old" ]
    jq -e '.detail | test("REBASED")' "$OUT" >/dev/null
    [ "$(/usr/bin/plutil -convert json -o - "$plist" | jq -r '.ProgramArguments[0]')" = "$SPAWN_GATEWAY_LAUNCHER" ]

    # FUNCTIONAL, not textual. The binary the plist named does not exist, so a
    # launcher that failed to rebase cannot produce this record at all — and the
    # config it is handed is the resolved one, not the retired install's.
    run bash "$SPAWN_GATEWAY_LAUNCHER"
    [ "$status" -eq 0 ]
    grep -qx "args=--config $INSTALL/gateway.yaml" "$BIN_RECORD"
    grep -qx "cwd=$INSTALL" "$BIN_RECORD"
    grep -qx "token=$STORED_TOKEN" "$BIN_RECORD"
    run grep -F -- "$old" "$BIN_RECORD"
    [ "$status" -ne 0 ]
}

@test "R28: a rebase keeps the argv it FIRST adopted, and a re-run rebases from that record again" {
    local old
    old="$WORK/gateway-0.1.0"
    plant_agent gateway "$old/target/release/gateway" "$old" >/dev/null

    run_supervisor
    [ "$RC" -eq 0 ]
    # The recorded original is the only surviving copy of the command the
    # operator wrote, so it keeps naming what it first adopted...
    grep -q '^# spawn-setup-original-argv: ' "$SPAWN_GATEWAY_LAUNCHER"
    grep -qF -- "$old/target/release/gateway" "$SPAWN_GATEWAY_LAUNCHER"
    # ...while the line that RUNS names the install this run resolved.
    grep -qF -- "exec '$BIN'" "$SPAWN_GATEWAY_LAUNCHER"

    # The re-run sees a plist naming the LAUNCHER, recovers the original out of
    # it, and rebases again from that record — stable, not drifting.
    run_supervisor
    [ "$RC" -eq 0 ]
    assert_one_json
    [ "$(jq -r '.rebased' "$OUT")" = "true" ]
    [ "$(jq -r '.rebased_from' "$OUT")" = "$old" ]
    [ "$(jq -r '.original_program_arguments[0]' "$OUT")" = "$old/target/release/gateway" ]
    [ "$(jq -r '.program_arguments[0]' "$OUT")" = "$BIN" ]
    grep -qF -- "$old/target/release/gateway" "$SPAWN_GATEWAY_LAUNCHER"

    run bash "$SPAWN_GATEWAY_LAUNCHER"
    [ "$status" -eq 0 ]
    grep -qx "args=--config $INSTALL/gateway.yaml" "$BIN_RECORD"
}

@test "R28: only a gateway-* SIBLING of the resolved install matches — three lookalikes are not adopted" {
    # A different directory family; a deeper path under a gateway-* directory
    # (the trap a `case` glob would fall into, since * crosses /); and a
    # gateway-* install one directory level up.
    plant_agent family "$WORK/notgateway-0.1.0/target/release/gateway" "$WORK/notgateway-0.1.0" >/dev/null
    plant_agent nested "$WORK/gateway-0.1.0/vendor/target/release/gateway" "$WORK/gateway-0.1.0" >/dev/null
    plant_agent higher "$(dirname "$WORK")/gateway-0.1.0/target/release/gateway" "$(dirname "$WORK")/gateway-0.1.0" >/dev/null
    local before
    before="$(file_list)"

    run_supervisor
    [ "$RC" -eq 0 ]
    assert_one_json
    [ "$(jq -r '.action' "$OUT")" = "not-supervised" ]
    [ ! -e "$SPAWN_GATEWAY_LAUNCHER" ]
    [ "$(file_list)" = "$before" ]
    [ ! -f "$CTL_RECORD" ]
}

@test "R28: a stale sibling AND the resolved install both matching is still the two-agent refusal" {
    local a b sha_a sha_b old="$WORK/gateway-0.1.0"
    a="$(plant_agent gateway)"
    b="$(plant_agent gateway-old "$old/target/release/gateway" "$old")"
    sha_a="$(sha_of "$a")"
    sha_b="$(sha_of "$b")"

    run_supervisor
    [ "$RC" -eq 2 ]
    assert_one_json
    jq -e '.error | test("2 launchd agents")' "$OUT" >/dev/null
    [ "$(sha_of "$a")" = "$sha_a" ]
    [ "$(sha_of "$b")" = "$sha_b" ]
    [ ! -e "$SPAWN_GATEWAY_LAUNCHER" ]
    [ ! -f "$CTL_RECORD" ]
}

# --- G3: the assertions are proven by mutating the code ---------------------

@test "G3 self-test: a step that CREATES a plist when none matched makes the no-match assertion go red" {
    # The defect this suite exists to catch: "make the supervised case work"
    # slides into "make the machine supervised", and the plugin quietly becomes
    # the owner of a startup path the operator never asked it to own.
    local script
    script="$(mutant setup.sh 's|^        say "no launchd agent in .*|        printf "invented\\n" > "$LAUNCH_AGENTS_DIR/com.spawn.invented.plist"|')"
    grep -q 'com.spawn.invented.plist' "$script"

    plant_agent unrelated "/usr/bin/true" >/dev/null
    local before
    before="$(file_list)"

    run_supervisor --script "$script"
    [ "$RC" -eq 0 ]
    [ "$(jq -r '.action' "$OUT")" = "not-supervised" ]
    # The mutation is live: a plist really was invented...
    [ -f "$SPAWN_LAUNCH_AGENTS_DIR/com.spawn.invented.plist" ]
    # ...so the assertion the healthy suite makes is now false.
    [ "$(file_list)" != "$before" ]
}

@test "G3 self-test: a launcher that BAKES the token makes the credential-free assertion go red" {
    local script
    script="$(mutant setup.sh 's|^# credentials are NEVER baked into this file.*|GATEWAY_TOKEN=$(spawn::keychain_read "$KEYCHAIN_SERVICE" "$KEYCHAIN_ACCOUNT_TOKEN")|')"
    grep -q 'GATEWAY_TOKEN=\$(spawn::keychain_read' "$script"

    plant_agent gateway >/dev/null
    run_supervisor --script "$script"
    [ "$RC" -eq 0 ]
    # The mutation is live: the literal really is in the emitted launcher...
    grep -qF -- "$STORED_TOKEN" "$SPAWN_GATEWAY_LAUNCHER"
    # ...so the assertion the healthy suite makes is now false.
    run grep -F -- "$STORED_TOKEN" "$SPAWN_GATEWAY_LAUNCHER"
    [ "$status" -eq 0 ]
}

@test "G3 self-test: a reload that skips the unload makes the order assertion go red" {
    # KeepAlive means a load without an unload leaves launchd supervising the
    # OLD command — the agent reads as adopted and still starts the gateway
    # with no token.
    local script
    script="$(mutant setup.sh 's|^    "\$LAUNCHCTL_BIN" unload "\$SUPERVISOR_PLIST"|    true unload "$SUPERVISOR_PLIST"|')"
    grep -q '^    true unload' "$script"

    plant_agent gateway >/dev/null
    run_supervisor --script "$script"
    [ "$RC" -eq 0 ]
    [ "$(grep -c . "$CTL_RECORD")" -eq 1 ]
    [ "$(sed -n '1p' "$CTL_RECORD")" = "load $SPAWN_LAUNCH_AGENTS_DIR/gateway.plist" ]
}

@test "G3 self-test: reverting the match to exact-binary makes the upgrade adoption go red" {
    # The regression this closes, reintroduced deliberately: match only the
    # RESOLVED binary and the upgrade path becomes invisible again.
    local script old="$WORK/gateway-0.1.0"
    script="$(mutant setup.sh 's, || sibling_install_of "$arg0" "$install" >/dev/null,,')"
    run grep -c 'sibling_install_of "\$arg0" "\$install" >' "$script"
    [ "$output" = "0" ]

    plant_agent gateway "$old/target/release/gateway" "$old" >/dev/null
    run_supervisor --script "$script"
    [ "$RC" -eq 0 ]
    # The mutation is live: the supervising agent is no longer seen at all...
    [ "$(jq -r '.action' "$OUT")" = "not-supervised" ]
    # ...so the healthy suite's adoption assertions are now false, and launchd
    # is left starting a binary that is gone.
    [ ! -e "$SPAWN_GATEWAY_LAUNCHER" ]
}

@test "G3 self-test: a launcher that execs the argv UNREBASED makes the launcher-run assertion go red" {
    local script old="$WORK/gateway-0.1.0"
    script="$(mutant setup.sh 's,write_launcher "\$SUPERVISOR_ARGV" "\$exec_argv",write_launcher "$SUPERVISOR_ARGV" "$SUPERVISOR_ARGV",')"
    grep -q 'write_launcher "\$SUPERVISOR_ARGV" "\$SUPERVISOR_ARGV"' "$script"

    plant_agent gateway "$old/target/release/gateway" "$old" >/dev/null
    run_supervisor --script "$script"
    [ "$RC" -eq 0 ]
    [ "$(jq -r '.action' "$OUT")" = "repointed" ]
    # The mutation is live: the launcher execs the install that is GONE...
    grep -qF -- "exec '$old/target/release/gateway'" "$SPAWN_GATEWAY_LAUNCHER"
    # ...so the healthy suite's functional assertion is now false — the gateway
    # never starts, which is what "adopted" would have been claiming. `run !`
    # rather than a bare `run`, because the failure here is the POINT and bats
    # would otherwise warn about the 127 as though it were an accident.
    run ! bash "$SPAWN_GATEWAY_LAUNCHER"
    [ "$status" -ne 0 ]
    [ ! -f "$BIN_RECORD" ]
}

@test "G3 self-test: recording the REBASED argv makes the original-command assertion go red" {
    local script old="$WORK/gateway-0.1.0"
    script="$(mutant setup.sh 's,write_launcher "\$SUPERVISOR_ARGV" "\$exec_argv",write_launcher "$exec_argv" "$exec_argv",')"
    grep -q 'write_launcher "\$exec_argv" "\$exec_argv"' "$script"

    plant_agent gateway "$old/target/release/gateway" "$old" >/dev/null
    run_supervisor --script "$script"
    [ "$RC" -eq 0 ]
    [ "$(jq -r '.action' "$OUT")" = "repointed" ]
    # The mutation is live: the recorded command has been overwritten with the
    # rebased one, so the only surviving copy of what the operator wrote is
    # lost — and the healthy suite's preservation assertion is now false.
    run grep -F -- "$old/target/release/gateway" "$SPAWN_GATEWAY_LAUNCHER"
    [ "$status" -ne 0 ]
}

# --- KTD17: adoption is consent-gated --------------------------------------
#
# Repointing a launchd agent takes over a file setup did not write and puts
# this plugin in the machine's startup path — a bigger act than overwriting
# `gw`, which has been gated since it shipped. This one was not.

@test "KTD17: adopting the agent without consent is refused with exit 8 and writes NOTHING" {
    plant_agent com.example.gateway
    local plist="$LAUNCH_AGENTS_DIR/com.example.gateway.plist"
    local before_sha; before_sha="$(shasum "$plist" | awk '{print $1}')"

    # No --consent-adopt-agent: the bare verb, as an operator would first run it.
    RC=0
    bash "$SETUP" supervisor --install-dir "$INSTALL" >"$OUT" 2>"$ERR" || RC=$?
    [ "$RC" -eq 8 ]
    assert_one_json
    [ "$(jq -r '.ok' "$OUT")" = "false" ]
    [ "$(jq -r '.consent_required' "$OUT")" = "adopt-agent" ]
    [ "$(jq -r '.exit_code' "$OUT")" = "8" ]
    # The error names the flag the caller must come back with, or the operator
    # is told "no" with no way forward.
    jq -r '.error' "$OUT" | grep -qF -- '--consent-adopt-agent'

    # NOTHING was written: the plist is byte-identical and no launcher exists.
    [ "$(shasum "$plist" | awk '{print $1}')" = "$before_sha" ]
    [ ! -e "$SPAWN_GATEWAY_LAUNCHER" ]
    # And launchctl was never called — a refusal that still unloaded the
    # operator's agent would have taken their gateway down to say no.
    [ ! -s "$CTL_RECORD" ] || refute_file_match 'load' "$CTL_RECORD"
}

@test "KTD17: with consent the same run adopts, so the gate is what differs" {
    plant_agent com.example.gateway
    run_supervisor
    [ "$RC" -eq 0 ]
    [ "$(jq -r '.action' "$OUT")" = "repointed" ]
    [ -f "$SPAWN_GATEWAY_LAUNCHER" ]
}

# --- THE LAUNCHER AT RUNTIME (the gap the review found) ---------------------
#
# fake-launchctl.sh records argv and execs nothing, so every test above proves
# the launcher was WRITTEN and repointed — none proved what happens when
# launchd actually runs it. Two defects lived in exactly that blind spot: the
# launcher registered no pid (so spawnctl saw a launchd-started gateway as
# unmanaged and every restart path aborted over a healthy process), and it
# relied on a .env.local that spawnctl deletes after every start (so a
# launchd-started gateway came up with no upstream credential). Both are
# invisible to a structural assertion and obvious to an executed one.

@test "R28: the launcher REGISTERS its pid, so a launchd-started gateway is not unmanaged" {
    plant_agent gateway >/dev/null
    run_supervisor
    [ "$RC" -eq 0 ]
    [ ! -f "$PIDFILE" ]

    run bash "$SPAWN_GATEWAY_LAUNCHER"
    [ "$status" -eq 0 ]

    # exec keeps the pid, so what the launcher recorded IS the gateway's pid.
    [ -f "$PIDFILE" ]
    grep -qE '^[0-9]+$' "$PIDFILE"
    # And the binary is recorded beside it, which is what spawnctl's anchored
    # identification (pid_is_gateway) matches a live process against.
    [ -f "$PIDFILE.bin" ]
    [ "$(cat "$PIDFILE.bin")" = "$BIN" ]
}

@test "R7/KTD1: the launcher DELIVERS the OpenRouter key it used to assume was lying there" {
    plant_agent gateway >/dev/null
    run_supervisor
    [ "$RC" -eq 0 ]
    # The state spawnctl leaves behind: it writes .env.local to start the
    # gateway and removes it once the probe settles. Nothing is there.
    rm -f "$INSTALL/.env.local"

    run bash "$SPAWN_GATEWAY_LAUNCHER"
    [ "$status" -eq 0 ]

    # The gateway stub records the delivery file it saw AT EXEC — after the
    # launcher ran, before the cleaner fires.
    grep -qx "envlocal=OPENROUTER_API_KEY=$STORED_KEY" "$BIN_RECORD"
    # mode 0600, the same bar spawnctl's delivery meets.
    grep -qx 'envmode=600' "$BIN_RECORD"
    # Still never in the exec-time environment (R7): the file is the channel.
    grep -qx 'openrouter=<unset>' "$BIN_RECORD"
}

@test "KTD1: the delivered key does NOT outlive startup — the cleaner removes it" {
    plant_agent gateway >/dev/null
    run_supervisor
    [ "$RC" -eq 0 ]

    run bash "$SPAWN_GATEWAY_LAUNCHER"
    [ "$status" -eq 0 ]
    # SPAWN_LAUNCHER_DELIVERY_TTL is 1 in this suite, so a bounded wait covers
    # it. A key left on disk for the life of the machine is the thing KTD1
    # exists to prevent.
    local i
    for i in $(seq 1 40); do
        [ -e "$INSTALL/.env.local" ] || break
        sleep 0.25
    done
    [ ! -e "$INSTALL/.env.local" ]
}

@test "R9: a launcher with nothing stored writes NO pidfile and execs nothing" {
    plant_agent gateway >/dev/null
    run_supervisor
    [ "$RC" -eq 0 ]
    "$SPAWN_SECURITY_BIN" delete-generic-password -a gateway-token -s "$SPAWN_KEYCHAIN_SERVICE" >/dev/null 2>&1

    run bash "$SPAWN_GATEWAY_LAUNCHER"
    [ "$status" -eq 9 ]
    # The refusal is total: no gateway ran, and no pidfile was left claiming one
    # did. A pidfile written before the token check would point spawnctl at a
    # pid that never served.
    [ ! -f "$BIN_RECORD" ] || refute_file_match 'cwd=' "$BIN_RECORD"
    [ ! -f "$PIDFILE" ]
}

@test "R4: the launcher does not steal the pidfile from a LIVE gateway of its own binary" {
    plant_agent gateway >/dev/null
    run_supervisor
    [ "$RC" -eq 0 ]

    # A live process holding the pidfile, recorded against the same binary —
    # the start-vs-supervisor race. The launcher must leave it alone; pointing
    # spawnctl at the loser is how a stop signals the wrong process.
    sleep 60 &
    local live=$!
    printf '%s\n' "$live" > "$PIDFILE"
    printf '%s\n' "$BIN" > "$PIDFILE.bin"

    run bash "$SPAWN_GATEWAY_LAUNCHER"
    [ "$status" -eq 0 ]
    [ "$(cat "$PIDFILE")" = "$live" ]
    kill "$live" 2>/dev/null || true
}
