#!/usr/bin/env bats
# U4 — the contract, answerable at runtime.
#
# WHAT THIS SUITE IS FOR
# ----------------------
# The plugin's real consumer runs with `allowed-tools: Bash, Read`. It cannot
# load a skill or a slash command, so every affordance written only into
# markdown is invisible to it: it hard-codes an exit table from whatever it was
# told once, and drifts. `--describe` is that table as DATA, and this suite
# pins the three properties that make it worth trusting:
#
#   1. it answers under the conditions a caller needs it — gateway down, no
#      config, no install — because a contract is read in order to interpret a
#      FAILURE, and one that needed a healthy gateway would be missing then;
#   2. what it declares is what the script actually is (the EX_* constants it
#      defines, the remedies its own table returns);
#   3. it agrees with the command bodies on NAMED FIELDS — not on prose.
#
# Everything is asserted on a RUN, never on source text, except where the
# assertion is explicitly about the source (the EX_* constants, the no-spend
# lint). The two agreement self-tests plant a rename — one on each side — and
# require the agreement check to go RED, because a detector never seen failing
# is a detector that proves nothing.

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    LIB="$ROOT/lib"
    CMD_DIR="$ROOT/commands"
    FIX="$(cd "$BATS_TEST_DIRNAME/../fixtures" && pwd)"
    LENS="$LIB/lens.sh"
    LAUNCH="$LIB/launch.sh"
    CTL="$LIB/spawnctl.sh"
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/gw-describe.XXXXXX")"
    WORK="$(cd "$WORK" && pwd -P)"
    GW_PID=""
    TOKEN="tok-describe-s3cr3t-7c4e"

    # Same isolation lens.bats sets: state and search root inside $WORK so no
    # test touches ~/.gateway.pid or discovers the real ~/gateway-* install, and
    # an own TMPDIR so a leftover from an unrelated run is not mistaken for a
    # leak from this one.
    export SPAWN_STATE_HOME="$WORK"
    export SPAWN_SEARCH_ROOT="$WORK/searchroot"
    mkdir -p "$SPAWN_SEARCH_ROOT"
    export TMPDIR="$WORK/tmp"
    mkdir -p "$TMPDIR"
    export SPAWN_CONNECT_TIMEOUT=2
    export SPAWN_PROBE_TIMEOUT=5
    export SPAWN_START_TIMEOUT=10
    export SPAWN_LOCK_TIMEOUT=30
    # NO CONFIG, NO INSTALL. This is not incidental setup — it is the condition
    # scenario 3 is about, and it holds for every test in the file.
    unset SPAWN_INSTALL_DIR SPAWN_CONFIG SPAWN_MODELS_JSON
    unset SPAWN_LENS_TIMEOUT SPAWN_SPILL_BYTES SPAWN_LENS_MAX_TOKENS
    unset SPAWN_LAUNCH_TIMEOUT
    # A port nothing serves. A test that forgets to point somewhere must not
    # probe the REAL gateway on 4000.
    export SPAWN_BASE_URL="http://127.0.0.1:1/anthropic"

    SCRIPTS=("$LENS" "$LAUNCH" "$CTL")
}

teardown() {
    if [ -n "${GW_PID:-}" ]; then
        kill "$GW_PID" 2>/dev/null || true
        wait "$GW_PID" 2>/dev/null || true
    fi
    for p in $(pgrep -f "$WORK" 2>/dev/null); do
        [ "$p" = "$$" ] && continue
        kill -9 "$p" 2>/dev/null
    done
    rm -rf "$WORK"
}

# --- helpers ---------------------------------------------------------------

# NEGATIVE ASSERTIONS. bats runs under `set -e`, but POSIX exempts a pipeline
# beginning with `!` from it, so `! grep -q ...` never fails a test — a shape
# that already let a token-leak assertion pass over genuinely leaking code in
# this repo. These fail as PLAIN commands, which set -e does honour. Same
# reasoning as launch.bats' refute_ helpers.
refute_match() {        # <extended-regex> <string>
    if printf '%s' "$2" | grep -qE -- "$1"; then
        printf 'refute_match: unexpected match for %s in:\n%s\n' "$1" "$2" >&2
        return 1
    fi
    return 0
}

describe_of() {         # <script> — prints the describe object, fails if not exit 0
    local out rc
    out="$(bash "$1" --describe 2>/dev/null)"; rc=$?
    [ "$rc" -eq 0 ] || { printf 'describe_of: %s exited %s\n' "$1" "$rc" >&2; return 1; }
    printf '%s' "$out"
}

# The command body each script's contract is also written into. One place, so a
# fourth surface is added here rather than in five tests.
command_for() {         # <script>
    case "$(basename "$1")" in
        lens.sh)     printf '%s' "$CMD_DIR/agent.md" ;;
        launch.sh)   printf '%s' "$CMD_DIR/session.md" ;;
        spawnctl.sh) printf '%s' "$CMD_DIR/report.md" ;;
        *) return 1 ;;
    esac
}

# --- the agreement check (R14) ---------------------------------------------
#
# The canonical statement is `--describe`; the command body is a PROJECTION of
# it. The check compares NAMES, never prose:
#
#   * the exit codes the command documents against the codes declared;
#   * every backticked identifier in the body against the names declared — a
#     response field, an error value, a verb, a drift class or a drift entry
#     field.
#
# TWO NAMES ARE EXEMPT, both because they belong to a FOREIGN surface:
#   is_error      — a field of the `claude` CLI's own JSON, which session.md
#                   quotes when it explains why a seed run was refused;
#   gateway.yaml  — the gateway's config FILE, not a field of any response.
# The staleness guard below fails if either stops appearing, so the exemption
# cannot outlive its reason.
AGREEMENT_EXEMPT="is_error gateway.yaml"

declared_names() {      # <describe json>
    printf '%s' "$1" | jq -r '
        [ (.response_fields[]?.name), (.error_values[]?.value),
          (.verbs[]?.name), (.drift_kinds[]?.name), (.drift_entry_fields[]?) ]
        | .[]' | sort -u
}

doc_code_lines() {      # <command md>
    grep -E '^[[:space:]]*- \*\*[0-9]\*\*' "$1"
}

doc_codes() {           # <command md>
    doc_code_lines "$1" | sed -E 's/^[^0-9]*([0-9]).*/\1/' | sort -u
}

# Backticked identifiers anywhere in the body, normalized: everything from the
# first `:` or space is dropped (`running: false` -> `running`), so the token is
# the NAME a caller would read out of the JSON.
#
# The WHOLE body is scanned, not just the exit-code lines. The fields a caller
# actually reads are documented in the step that tells it what to do with a
# successful answer (`text` and `output_file` in agent.md, the handle fields in
# session.md), and a scan that stopped at the exit table would have declared
# agreement while the two surfaces disagreed on exactly those names.
#
# Only LOWER-case identifiers count. An upper-case token is an environment
# variable (SPAWN_LAUNCH_TIMEOUT) or a character class, never a response field;
# a token starting with `-` or `/` is a flag or a slash command. None of those
# are names --describe declares, and demanding they be declared would push
# junk into the contract to satisfy a lint.
doc_tokens() {          # <command md>
    grep -oE '`[^`]+`' "$1" | tr -d '`' \
        | sed -E 's/[: ].*$//' | grep -E '^[a-z][a-z0-9_.-]*$' | sort -u
}

# agreement_check <describe json> <command md> <code-mode: equal|subset>
# Prints every disagreement; returns 1 if there was one.
agreement_check() {
    local desc="$1" md="$2" mode="$3" found=0
    local names t first
    names="$(declared_names "$desc")"

    # 1. exit codes.
    local declared_codes doc_c
    declared_codes="$(printf '%s' "$desc" | jq -r '.exit_codes[].code' | sort -u)"
    doc_c="$(doc_codes "$md")"
    for t in $doc_c; do
        printf '%s\n' "$declared_codes" | grep -qx "$t" || {
            printf 'AGREEMENT: %s documents exit %s, which --describe does not declare\n' "$(basename "$md")" "$t"
            found=1; }
    done
    if [ "$mode" = "equal" ]; then
        for t in $declared_codes; do
            printf '%s\n' "$doc_c" | grep -qx "$t" || {
                printf 'AGREEMENT: --describe declares exit %s, which %s does not document\n' "$t" "$(basename "$md")"
                found=1; }
        done
    fi

    # 2. names.
    for t in $(doc_tokens "$md"); do
        case " $AGREEMENT_EXEMPT " in *" $t "*) continue ;; esac
        if printf '%s\n' "$names" | grep -qx "$t"; then continue; fi
        first="${t%%.*}"
        if [ "$first" != "$t" ] && printf '%s\n' "$names" | grep -qx "$first"; then continue; fi
        printf 'AGREEMENT: %s names `%s`, which --describe does not declare\n' "$(basename "$md")" "$t"
        found=1
    done

    # 3. the other direction, on the one code where the command tells a caller
    #    to read `error` rather than the code: every error value declared at
    #    exit 5 must be named in the body. A sub-class renamed in the script and
    #    not in the command leaves a caller branching on a value that no longer
    #    exists.
    if [ "$mode" = "equal" ]; then
        for t in $(printf '%s' "$desc" | jq -r '.error_values[] | select(.exit_code == 5) | .value'); do
            grep -qF -- "\`$t\`" "$md" || {
                printf 'AGREEMENT: --describe declares error value `%s` at exit 5, which %s never names\n' "$t" "$(basename "$md")"
                found=1; }
        done
    fi
    return $found
}

start_fixture() {       # <scenario> <aliases> [extra fixture args]
    local scenario="$1" aliases="$2"; shift 2
    local portfile="$WORK/port"
    rm -f "$portfile"
    python3 "$FIX/fake-gateway.py" \
        --token "$TOKEN" --aliases "$aliases" --scenario "$scenario" \
        --port-file "$portfile" "$@" >"$WORK/gw.out" 2>"$WORK/gw.err" &
    GW_PID=$!
    local i
    for i in $(seq 1 100); do
        [ -s "$portfile" ] && break
        sleep 0.05
    done
    PORT="$(cat "$portfile")"
    [ -n "$PORT" ]
    export SPAWN_BASE_URL="http://127.0.0.1:$PORT/anthropic"
    {
        printf 'server:\n'
        printf '  bind: "127.0.0.1:%s"\n' "$PORT"
        printf '  token: %s\n' "$TOKEN"
        printf '\nmodels:\n'
        local a
        for a in ${aliases//,/ }; do
            printf '  %s:\n' "$a"
            printf '    model: up/%s\n' "$a"
        done
    } > "$WORK/gateway.yaml"
    export SPAWN_CONFIG="$WORK/gateway.yaml"
}

# --- R10: --describe answers, at exit 0, under the worst conditions --------

@test "R10 — every script answers --describe at exit 0 with one describe object" {
    local s
    for s in "${SCRIPTS[@]}"; do
        run bash "$s" --describe
        [ "$status" -eq 0 ]
        [ "$(printf '%s' "$output" | jq -s 'length')" = "1" ]
        [ "$(printf '%s' "$output" | jq -r '.ok')" = "true" ]
        [ "$(printf '%s' "$output" | jq -r '.error')" = "null" ]
        [ "$(printf '%s' "$output" | jq -r '.exit_code')" = "0" ]
        [ "$(printf '%s' "$output" | jq -r '.response_kind')" = "describe" ]
        [ "$(printf '%s' "$output" | jq -r '.surface')" = "$(basename "$s")" ]
        # The envelope is unchanged — describe adds fields, it does not alter it.
        printf '%s' "$output" | jq -e '
            has("schema") and has("ok") and has("error") and has("remedy")
            and has("content_trust") and has("content_notice") and has("exit_code")' >/dev/null
        [ "$(printf '%s' "$output" | jq -r '.schema')" = "spawn.response/v1" ]
    done
}

@test "R10 — --describe answers with the gateway DOWN and no config anywhere" {
    # setup already unsets SPAWN_CONFIG/SPAWN_INSTALL_DIR and points the search
    # root at an empty directory, so nothing on this box can be resolved. This
    # is the state a caller is in when it most needs the contract: it is trying
    # to work out what the failure it just got means.
    [ ! -e "$SPAWN_SEARCH_ROOT/gateway" ]
    local s
    for s in "${SCRIPTS[@]}"; do
        run env SPAWN_BASE_URL="http://127.0.0.1:1/anthropic" bash "$s" --describe
        [ "$status" -eq 0 ]
        [ "$(printf '%s' "$output" | jq -r '.response_kind')" = "describe" ]
        # It must declare a usable contract, not an empty shell.
        [ "$(printf '%s' "$output" | jq -r '.exit_codes | length')" -ge 5 ]
        [ "$(printf '%s' "$output" | jq -r '.response_fields | length')" -ge 8 ]
        [ "$(printf '%s' "$output" | jq -r '.error_values | length')" -ge 4 ]
    done
}

@test "R10 — --describe answers fast, with no gateway probe in the path" {
    # A describe that fell through to preflight would sit on the connect
    # timeout and the start lock. Bounded generously (the box is shared with a
    # full suite) but far below the probe + start budget, so a regression that
    # reintroduced the probe fails here rather than merely being slow.
    local s start elapsed
    for s in "${SCRIPTS[@]}"; do
        start="$(date +%s)"
        run bash "$s" --describe
        elapsed=$(( $(date +%s) - start ))
        [ "$status" -eq 0 ]
        [ "$elapsed" -lt 10 ]
    done
}

@test "R10 — the declared exit enum matches the EX_* constants the script defines" {
    # `own` versus `propagated` is the load-bearing distinction. lens.sh and
    # launch.sh can EXIT 4 (and launch 7) without defining the constant: the
    # code comes from `spawnctl ensure` and propagates unchanged (KTD3). So the
    # assertion is exact on the codes the script produces itself, and the
    # propagated ones are declared and named as such.
    local s defined own
    for s in "${SCRIPTS[@]}"; do
        defined="$(grep -E '^EX_[A-Z]+=[0-9]+' "$s" | sed -E 's/.*=([0-9]+).*/\1/' | sort -u)"
        [ -n "$defined" ]
        own="$(describe_of "$s" | jq -r '.exit_codes[] | select(.origin == "own") | .code' | sort -u)"
        [ "$defined" = "$own" ]
        # Nothing outside the frozen enum, whatever its origin (KTD2).
        run bash -c "describe=\$(bash '$s' --describe 2>/dev/null); printf '%s' \"\$describe\" | jq -e 'all(.exit_codes[].code; . == 0 or . == 2 or . == 3 or . == 4 or . == 5 or . == 6 or . == 7)'"
        [ "$status" -eq 0 ]
        # Every propagated code says where it comes from.
        describe_of "$s" | jq -e 'all(.exit_codes[]; .origin == "own" or .origin == "propagated")' >/dev/null
    done
}

# --- R11 / AE6: help is distinguishable from a usage error -----------------

@test "AE6 — --help and a usage error are distinguishable by a FIELD, and both still exit 2" {
    # lens: help, then a genuinely wrong call.
    run bash -c "bash '$LENS' --help 2>/dev/null"
    [ "$status" -eq 2 ]
    [ "$(printf '%s' "$output" | jq -r '.help_requested')" = "true" ]
    [ "$(printf '%s' "$output" | jq -r '.error')" = "usage" ]

    run bash -c "bash '$LENS' --alias 'bad;alias' < /dev/null 2>/dev/null"
    [ "$status" -eq 2 ]
    [ "$(printf '%s' "$output" | jq -r '.help_requested')" = "false" ]
    [ "$(printf '%s' "$output" | jq -r '.error')" = "usage" ]

    # launch
    run bash -c "bash '$LAUNCH' -h 2>/dev/null"
    [ "$status" -eq 2 ]
    [ "$(printf '%s' "$output" | jq -r '.help_requested')" = "true" ]
    run bash -c "bash '$LAUNCH' --alias 'bad;alias' < /dev/null 2>/dev/null"
    [ "$status" -eq 2 ]
    [ "$(printf '%s' "$output" | jq -r '.help_requested')" = "false" ]

    # spawnctl
    run bash -c "bash '$CTL' --help 2>/dev/null"
    [ "$status" -eq 2 ]
    [ "$(printf '%s' "$output" | jq -r '.help_requested')" = "true" ]
    run bash -c "bash '$CTL' no-such-verb 2>/dev/null"
    [ "$status" -eq 2 ]
    [ "$(printf '%s' "$output" | jq -r '.help_requested')" = "false" ]
}

@test "R11 — spawnctl's MISSING verb is a usage error, not a help request" {
    # These two used to share one case arm, which made the discriminator lie on
    # the most common way to misuse this script: forgetting the verb entirely is
    # a caller bug, and nobody asked for help.
    run bash -c "bash '$CTL' 2>/dev/null"
    [ "$status" -eq 2 ]
    [ "$(printf '%s' "$output" | jq -r '.help_requested')" = "false" ]
    [ "$(printf '%s' "$output" | jq -r '.error')" = "usage" ]
}

@test "R11 — the discriminator survives the no-jq tier" {
    # The tier nobody runs is the tier that drifts. With no encoder on PATH a
    # consumer still gets one object, and it can still tell help from a bug.
    local d="$WORK/nojq" t p
    mkdir -p "$d"
    for t in bash sh curl sed awk grep cat wc tr cut head tail sort mktemp \
             dirname basename mkdir rm cp mv chmod find kill sleep date uname \
             stat python3 pgrep ps; do
        p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$d/$t"
    done
    run env PATH="$d" bash "$LENS" --help
    [ "$status" -eq 2 ]
    run bash -c "printf '%s' '$output' | grep -qF '\"help_requested\":true'"
    [ "$status" -eq 0 ]

    run env PATH="$d" bash -c "bash '$LENS' --alias 'bad;alias' < /dev/null"
    [ "$status" -eq 2 ]
    run bash -c "printf '%s' '$output' | grep -qF '\"help_requested\":false'"
    [ "$status" -eq 0 ]
}

@test "R11 — --describe declares help_requested, so a consumer knows to look for it" {
    local s
    for s in "${SCRIPTS[@]}"; do
        describe_of "$s" | jq -e '[.response_fields[].name] | index("help_requested") != null' >/dev/null
        describe_of "$s" | jq -e '[.flags[].name] | index("--help") != null' >/dev/null
        describe_of "$s" | jq -e '[.flags[].name] | index("--describe") != null' >/dev/null
    done
}

# --- R12: every error names its remedy -------------------------------------

@test "R12 — every declared error value carries a non-empty remedy" {
    local s
    for s in "${SCRIPTS[@]}"; do
        [ "$(describe_of "$s" | jq -r '.error_values | length')" -ge 4 ]
        describe_of "$s" | jq -e 'all(.error_values[]; (.value | test("^[a-z][a-z0-9_]*$"))
                                     and (.remedy != null) and (.remedy | length > 20))' >/dev/null
    done
}

@test "R12 — a real failing run carries a non-empty remedy, on every script" {
    # Asserted on RUNS, not on the describe document: the point of R12 is what
    # the caller holds when something broke, not what the contract promises.
    run bash -c "bash '$LENS' --alias 'bad;alias' < /dev/null 2>/dev/null"
    [ "$status" -eq 2 ]
    [ -n "$(printf '%s' "$output" | jq -r '.remedy // empty')" ]

    run bash -c "printf 'hi' | bash '$LENS' --alias alpha 2>/dev/null"
    [ "$status" -ne 0 ]
    [ -n "$(printf '%s' "$output" | jq -r '.remedy // empty')" ]

    run bash -c "bash '$LAUNCH' --alias 'bad;alias' < /dev/null 2>/dev/null"
    [ "$status" -eq 2 ]
    [ -n "$(printf '%s' "$output" | jq -r '.remedy // empty')" ]

    run bash -c "bash '$CTL' status 2>/dev/null"
    [ "$status" -eq 3 ]
    [ -n "$(printf '%s' "$output" | jq -r '.remedy // empty')" ]

    run bash -c "bash '$CTL' no-such-verb 2>/dev/null"
    [ "$status" -eq 2 ]
    [ -n "$(printf '%s' "$output" | jq -r '.remedy // empty')" ]
}

@test "R12 — the remedy for a truncated answer differs from the one for an empty answer" {
    # The two values exist BECAUSE the repair differs. If both ended up with the
    # same remedy the split would be decorative, and a caller would raise
    # --max-tokens against a model that simply said nothing.
    local trunc empty
    trunc="$(describe_of "$LENS" | jq -r '.error_values[] | select(.value=="no_text_truncated") | .remedy')"
    empty="$(describe_of "$LENS" | jq -r '.error_values[] | select(.value=="no_text_in_response") | .remedy')"
    [ -n "$trunc" ] && [ -n "$empty" ]
    [ "$trunc" != "$empty" ]
    printf '%s' "$trunc" | grep -qF -- '--max-tokens'
    # ...and the empty case must not tell a caller to raise it, which is the
    # advice that would waste the retry.
    refute_match 'Raise --max-tokens' "$empty"
}

@test "R12 — success carries no remedy" {
    start_fixture healthy "alpha" --response-text "an answer"
    run bash -c "printf 'hi' | bash '$LENS' --alias alpha 2>/dev/null"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.remedy')" = "null" ]
    [ "$(printf '%s' "$output" | jq -r '.error')" = "null" ]
}

@test "R7 — the no-spend lint still passes over the new prose" {
    # The lens source may not carry the vocabulary of spend logic (KD2 settles
    # that this plugin has none). The remedies and the describe document are new
    # PROSE inside that source, which is exactly where the words would creep in.
    # Both the source and what it actually prints are checked: a word could
    # otherwise arrive through common.sh's shared remedy table, which the source
    # lint does not read.
    run bash -c "sed 's/#.*//' '$LENS' | grep -inE 'spend|budget|cost|quota|dollar|usd|price'"
    [ "$status" -ne 0 ]
    local s
    for s in "${SCRIPTS[@]}"; do
        run bash -c "bash '$s' --describe 2>/dev/null | grep -inE 'spend|budget|cost|quota|dollar|usd|price'"
        [ "$status" -ne 0 ]
    done
    run bash -c "bash '$LENS' --help 2>/dev/null | grep -inE 'spend|budget|cost|quota|dollar|usd|price'"
    [ "$status" -ne 0 ]
}

# --- R13: the lens states what the model could see -------------------------

@test "R13 — the lens's answer states that the model saw one message and had no tools" {
    start_fixture healthy "alpha" --response-text "an answer"
    run bash -c "printf 'hi' | bash '$LENS' --alias alpha 2>/dev/null"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.model_scope')" = "single-message-no-tools" ]
    [ "$(printf '%s' "$output" | jq -r '.model_scope_notice | length > 40')" = "true" ]
    # It is a CONSTANT, like content_trust: the far side contributes no byte of
    # it, so a model cannot claim to have looked at the repository.
    printf '%s' "$output" | jq -e '.model_scope_notice | test("no tools")' >/dev/null
}

@test "R13 — a spilled answer carries the same statement as an inline one" {
    start_fixture healthy "alpha" --response-text "$(printf 'x%.0s' $(seq 1 200))"
    run bash -c "SPAWN_SPILL_BYTES=10 SPAWN_CONFIG='$SPAWN_CONFIG' SPAWN_BASE_URL='$SPAWN_BASE_URL' printf 'hi' | SPAWN_SPILL_BYTES=10 bash '$LENS' --alias alpha --output-file '$WORK/answer.txt' 2>/dev/null"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.text')" = "null" ]
    [ "$(printf '%s' "$output" | jq -r '.model_scope')" = "single-message-no-tools" ]
}

@test "R13 — --describe declares the same statement, so it is readable before any call" {
    local d
    d="$(describe_of "$LENS")"
    [ "$(printf '%s' "$d" | jq -r '.model_scope')" = "single-message-no-tools" ]
    [ "$(printf '%s' "$d" | jq -r '.tools_on_far_side')" = "false" ]
    [ "$(printf '%s' "$d" | jq -r '.turns')" = "1" ]
    printf '%s' "$d" | jq -e '[.response_fields[].name] | index("model_scope") != null' >/dev/null
}

# --- R14: the projections agree, on names ----------------------------------

@test "R14 — lens.sh --describe and commands/agent.md agree on codes and names" {
    run agreement_check "$(describe_of "$LENS")" "$CMD_DIR/agent.md" equal
    [ "$status" -eq 0 ] || printf '%s\n' "$output" >&2
    [ "$status" -eq 0 ]
}

@test "R14 — launch.sh --describe and commands/session.md agree on codes and names" {
    run agreement_check "$(describe_of "$LAUNCH")" "$CMD_DIR/session.md" equal
    [ "$status" -eq 0 ] || printf '%s\n' "$output" >&2
    [ "$status" -eq 0 ]
}

@test "R14 — spawnctl.sh --describe and commands/report.md agree on codes and names" {
    # SUBSET on the codes, not equality: report.md documents the `status` verb's
    # answers for a human, and exit 4 belongs to `ensure`, which that command
    # never runs. Every code it DOES document must be declared, and every name
    # it uses must exist — which is what a caller reading it would rely on.
    run agreement_check "$(describe_of "$CTL")" "$CMD_DIR/report.md" subset
    [ "$status" -eq 0 ] || printf '%s\n' "$output" >&2
    [ "$status" -eq 0 ]
}

@test "R14 — the exempted names are still present, so the exemption cannot outlive its reason" {
    # An exemption list that nothing checks becomes a list of names nobody
    # remembers exempting. Each entry must still appear in some command body;
    # when the prose that needed it goes, the entry has to go with it.
    local t hits
    for t in $AGREEMENT_EXEMPT; do
        hits="$(grep -lF -- "\`$t\`" "$CMD_DIR"/*.md | wc -l | tr -d ' ')"
        [ "$hits" -ge 1 ]
    done
}

@test "R14 self-test — the agreement check goes RED when the COMMAND renames a field" {
    # A detector never seen failing proves nothing. Planted on the command side:
    # somebody edits agent.md to say `spill_path` while the script still emits
    # `output_file`, and a caller written from the command reads null forever.
    cp "$CMD_DIR/agent.md" "$WORK/agent.md"
    sed -i.bak 's/`output_file`/`spill_path`/g' "$WORK/agent.md"
    run agreement_check "$(describe_of "$LENS")" "$WORK/agent.md" equal
    [ "$status" -ne 0 ]
    printf '%s' "$output" | grep -qF 'spill_path'
    # ...and the untouched original still passes, so the failure is the rename.
    run agreement_check "$(describe_of "$LENS")" "$CMD_DIR/agent.md" equal
    [ "$status" -eq 0 ]
}

@test "R14 self-test — the agreement check goes RED when the SCRIPT renames a field" {
    # The other direction, which is the one that actually happens: a field is
    # renamed in the emitting script and the markdown is forgotten.
    mkdir -p "$WORK/lib"
    cp "$LIB"/*.sh "$WORK/lib/"
    [ -f "$LIB/models.json" ] && cp "$LIB/models.json" "$WORK/lib/"
    sed -i.bak 's/{name:"output_file",/{name:"spill_path",/' "$WORK/lib/lens.sh"
    # The rename must have landed, or this test would pass vacuously.
    run bash -c "bash '$WORK/lib/lens.sh' --describe 2>/dev/null | jq -e '[.response_fields[].name] | index(\"spill_path\") != null'"
    [ "$status" -eq 0 ]

    run agreement_check "$(describe_of "$WORK/lib/lens.sh")" "$CMD_DIR/agent.md" equal
    [ "$status" -ne 0 ]
    printf '%s' "$output" | grep -qF 'output_file'
}

@test "R14 self-test — the agreement check goes RED when the SCRIPT drops an exit code" {
    mkdir -p "$WORK/lib2"
    cp "$LIB"/*.sh "$WORK/lib2/"
    [ -f "$LIB/models.json" ] && cp "$LIB/models.json" "$WORK/lib2/"
    # Drop the propagated exit 4 from the declaration only. The script still
    # returns 4 (ensure decides it), so this is precisely the silent divergence
    # a caller cannot see.
    sed -i.bak '/{code:4, error:"alias_unknown",    origin:"propagated",/,+1d' "$WORK/lib2/lens.sh"
    run bash -c "bash '$WORK/lib2/lens.sh' --describe 2>/dev/null | jq -e '[.exit_codes[].code] | index(4) == null'"
    [ "$status" -eq 0 ]

    run agreement_check "$(describe_of "$WORK/lib2/lens.sh")" "$CMD_DIR/agent.md" equal
    [ "$status" -ne 0 ]
    printf '%s' "$output" | grep -qF 'exit 4'
}
