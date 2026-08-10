#!/usr/bin/env bats
# U6 — harness wiring emission (Claude Code and Codex).
#
# What this file is about: `setup.sh wire` gives every harness it finds a
# working, credential-free configuration, validated by that harness's own
# loader, and says out loud what the wiring costs and what the validation cannot
# see.
#
# FALSE-GREEN TRAPS IT IS WRITTEN AGAINST
#   1. "the emitted config holds no credential" is vacuously true of a file that
#      was never written, or written empty. Every credential assertion is paired
#      with a POSITIVE one: the provider block is read back field by field, and
#      the shell snippet is SOURCED against a fake Keychain so the token is
#      proven to arrive rather than merely referenced in text.
#   2. "it validated the config" is vacuously true of a validator that always
#      says yes. The fixture can disagree with itself — config.load passing
#      while the PROCESS exits non-zero — and both directions are asserted.
#   3. "Codex was reported" is vacuously true of a run that marked it `skipped`
#      after failing to wire it. R11 makes that a failure, so the AE10 tests
#      assert the exit code, the loader's own message, a byte-identical file AND
#      the absence of codex from `skipped`.
#   4. A `skipped` that means "we did not try". Detection is asserted by RUNNING
#      against a PATH that holds one harness and not the other.
#
# CODEX IS NOT INSTALLED ON THIS MACHINE. Every Codex assertion here is proven
# against tests/fixtures/fake-codex.sh. That is a stated gap (KTD20) carried in
# setup's own output as `validation_gaps`, and asserted as such below.
#
# NO REAL CREDENTIAL IS USED OR NEEDED. Every token is a short synthetic string
# with no credential-shaped prefix — the repo-wide secret scan reads this file.

setup() {
    FIX="$(cd "$BATS_TEST_DIRNAME/../fixtures" && pwd)"
    LIB="$(cd "$BATS_TEST_DIRNAME/../../lib" && pwd)"
    SETUP="$LIB/setup.sh"
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/wire.XXXXXX")"
    WORK="$(cd "$WORK" && pwd -P)"

    # THE SAFETY RAILS. Every write this suite can provoke lands under $WORK.
    # The operator's real ~/.codex/config.toml and ~/.zshrc are never candidates.
    export SPAWN_CODEX_CONFIG="$WORK/dot-codex/config.toml"
    export SPAWN_GATEWAY_ENV_FILE="$WORK/dot-gateway/env.sh"
    export SPAWN_SHELL_RC="$WORK/dot-zshrc"

    # Where the alias list comes from, and where the installs would live.
    export SPAWN_SEARCH_ROOT="$WORK"
    CFG_DIR="$WORK/gateway-0.1.1"
    mkdir -p "$CFG_DIR"
    write_gateway_config

    # The gateway's root URL, through the seam spawnctl.sh already owns.
    export SPAWN_BASE_URL="http://127.0.0.1:4321/anthropic"

    # Keychain seam (U1's fixture). Nothing here may reach the login keychain.
    export SPAWN_SECURITY_BIN="$FIX/fake-security.sh"
    export FAKE_SECURITY_STORE_DIR="$WORK/kc-store"
    export FAKE_SECURITY_RECORD_DIR="$WORK/kc-record"
    mkdir -p "$FAKE_SECURITY_STORE_DIR" "$FAKE_SECURITY_RECORD_DIR"
    export FAKE_SECURITY_MODE=ok
    export SPAWN_KEYCHAIN_SERVICE="spawn-gateway-test"
    export SPAWN_KEYCHAIN_ACCOUNT_TOKEN="gateway-token"
    unset GATEWAY_TOKEN OPENROUTER_API_KEY

    STORED_TOKEN="stored-tok-w1r3d"
    seed_keychain gateway-token "$STORED_TOKEN"

    # A PATH holding ONLY what each test puts there, so detection is answered by
    # running rather than by a flag. The real `claude` and any real `codex` on
    # this machine's PATH are deliberately out of reach.
    BINDIR="$WORK/bin"
    mkdir -p "$BINDIR"
    export SPAWN_CLAUDE_BIN="$BINDIR/claude"
    export SPAWN_CODEX_BIN="$BINDIR/codex"
    export FAKE_CODEX_RECORD="$WORK/codex-argv"

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

# A gateway.yaml whose models block holds three aliases, only two of which are
# in the plugin's window table. The third exists so the INTERSECTION is provable:
# a wire that emitted everything the config served would emit `nosuch` too.
write_gateway_config() {
    cat > "$CFG_DIR/gateway.yaml" <<'EOF'
server:
  port: 4321

models:
  kimi:
    model: openrouter/moonshotai/kimi-k2.7-code
  glm:
    model: openrouter/z-ai/glm-5.2
  nosuch-alias:
    model: openrouter/vendor/not-in-the-table
EOF
}

install_claude() {
    cat > "$SPAWN_CLAUDE_BIN" <<'EOS'
#!/usr/bin/env bash
exit 0
EOS
    chmod +x "$SPAWN_CLAUDE_BIN"
}

install_codex() {
    cp "$FIX/fake-codex.sh" "$SPAWN_CODEX_BIN"
    chmod +x "$SPAWN_CODEX_BIN"
    export FAKE_CODEX_MODE="${1:-ok}"
}

run_wire() {   # run_wire [--script <path>] [flags...]
    local script="$SETUP"
    if [ "${1:-}" = "--script" ]; then script="$2"; shift 2; fi
    rm -f "$OUT" "$ERR"
    RC=0
    bash "$script" wire "$@" >"$OUT" 2>"$ERR" || RC=$?
    return 0
}

assert_one_json() {
    [ -s "$OUT" ]
    [ "$(grep -c . "$OUT")" -eq 1 ]
    jq -e . "$OUT" >/dev/null
    jq -e 'has("ok") and has("error") and has("exit_code")' "$OUT" >/dev/null
}

sha_of() { shasum -a 256 "$1" | awk '{print $1}'; }

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

# An existing Codex config in the operator's own hand, with no managed block.
plant_operator_codex_config() {
    mkdir -p "$(dirname "$SPAWN_CODEX_CONFIG")"
    cat > "$SPAWN_CODEX_CONFIG" <<'EOF'
# the operator's own file
model = "gpt-5.6-sol"
approval_policy = "on-request"

[mcp_servers.notes]
command = "note-server"
EOF
}

# --- AE4: detection reports by name, and a missing harness is SKIPPED --------

@test "AE4/R11: claude installed and codex not — Claude Code is wired and Codex is named as skipped" {
    install_claude

    run_wire --consent-shell-rc
    [ "$RC" -eq 0 ]
    assert_one_json
    [ "$(jq -r '.ok' "$OUT")" = "true" ]
    [ "$(jq -r '[.wired[].harness] | join(",")' "$OUT")" = "claude-code" ]
    [ "$(jq -r '[.skipped[].harness] | join(",")' "$OUT")" = "codex" ]
    [ "$(jq -r '.skipped[0].reason' "$OUT")" = "not installed" ]

    # Named, not silently omitted — and nothing was written for the absent one.
    [ ! -e "$SPAWN_CODEX_CONFIG" ]
    [ -f "$SPAWN_GATEWAY_ENV_FILE" ]
}

@test "R11: codex installed and claude not — Codex is wired and Claude Code is named as skipped" {
    install_codex ok

    run_wire
    [ "$RC" -eq 0 ]
    assert_one_json
    [ "$(jq -r '[.wired[].harness] | join(",")' "$OUT")" = "codex" ]
    [ "$(jq -r '[.skipped[].harness] | join(",")' "$OUT")" = "claude-code" ]
    # No Claude Code means no shell edit, and therefore no consent to ask for.
    [ ! -e "$SPAWN_GATEWAY_ENV_FILE" ]
    [ ! -e "$SPAWN_SHELL_RC" ]
}

@test "R11: a machine with neither harness fails rather than reporting an empty success" {
    run_wire --consent-shell-rc
    [ "$RC" -eq 2 ]
    assert_one_json
    [ "$(jq -r '.ok' "$OUT")" = "false" ]
    jq -e '.error | test("no supported harness")' "$OUT" >/dev/null
}

# --- The emitted Codex block ------------------------------------------------

@test "R12/R14: the emitted Codex block names the credential, carries no value, ends in /v1, and declares both windows" {
    install_codex ok
    run_wire
    [ "$RC" -eq 0 ]

    # The provider block, field by field. Each of these is a decision that fails
    # silently if it is wrong: a base_url without /v1 posts to a route the
    # gateway does not serve, and `chat` no longer deserializes upstream.
    grep -qF 'base_url = "http://127.0.0.1:4321/v1"' "$SPAWN_CODEX_CONFIG"
    grep -qF 'env_key = "GATEWAY_TOKEN"' "$SPAWN_CODEX_CONFIG"
    grep -qF 'wire_api = "responses"' "$SPAWN_CODEX_CONFIG"

    # R12: by NAME only. The stored value is nowhere in the file, and neither is
    # any other assignment that looks like a literal credential.
    run grep -F -- "$STORED_TOKEN" "$SPAWN_CODEX_CONFIG"
    [ "$status" -ne 0 ]
    # Stronger than "the value is absent", which an empty file satisfies: the
    # ONLY credential-shaped assignment anywhere in the file is the env_key line,
    # and its right-hand side is a variable NAME.
    run grep -nE '^[[:space:]]*[A-Za-z_]*(token|key|secret)[[:space:]]*=' "$SPAWN_CODEX_CONFIG"
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | grep -vc 'env_key = "GATEWAY_TOKEN"$')" -eq 0 ]

    # R14: both windows, per alias, sourced from models.json rather than typed.
    local ctx out
    ctx="$(jq -r '.aliases.kimi.context_window' "$LIB/models.json")"
    out="$(jq -r '.aliases.kimi.output_window' "$LIB/models.json")"
    grep -qF "model_context_window = $ctx" "$SPAWN_CODEX_CONFIG"
    grep -qF "model_max_output_tokens = $out" "$SPAWN_CODEX_CONFIG"
}

@test "step 6: emitted model entries are the INTERSECTION of served aliases and the table" {
    install_codex ok
    run_wire
    [ "$RC" -eq 0 ]

    [ "$(jq -r '[.models[].alias] | sort | join(",")' "$OUT")" = "glm,kimi" ]
    # The alias the gateway serves but the table does not know is emitted by
    # neither side: no profile, no model entry.
    run grep -F 'nosuch-alias' "$SPAWN_CODEX_CONFIG" "$OUT"
    [ "$status" -ne 0 ]
    # ...and an alias in the table that this gateway does NOT serve is absent too.
    run grep -F 'gpt-sol-pro' "$SPAWN_CODEX_CONFIG"
    [ "$status" -ne 0 ]
    grep -qF '[profiles."kimi"]' "$SPAWN_CODEX_CONFIG"
}

@test "a second run leaves the Codex config byte-identical, and the operator's own content survives both" {
    install_codex ok
    plant_operator_codex_config
    local operator_sha
    operator_sha="$(sha_of "$SPAWN_CODEX_CONFIG")"

    run_wire
    [ "$RC" -eq 0 ]
    [ "$(jq -r '.wired[0].action' "$OUT")" = "created" ]
    [ "$(sha_of "$SPAWN_CODEX_CONFIG")" != "$operator_sha" ]
    local first
    first="$(sha_of "$SPAWN_CODEX_CONFIG")"

    run_wire
    [ "$RC" -eq 0 ]
    [ "$(jq -r '.wired[0].action' "$OUT")" = "updated" ]
    [ "$(sha_of "$SPAWN_CODEX_CONFIG")" = "$first" ]

    # Idempotent does not mean "we own the file": every line the operator wrote
    # is still there, and there is exactly one managed block.
    grep -qF '# the operator own file' "$SPAWN_CODEX_CONFIG" || grep -qF "# the operator's own file" "$SPAWN_CODEX_CONFIG"
    grep -qF '[mcp_servers.notes]' "$SPAWN_CODEX_CONFIG"
    grep -qF 'command = "note-server"' "$SPAWN_CODEX_CONFIG"
    [ "$(grep -cF '>>> spawn-setup: managed block' "$SPAWN_CODEX_CONFIG")" -eq 1 ]
    [ "$(grep -cF '<<< spawn-setup: end managed block' "$SPAWN_CODEX_CONFIG")" -eq 1 ]
    [ -z "$(find "$(dirname "$SPAWN_CODEX_CONFIG")" -maxdepth 1 -name 'config.toml.spawn-*' 2>/dev/null)" ]
}

@test "a half-deleted managed block is refused rather than guessed at, and the file is untouched" {
    install_codex ok
    run_wire
    [ "$RC" -eq 0 ]
    # The operator truncated the end marker away. Stripping to EOF would delete
    # whatever follows; appending would leave two blocks.
    grep -v -- '<<< spawn-setup: end managed block' "$SPAWN_CODEX_CONFIG" > "$WORK/trunc"
    cat "$WORK/trunc" > "$SPAWN_CODEX_CONFIG"
    printf '\n[my_own_section]\nkeep = true\n' >> "$SPAWN_CODEX_CONFIG"
    local before
    before="$(sha_of "$SPAWN_CODEX_CONFIG")"

    run_wire
    [ "$RC" -eq 2 ]
    assert_one_json
    jq -e '.error | test("incomplete")' "$OUT" >/dev/null
    [ "$(sha_of "$SPAWN_CODEX_CONFIG")" = "$before" ]
}

# --- KTD20: validation reads the CHECK, never the process exit --------------

@test "KTD20: codex exits non-zero for a network reason while config.load passes — the config is treated as valid" {
    # The single most important test in this file. `codex doctor --json` folds
    # network reachability into its exit status, so a caller that branches on
    # `$?` calls a perfectly good config broken every time the machine is
    # offline — which is a state setup routinely runs in.
    install_codex net_fail
    run_wire
    [ "$RC" -eq 0 ]
    assert_one_json
    [ "$(jq -r '.ok' "$OUT")" = "true" ]
    [ "$(jq -r '.wired[0].harness' "$OUT")" = "codex" ]
    jq -e '.wired[0].validation_detail | test("loaded 1 provider")' "$OUT" >/dev/null

    # Guard the guard: the fixture really did exit non-zero, so this is not a
    # test that passed because both signals agreed.
    run "$SPAWN_CODEX_BIN" doctor --json
    [ "$status" -ne 0 ]
    printf '%s' "$output" | jq -e '[.checks[] | select(.name=="config.load")][0].status == "ok"' >/dev/null
}

@test "KTD20: doctor output that is not JSON is a wiring FAILURE, never a silent pass" {
    install_codex garbage
    run_wire
    [ "$RC" -eq 2 ]
    assert_one_json
    [ "$(jq -r '.ok' "$OUT")" = "false" ]
    jq -e '.error | test("no readable config.load check")' "$OUT" >/dev/null
    # Nothing was left behind claiming to be wired.
    [ ! -e "$SPAWN_CODEX_CONFIG" ]
}

@test "KTD20: doctor output with no config.load check at all is a wiring FAILURE" {
    install_codex nocheck
    run_wire
    [ "$RC" -eq 2 ]
    assert_one_json
    jq -e '.error | test("no readable config.load check")' "$OUT" >/dev/null
    [ ! -e "$SPAWN_CODEX_CONFIG" ]
}

@test "AE10/R11: an existing unloadable Codex config fails the run, is left byte-identical, and codex is NOT skipped" {
    install_codex invalid
    plant_operator_codex_config
    local before
    before="$(sha_of "$SPAWN_CODEX_CONFIG")"

    run_wire --consent-shell-rc
    [ "$RC" -eq 2 ]
    assert_one_json
    [ "$(jq -r '.ok' "$OUT")" = "false" ]

    # The loader's OWN message, not a paraphrase of it.
    jq -e '.error | test("expected a value at line 12 column 9")' "$OUT" >/dev/null
    jq -e '.error | test("Codex")' "$OUT" >/dev/null

    # Setup cannot know what it would be discarding, so it discards nothing.
    [ "$(sha_of "$SPAWN_CODEX_CONFIG")" = "$before" ]
    # `skipped` is reserved for harnesses that are not installed. This one is.
    run jq -e '(.skipped // []) | map(.harness) | index("codex")' "$OUT"
    [ "$status" -ne 0 ]
}

@test "R25: a validator that rejects the config setup just wrote fails the run and puts the file back" {
    # No pre-existing config, so the pre-check has nothing to read: the ONLY
    # thing that can catch this is validating what setup itself emitted.
    install_codex invalid
    [ ! -e "$SPAWN_CODEX_CONFIG" ]

    run_wire
    [ "$RC" -eq 2 ]
    assert_one_json
    jq -e '.error | test("Codex rejected the config setup wrote")' "$OUT" >/dev/null
    jq -e '.error | test("expected a value at line 12 column 9")' "$OUT" >/dev/null
    # It created the file, so putting it back means removing it.
    [ ! -e "$SPAWN_CODEX_CONFIG" ]
}

@test "R25: the validation is reported WITH what it cannot cover" {
    install_codex ok
    run_wire
    [ "$RC" -eq 0 ]
    jq -e '.wired[0].validated_by | test("config.load")' "$OUT" >/dev/null
    # KTD20's two stated gaps, carried as data rather than left to prose.
    jq -e '[.validation_gaps[] | select(test("strict_config"))] | length == 1' "$OUT" >/dev/null
    jq -e '[.validation_gaps[] | select(test("not installed on the machine"))] | length == 1' "$OUT" >/dev/null
    # Claude Code has no setup-written config, and says so rather than implying
    # a validation happened.
    install_claude
    run_wire --consent-shell-rc
    [ "$RC" -eq 0 ]
    jq -e '[.wired[] | select(.harness=="claude-code")][0].validated_by == null' "$OUT" >/dev/null
    jq -e '[.wired[] | select(.harness=="claude-code")][0].validation_note | test("no setup-written config")' "$OUT" >/dev/null
}

# --- KTD15/R8/R24: the shell snippet, the rc line, and the activation line ---

@test "KTD15/R8: the snippet is a Keychain READ, holds no value, and functionally lands the token in a new shell" {
    install_claude
    run_wire --consent-shell-rc
    [ "$RC" -eq 0 ]

    # By reference, in the text.
    grep -qF 'find-generic-password' "$SPAWN_GATEWAY_ENV_FILE"
    run grep -F -- "$STORED_TOKEN" "$SPAWN_GATEWAY_ENV_FILE" "$SPAWN_SHELL_RC" "$OUT" "$ERR"
    [ "$status" -ne 0 ]

    # ...and functionally, which is the half a text grep cannot give: source it
    # the way a new shell would and read the variable back out.
    run bash -c 'unset GATEWAY_TOKEN; . "$1" >/dev/null 2>&1; printf "%s" "${GATEWAY_TOKEN:-<unset>}"' _ "$SPAWN_GATEWAY_ENV_FILE"
    [ "$status" -eq 0 ]
    [ "$output" = "$STORED_TOKEN" ]

    # Rotation reaches a new shell with no rewrite: change what is stored, and
    # the same unmodified file resolves the new value.
    local before_sha
    before_sha="$(sha_of "$SPAWN_GATEWAY_ENV_FILE")"
    seed_keychain gateway-token "rotated-tok-z9y8"
    run bash -c 'unset GATEWAY_TOKEN; . "$1" >/dev/null 2>&1; printf "%s" "${GATEWAY_TOKEN:-<unset>}"' _ "$SPAWN_GATEWAY_ENV_FILE"
    [ "$output" = "rotated-tok-z9y8" ]
    [ "$(sha_of "$SPAWN_GATEWAY_ENV_FILE")" = "$before_sha" ]
}

@test "KTD15: with nothing stored the snippet leaves GATEWAY_TOKEN unset rather than exported-and-empty" {
    install_claude
    run_wire --consent-shell-rc
    [ "$RC" -eq 0 ]
    "$SPAWN_SECURITY_BIN" delete-generic-password \
        -a gateway-token -s "$SPAWN_KEYCHAIN_SERVICE" >/dev/null 2>&1

    run bash -c 'unset GATEWAY_TOKEN; . "$1" >/dev/null 2>&1; printf "%s" "${GATEWAY_TOKEN-<unset>}"' _ "$SPAWN_GATEWAY_ENV_FILE"
    [ "$output" = "<unset>" ]
}

@test "R8: the rc source line appears exactly once after two consecutive runs" {
    install_claude
    run_wire --consent-shell-rc
    [ "$RC" -eq 0 ]
    [ "$(jq -r '.wired[0].rc_line' "$OUT")" = "appended" ]

    run_wire --consent-shell-rc
    [ "$RC" -eq 0 ]
    [ "$(jq -r '.wired[0].rc_line' "$OUT")" = "already-present" ]

    [ "$(grep -cF -- 'spawn-setup: gateway token' "$SPAWN_SHELL_RC")" -eq 1 ]
    [ "$(grep -cF -- "$SPAWN_GATEWAY_ENV_FILE" "$SPAWN_SHELL_RC")" -eq 1 ]
    bash -n "$SPAWN_SHELL_RC"
}

@test "KTD17: without consent the rc is not touched, nothing else is written, and exit 8 says what is needed" {
    install_claude
    install_codex ok

    run_wire
    [ "$RC" -eq 8 ]
    assert_one_json
    [ "$(jq -r '.ok' "$OUT")" = "false" ]
    [ "$(jq -r '.consent_required' "$OUT")" = "shell-rc" ]
    jq -e '.shell_rc | test("dot-zshrc$")' "$OUT" >/dev/null

    # Refusing means touching NOTHING — including the harness that needed no
    # consent of its own.
    [ ! -e "$SPAWN_SHELL_RC" ]
    [ ! -e "$SPAWN_GATEWAY_ENV_FILE" ]
    [ ! -e "$SPAWN_CODEX_CONFIG" ]

    # And the consent flow closes: re-invoked with the flag, it completes.
    run_wire --consent-shell-rc
    [ "$RC" -eq 0 ]
    [ -f "$SPAWN_SHELL_RC" ]
}

@test "AE11/R24: the success output prints exactly ONE activation line and states later shells need nothing" {
    install_claude
    run_wire --consent-shell-rc
    [ "$RC" -eq 0 ]

    local act
    act="$(jq -r '.activation.shell_command' "$OUT")"
    [ -n "$act" ]
    # It really is a source of the file that was written, not prose.
    printf '%s' "$act" | grep -qF "$SPAWN_GATEWAY_ENV_FILE"
    # Exactly one, in the operator-facing output as well as in the JSON.
    [ "$(grep -cF -- "$act" "$ERR")" -eq 1 ]
    jq -e '.activation.this_shell | test("parent shell")' "$OUT" >/dev/null
    jq -e '.activation.later_shells | test("need nothing")' "$OUT" >/dev/null

    # AE11's other half, functionally: a harness launched in a shell that has
    # NOT run the line has no token, and running the line gives it one.
    run bash -c 'unset GATEWAY_TOKEN; printf "%s" "${GATEWAY_TOKEN-<unset>}"'
    [ "$output" = "<unset>" ]
    run bash -c "unset GATEWAY_TOKEN; $act >/dev/null 2>&1; printf '%s' \"\${GATEWAY_TOKEN-<unset>}\""
    [ "$output" = "$STORED_TOKEN" ]
}

# --- R15: the losses are carried as DATA ------------------------------------

@test "R15: setup's own output carries what a gateway-pointed session loses, including the Codex compaction gap" {
    install_claude
    install_codex ok
    run_wire --consent-shell-rc
    [ "$RC" -eq 0 ]

    # Copied from the verified list rather than referenced: the SKILL.md it came
    # from never loads at runtime, so a pointer would be a statement nothing
    # opens.
    jq -e '(.losses | length) >= 5' "$OUT" >/dev/null
    jq -e '[.losses[] | select(test("MCP connectors"))] | length == 1' "$OUT" >/dev/null
    jq -e '[.losses[] | select(test("advisor"))] | length == 1' "$OUT" >/dev/null
    jq -e '[.losses[] | select(test("32000"))] | length == 1' "$OUT" >/dev/null
    jq -e '[.losses[] | select(test("/responses/compact"))] | length == 1' "$OUT" >/dev/null
}

# --- KTD19: the window table -------------------------------------------------

@test "KTD19/R14: every alias in models.json declares an output window, and the schema version bumped" {
    [ "$(jq -r '.version' "$LIB/models.json")" -ge 2 ]
    # Every alias, not most of them: a single missing entry is an alias whose
    # output is silently capped at 32000 by Claude Code.
    [ "$(jq -r '[.aliases[] | select((.output_window // null) == null)] | length' "$LIB/models.json")" -eq 0 ]
    [ "$(jq -r '[.aliases[] | select((.output_source // null) == null)] | length' "$LIB/models.json")" -eq 0 ]
    # Additive: the field the existing drift logic reads is still on every entry.
    [ "$(jq -r '[.aliases[] | select((.context_window // null) == null)] | length' "$LIB/models.json")" -eq 0 ]
    # The chain alias under-declares rather than overflows, same rule the
    # context window follows.
    local d k g
    d="$(jq -r '.aliases.default.output_window' "$LIB/models.json")"
    k="$(jq -r '.aliases.kimi.output_window' "$LIB/models.json")"
    g="$(jq -r '.aliases.glm.output_window' "$LIB/models.json")"
    [ "$d" -le "$k" ]
    [ "$d" -le "$g" ]
}

# --- R10: nothing emitted here carries a credential -------------------------

@test "R10: every file this verb writes passes the secret scan's credential-prefix layer" {
    install_claude
    install_codex ok
    run_wire --consent-shell-rc
    [ "$RC" -eq 0 ]

    local pat='sk-ant-[A-Za-z0-9_-]{16,}|sk-or-v1-[A-Za-z0-9]{16,}|sk-[A-Za-z0-9]{32,}|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{30,}|xox[baprs]-[A-Za-z0-9-]{10,}|-----BEGIN [A-Z ]*PRIVATE KEY-----'
    local f
    for f in "$SPAWN_CODEX_CONFIG" "$SPAWN_GATEWAY_ENV_FILE" "$SPAWN_SHELL_RC" "$OUT"; do
        [ -f "$f" ]
        run grep -nEo "$pat" "$f"
        [ "$status" -ne 0 ]
    done
}

# --- G3: the assertions are proven by mutating the CODE ----------------------

@test "G3 self-test: reporting an unwireable Codex as 'skipped' makes AE10's assertion go red" {
    # The defect R11 was reworded to forbid: an installed harness that cannot be
    # wired is quietly demoted to "not installed", and the run goes green having
    # wired nothing.
    local script
    script="$(mutant setup.sh '/does not load, so it cannot be wired/s|.*|                codex_here=0|')"
    grep -rqE '^ +codex_here=0$' "$(dirname "$script")"

    install_codex invalid
    plant_operator_codex_config

    run_wire --script "$script" --consent-shell-rc
    # Healthy behaviour is exit 2 with codex absent from `skipped`. With the
    # mutation live, the run succeeds and reports it as skipped instead.
    [ "$RC" -eq 0 ]
    [ "$(jq -r '.ok' "$OUT")" = "true" ]
    jq -e '(.skipped // []) | map(.harness) | index("codex") != null' "$OUT" >/dev/null
    # ...so both halves of the healthy assertion are now false.
    run jq -e '.error | test("expected a value at line 12 column 9")' "$OUT"
    [ "$status" -ne 0 ]
}

@test "G3 self-test: branching on the doctor PROCESS EXIT makes the network-failure case go red" {
    # KTD20's whole reason for existing. The mutation is the obvious, wrong
    # implementation: trust `$?`. It reports a valid config as broken on any
    # machine whose network check fails — which includes every machine where the
    # gateway is not started yet.
    local script
    script="$(mutant setup.sh '/# rc is READ but never branched on/s|.*|    if [ "$rc" -ne 0 ]; then CODEX_LOAD_STATUS="error"; CODEX_LOAD_DETAIL="codex doctor exited $rc"; rm -f "$out" 2>/dev/null; return 0; fi|')"
    grep -rqF 'if [ "$rc" -ne 0 ]; then CODEX_LOAD_STATUS="error"' "$(dirname "$script")"

    install_codex net_fail

    run_wire --script "$script"
    # Healthy behaviour on this exact fixture is exit 0 — config.load passes.
    [ "$RC" -eq 2 ]
    jq -e '.error | test("codex doctor exited 3")' "$OUT" >/dev/null
    # And the wiring the healthy path completes is gone.
    [ ! -e "$SPAWN_CODEX_CONFIG" ]
}

@test "G3 self-test: emitting the block without validating it at all makes R25's assertion go red" {
    # The third wrong-success shape in this verb: write the config, report
    # success, and let the harness discover the problem mid-task.
    local script
    script="$(mutant setup.sh '/^        codex_config_load_status$/s|.*|        CODEX_LOAD_STATUS=ok; CODEX_LOAD_DETAIL=unchecked|')"
    grep -rqF 'CODEX_LOAD_STATUS=ok; CODEX_LOAD_DETAIL=unchecked' "$(dirname "$script")"

    install_codex invalid
    [ ! -e "$SPAWN_CODEX_CONFIG" ]

    run_wire --script "$script"
    # Healthy behaviour is exit 2 with the file removed again.
    [ "$RC" -eq 0 ]
    [ "$(jq -r '.ok' "$OUT")" = "true" ]
    [ -f "$SPAWN_CODEX_CONFIG" ]
}
