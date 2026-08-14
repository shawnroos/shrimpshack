#!/usr/bin/env bats
# U8 — two entry points, two ceilings (R8, R25; AE4, AE10).
#
# THE ASSERTION RULE FOR THIS SUITE
# ---------------------------------
# Assert by FILE SIDE-EFFECT or by the flags actually handed to the child.
# NEVER on the model's prose. In the spike a text assertion passed in BOTH arms
# because the model quotes the command back while explaining that it cannot run
# it — the marker string appeared in the refusal. That trap is why every
# assertion below is on a record the model did not author: the fixture's argv
# log, the rendered permission file, or a file that either exists or does not.
#
# WHAT RUNS AGAINST WHAT
# ----------------------
# The DOOR tests run against tests/fixtures/fake-claude.sh and
# fake-gateway.py: which ceiling a door hands down is decided entirely by the
# door, so a real CLI would add spend and network flakiness and prove nothing
# extra. What the HARNESS does with that ceiling is not the plugin's code and
# cannot be faked, so the arms that measure enforcement — AE10, and the control
# pair that proves a child is genuinely narrower than its launcher — run the
# REAL `claude`. Those are opt-in behind SPAWN_CEILING_LIVE=1 because they cost
# money and a network on every unit run; they are written to be run, and they
# were, against this exact code:
#
#   control (allow Bash)              -> sentinel file CREATED
#   repo-bounded ceiling              -> no file; Bash refused, exit 0, is_error false
#   repo-bounded, write normal file   -> CREATED
#   repo-bounded, write .git hook     -> DENIED
#   repo-bounded, write .claude file  -> DENIED
#   repo-bounded, write via symlink resolving outside the tree -> DENIED
#
# Failure classes are asserted on EXIT CODES, not messages (Verification
# Contract): a caller branches on the number, so the number is what is pinned.

setup() {
    FIX="$(cd "$BATS_TEST_DIRNAME/../fixtures" && pwd)"
    LIB="$(cd "$BATS_TEST_DIRNAME/../../lib" && pwd)"
    PERMS="$(cd "$BATS_TEST_DIRNAME/../../permissions" && pwd)"
    OPERATOR="$LIB/bg-operator.sh"
    REPO="$LIB/bg-repo.sh"

    WORK="$(mktemp -d "${TMPDIR:-/tmp}/gw-ceil.XXXXXX")"
    # PHYSICAL path. On macOS /tmp is a symlink to /private/tmp, and the
    # rendered permission rules are matched against the path the CLI resolves —
    # a logical path here would compare unequal for a reason that has nothing
    # to do with the code.
    WORK="$(cd "$WORK" && pwd -P)"
    TOKEN="tok-ceil-s3cr3t-9f2a"
    GW_PID=""

    export SPAWN_STATE_HOME="$WORK"
    export SPAWN_SEARCH_ROOT="$WORK/searchroot"; mkdir -p "$SPAWN_SEARCH_ROOT"
    export TMPDIR="$WORK/tmp"; mkdir -p "$TMPDIR"
    export SPAWN_CONNECT_TIMEOUT=2
    export SPAWN_PROBE_TIMEOUT=5
    export SPAWN_START_TIMEOUT=10
    export SPAWN_LOCK_TIMEOUT=30
    unset SPAWN_INSTALL_DIR SPAWN_CONFIG SPAWN_MODELS_JSON SPAWN_CLAUDE_BIN
    unset SPAWN_BG_TIMEOUT SPAWN_CEILING_CONFIG_OPERATOR SPAWN_CEILING_CONFIG_REPO SPAWN_CEILING_DIR
    # Credential inputs: a real GATEWAY_TOKEN in the developer's or CI's shell
    # would otherwise decide what a "nothing is resolvable" test measures. Each
    # test sets what it needs; none may inherit it.
    unset GATEWAY_TOKEN SPAWN_KEYCHAIN_SERVICE SPAWN_KEYCHAIN_ACCOUNT_TOKEN
    # A test that forgets to point somewhere must not probe the REAL gateway.
    export SPAWN_BASE_URL="http://127.0.0.1:1/anthropic"

    export CLAUDE_CONFIG_DIR="$WORK/claude-home"; mkdir -p "$CLAUDE_CONFIG_DIR"
    export FAKE_CLAUDE_RECORD_DIR="$WORK/rec"; mkdir -p "$FAKE_CLAUDE_RECORD_DIR"
    unset FAKE_CLAUDE_MODE FAKE_CLAUDE_SESSION_ID FAKE_CLAUDE_PROJECTS_ROOT

    # The REAL binary, resolved BEFORE the fixture is put on PATH — the live
    # arms below need the actual CLI, and after the next three lines a bare
    # `claude` is the fixture. Resolving it later is how a live arm silently
    # measures the fake and reports a green that means nothing.
    REAL_CLAUDE="$(command -v claude 2>/dev/null || true)"

    mkdir -p "$WORK/bin"
    ln -sf "$FIX/fake-claude.sh" "$WORK/bin/claude"
    export PATH="$WORK/bin:$PATH"

    # A real git worktree: the repo-bounded ceiling is scoped to
    # `git rev-parse --show-toplevel`, and testing on a bare directory would
    # exercise the fallback and leave the property R25 turns on unproven.
    PROJ="$WORK/proj"; mkdir -p "$PROJ"; ( cd "$PROJ" && git init -q . )
    PROJ="$(cd "$PROJ" && pwd -P)"

    # The shipped defaults must survive every run untouched (R25: the plugin
    # never writes a user's settings, and it does not write its own either).
    SHIPPED_SHA="$(cat "$PERMS"/*.json | shasum | awk '{print $1}')"
}

teardown() {
    if [ -n "${GW_PID:-}" ]; then
        kill "$GW_PID" 2>/dev/null || true
        wait "$GW_PID" 2>/dev/null || true
    fi
    # Leave no stray process: every fixture process this suite starts carries
    # $WORK in its argv.
    for p in $(pgrep -f "$WORK" 2>/dev/null); do
        [ "$p" = "$$" ] && continue
        kill -9 "$p" 2>/dev/null
    done
    rm -rf "$WORK"
}

# --- helpers ---------------------------------------------------------------

# NEGATIVE ASSERTIONS. bats runs under `set -e`, but POSIX exempts a pipeline
# beginning with `!` from it — so `! grep -q ...` never fails a test. These
# helpers fail as PLAIN commands, which set -e does honour.
refute_file_match() {   # <pattern> <file...>
    local pat="$1"; shift
    if grep -qF -- "$pat" "$@"; then
        printf 'refute_file_match: unexpected match for %s in %s\n' "$pat" "$*" >&2
        grep -nF -- "$pat" "$@" >&2
        return 1
    fi
    return 0
}
refute_exists() {       # <path>
    if [ -e "$1" ]; then
        printf 'refute_exists: %s exists and must not\n' "$1" >&2
        return 1
    fi
    return 0
}

make_config() {
    local path="$1" token="$2"; shift 2
    {
        printf 'server:\n'
        printf '  bind: "127.0.0.1:4000"\n'
        printf '  token: %s\n' "$token"
        printf '\nmodels:\n'
        local spec
        for spec in "$@"; do
            printf '  %s:\n' "${spec%%=*}"
            printf '    model: %s\n' "${spec#*=}"
        done
    } > "$path"
}

start_fixture() {   # <scenario> <aliases>
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

    local a
    local -a specs=() parts=()
    IFS=',' read -ra parts <<< "$aliases"
    for a in "${parts[@]}"; do specs+=("$a=up/$a"); done
    make_config "$WORK/gateway.yaml" "$TOKEN" "${specs[@]}"
    export SPAWN_CONFIG="$WORK/gateway.yaml"
}

# Run a door capturing STDOUT ONLY, prose on stdin, cwd pinned to $PROJ.
door() {    # <script> [args...]
    local script="$1"; shift
    run bash -c 'cd "$3" && printf "%s" "$1" | bash "$2" --cwd "$3" "${@:4}" 2>/dev/null' \
        _ "do the task" "$script" "$PROJ" "$@"
}

# Split the fixture's append-only argv record into per-invocation chunks.
invocation() {  # <record file> <1-based n>
    awk -v want="$2" '/^--- invocation /{n++; next} n==want' "$1"
}

# The rendered ceiling, obtained by calling the library directly. This is the
# artifact the harness is handed; asserting on it needs no CLI and no spend.
render() {  # <ceiling> <worktree> <dest>
    run bash -c '. "$1"; spawn::ceiling_render "$2" "$3" "$4"' _ "$LIB/ceilings.sh" "$1" "$2" "$3"
}

live_or_skip() {
    [ "${SPAWN_CEILING_LIVE:-0}" = "1" ] \
        || skip "live ceiling arms are opt-in: SPAWN_CEILING_LIVE=1 (they run the real claude and cost money)"
    [ -n "${REAL_CLAUDE:-}" ] && [ -x "$REAL_CLAUDE" ] || skip "no real claude on PATH"
}

# ===========================================================================
# AE4 — which door was run decides the ceiling
# ===========================================================================

@test "AE4: the operator door hands its child the operator configuration" {
    start_fixture healthy "alpha"
    door "$OPERATOR" --alias alpha
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.ceiling')" = "operator" ]
    # The operator is present and accountable, so their own sources are left
    # alone — that is the whole difference between the two doors.
    [ "$(printf '%s' "$output" | jq -r '.setting_sources')" = "null" ]
    [ "$(printf '%s' "$output" | jq -r '.ceiling_config')" = "$PERMS/operator.settings.json" ]

    # And the CHILD was actually invoked that way. The response is the door's
    # own account of itself; the argv record is not.
    invocation "$FAKE_CLAUDE_RECORD_DIR/argv" 1 > "$WORK/argv1"
    grep -qx -- '--settings' "$WORK/argv1"
    grep -qx -- '--permission-mode' "$WORK/argv1"
    grep -qx -- 'dontAsk' "$WORK/argv1"
    refute_file_match '--setting-sources' "$WORK/argv1"
}

@test "AE4: the agent door hands its child the repo-bounded configuration" {
    start_fixture healthy "alpha"
    door "$REPO" --alias alpha
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.ceiling')" = "repo-bounded" ]
    # Dropping `user` is the lever that makes the child narrower than its
    # launcher (measured — see the live arm below).
    [ "$(printf '%s' "$output" | jq -r '.setting_sources')" = "project" ]
    [ "$(printf '%s' "$output" | jq -r '.ceiling_config')" = "$PERMS/repo-bounded.settings.json" ]
    [ "$(printf '%s' "$output" | jq -r '.worktree')" = "$PROJ" ]

    invocation "$FAKE_CLAUDE_RECORD_DIR/argv" 1 > "$WORK/argv1"
    grep -qx -- '--setting-sources' "$WORK/argv1"
    grep -qx -- 'project' "$WORK/argv1"
    grep -qx -- '--settings' "$WORK/argv1"
}

@test "AE4/R8: the ceiling is not selectable — no argument reaches it" {
    start_fixture healthy "alpha"
    # A caller asserting its own identity is exactly what R8 rules out. The
    # flag does not exist, so it is a usage error, and the response still
    # reports the door's own ceiling.
    door "$REPO" --alias alpha --ceiling operator
    [ "$status" -eq 2 ]
    [ "$(printf '%s' "$output" | jq -r '.error')" = "usage" ]
    [ "$(printf '%s' "$output" | jq -r '.ceiling')" = "repo-bounded" ]
    # Structural, not behavioural: no source file may contain a parser branch
    # that assigns the ceiling from an argument. A future edit that adds one
    # turns this red rather than quietly re-opening the hole.
    # Comments stripped first: the header explains at length why the flag does
    # not exist, and a lint that reads its own rationale as a violation would
    # be satisfied by deleting the explanation.
    local f
    for f in "$LIB/ceilings.sh" "$OPERATOR" "$REPO"; do
        run bash -c "sed 's/#.*//' '$f' | grep -n -- '--ceiling'"
        [ "$status" -ne 0 ]
        run bash -c "sed 's/#.*//' '$f' | grep -nE 'CEILING=\\\$[0-9{]'"
        [ "$status" -ne 0 ]
    done
    # Each door fixes its ceiling as a constant and there is exactly one.
    [ "$(grep -c '^CEILING=' "$OPERATOR")" -eq 1 ]
    [ "$(grep -c '^CEILING=' "$REPO")" -eq 1 ]
    # ...and --describe says so in the data, for a caller that cannot read bash.
    run bash "$REPO" --describe
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.ceiling_selectable')" = "false" ]
}

# ===========================================================================
# R9 — no permission prompt is ever waited on
# ===========================================================================

@test "R9: both doors run the child in a mode where a prompt cannot park it" {
    start_fixture healthy "alpha"
    door "$OPERATOR" --alias alpha
    [ "$status" -eq 0 ]
    door "$REPO" --alias alpha
    [ "$status" -eq 0 ]

    local i
    for i in 1 2; do
        invocation "$FAKE_CLAUDE_RECORD_DIR/argv" "$i" > "$WORK/argv.$i"
        # The flag is present, and the VALUE is the one that refuses rather
        # than queues. `manual` would park an unattended job forever, and
        # `bypassPermissions` would make the ceiling decorative.
        grep -qx -- '--permission-mode' "$WORK/argv.$i"
        grep -qx -- 'dontAsk' "$WORK/argv.$i"
        refute_file_match 'bypassPermissions' "$WORK/argv.$i"
        refute_file_match 'manual' "$WORK/argv.$i"
        refute_file_match 'acceptEdits' "$WORK/argv.$i"
    done
    # And the shipped defaults say the same thing, for the case where a child
    # is launched by something other than these doors.
    [ "$(jq -r '.permissions.defaultMode' "$PERMS/operator.settings.json")" = "dontAsk" ]
    [ "$(jq -r '.permissions.defaultMode' "$PERMS/repo-bounded.settings.json")" = "dontAsk" ]
}

# ===========================================================================
# AE10 — what the repo-bounded ceiling actually says
# ===========================================================================

@test "AE10: the repo-bounded ceiling scopes writes to the worktree and denies hooks and agent config" {
    render "repo-bounded" "$PROJ" "$WORK/rendered.json"
    [ "$status" -eq 0 ]
    run jq -e . "$WORK/rendered.json"
    [ "$status" -eq 0 ]

    # A permission path is only ABSOLUTE when it begins with `//`. Measured: a
    # rule written /Users/... matched nothing and every write it was meant to
    # permit was refused, which reads exactly like a working deny. Pinned so a
    # renderer that drops the doubled slash goes red here.
    local wt="//${PROJ#/}"
    run jq -e --arg w "$wt/**" '.permissions.allow | index("Write(" + $w + ")")' "$WORK/rendered.json"
    [ "$status" -eq 0 ]
    run jq -e --arg w "$wt/**" '.permissions.allow | index("Edit(" + $w + ")")' "$WORK/rendered.json"
    [ "$status" -eq 0 ]
    # No placeholder survived the render.
    refute_file_match '{{WORKTREE}}' "$WORK/rendered.json"

    # Version-control hooks, agent configuration: denied for the write tools,
    # by path, on tools that stay PRESENT — so the call is attempted and
    # refused rather than never made. Measured caveat U9 needs: a DENY-RULE
    # refusal leaves no entry in the child's `permission_denials[]`, unlike an
    # unallowed call, so these three are detectable only by effect.
    local rule
    for rule in \
        'Write(//**/.git/**)' 'Edit(//**/.git/**)' \
        'Write(//**/.githooks/**)' \
        'Write(//**/.claude/**)' 'Edit(//**/.claude/**)' \
        'Write(//**/.claude-plugin/**)' \
        'Write(//**/CLAUDE.md)' 'Write(//**/AGENTS.md)' 'Write(//**/.mcp.json)' ; do
        run jq -e --arg r "$rule" '.permissions.deny | index($r)' "$WORK/rendered.json"
        if [ "$status" -ne 0 ]; then
            printf 'repo-bounded ceiling is missing deny rule: %s\n' "$rule" >&2
            return 1
        fi
    done

    # Bash is bounded by ABSENCE from the allow list, not by a tool-level deny.
    # A tool-level deny REMOVES the tool: the model reports having no such tool
    # and never attempts it, so there is nothing for a supervisor to observe.
    # This is a deliberate choice R9's degraded classification depends on.
    run jq -r '.permissions.allow | join(" ")' "$WORK/rendered.json"
    printf '%s' "$output" > "$WORK/allow.txt"
    refute_file_match 'Bash' "$WORK/allow.txt"
    run jq -r '.permissions.deny | join(" ")' "$WORK/rendered.json"
    printf '%s' "$output" > "$WORK/deny.txt"
    refute_file_match '"Bash"' "$WORK/deny.txt"

    # R25 denies EXECUTION-bearing paths, not readable ones: within its bound
    # the model still reads whatever the worktree contains.
    refute_file_match 'Read(//**/.git/**)' "$WORK/deny.txt"
}

@test "the operator ceiling does not scope the child at all — it is an override point" {
    render "operator" "$PROJ" "$WORK/op.json"
    [ "$status" -eq 0 ]
    # No allow list: the operator's own settings, loaded through their own
    # sources, are what governs. An allow here would NARROW the operator.
    run jq -r '.permissions.allow // "absent"' "$WORK/op.json"
    [ "$output" = "absent" ]
    run jq -r '.permissions.deny | length' "$WORK/op.json"
    [ "$output" = "0" ]
}

@test "an unknown ceiling resolves to nothing rather than to a guess" {
    run bash -c '. "$1"; spawn::ceiling_config "nonsense"' _ "$LIB/ceilings.sh"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
    render "nonsense" "$PROJ" "$WORK/nope.json"
    [ "$status" -ne 0 ]
    refute_exists "$WORK/nope.json"
}

# ===========================================================================
# R25 — the plugin ships defaults, the user overrides them, the plugin never
# writes anyone's settings
# ===========================================================================

@test "R25: a user override replaces the shipped default, and the shipped file is only read" {
    cat > "$WORK/mine.json" <<'EOF'
{"permissions":{"defaultMode":"dontAsk","allow":["Read(//{{WORKTREE}}/**)"],"deny":["Write(//**/.git/**)"]}}
EOF
    export SPAWN_CEILING_CONFIG_REPO="$WORK/mine.json"
    run bash -c '. "$1"; spawn::ceiling_config "repo-bounded"' _ "$LIB/ceilings.sh"
    [ "$output" = "$WORK/mine.json" ]

    render "repo-bounded" "$PROJ" "$WORK/mine.rendered.json"
    [ "$status" -eq 0 ]
    run jq -r '.permissions.allow | length' "$WORK/mine.rendered.json"
    [ "$output" = "1" ]

    start_fixture healthy "alpha"
    door "$REPO" --alias alpha
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.ceiling_config')" = "$WORK/mine.json" ]

    # Nothing wrote the override or the shipped defaults.
    [ "$(cat "$PERMS"/*.json | shasum | awk '{print $1}')" = "$SHIPPED_SHA" ]
    grep -qF '{{WORKTREE}}' "$WORK/mine.json"
}

@test "R25: a full run leaves the shipped defaults byte-identical" {
    start_fixture healthy "alpha"
    door "$OPERATOR" --alias alpha
    [ "$status" -eq 0 ]
    door "$REPO" --alias alpha
    [ "$status" -eq 0 ]
    export FAKE_CLAUDE_MODE=fail
    door "$REPO" --alias alpha
    [ "$status" -eq 5 ]
    [ "$(cat "$PERMS"/*.json | shasum | awk '{print $1}')" = "$SHIPPED_SHA" ]
}

@test "the rendered ceiling does not outlive the call" {
    start_fixture healthy "alpha"
    door "$REPO" --alias alpha
    [ "$status" -eq 0 ]
    local rendered
    rendered="$(printf '%s' "$output" | jq -r '.child_flags | .[index("--settings") + 1]')"
    [ -n "$rendered" ]
    refute_exists "$rendered"
    # Nothing was left under TMPDIR either.
    run bash -c 'ls -d "$1"/gwceil.* 2>/dev/null | wc -l' _ "$TMPDIR"
    [ "$(printf '%s' "$output" | tr -d ' ')" = "0" ]
}

# ===========================================================================
# The contract the doors share with every other script
# ===========================================================================

@test "R10/R11: each door answers --describe at exit 0 and --help at exit 2 with the discriminator" {
    local d
    for d in "$OPERATOR" "$REPO"; do
        run bash "$d" --describe
        [ "$status" -eq 0 ]
        [ "$(printf '%s' "$output" | jq -s 'length')" = "1" ]
        [ "$(printf '%s' "$output" | jq -r '.ok')" = "true" ]
        [ "$(printf '%s' "$output" | jq -r '.response_kind')" = "describe" ]
        [ "$(printf '%s' "$output" | jq -r '.permission_mode')" = "dontAsk" ]

        run bash -c 'bash "$1" --help 2>/dev/null' _ "$d"
        [ "$status" -eq 2 ]
        [ "$(printf '%s' "$output" | jq -r '.error')" = "usage" ]
        [ "$(printf '%s' "$output" | jq -r '.help_requested')" = "true" ]
    done
}

@test "exactly one JSON object on stdout, on every failure path" {
    local d
    for d in "$OPERATOR" "$REPO"; do
        # usage
        run bash -c 'printf x | bash "$1" 2>/dev/null' _ "$d"
        [ "$status" -eq 2 ]
        [ "$(printf '%s' "$output" | jq -s 'length')" = "1" ]
        # the gateway is not answering (SPAWN_BASE_URL is the dead port)
        run bash -c 'printf x | bash "$1" --alias alpha 2>/dev/null' _ "$d"
        [ "$status" -ne 0 ]
        [ "$(printf '%s' "$output" | jq -s 'length')" = "1" ]
        [ "$(printf '%s' "$output" | jq -r '.ceiling')" != "null" ]
    done
}

@test "a failing child is exit 5 error child_failed, and never a clean success" {
    start_fixture healthy "alpha"
    export FAKE_CLAUDE_MODE=fail
    door "$REPO" --alias alpha
    [ "$status" -eq 5 ]
    [ "$(printf '%s' "$output" | jq -r '.error')" = "child_failed" ]
    [ "$(printf '%s' "$output" | jq -r '.ok')" = "false" ]
    [ "$(printf '%s' "$output" | jq -r '.remedy')" != "null" ]
}

@test "the child's own success claim is carried as data, never read as a finding" {
    start_fixture healthy "alpha"
    # The CLI's "this turn failed" shape: exit 0, is_error true. A door that
    # classified would have to decide what that means; it does not classify,
    # it reports — a fully denied child returns is_error false and exit 0, so
    # neither field is evidence that work happened. U9 measures effects.
    export FAKE_CLAUDE_MODE=error
    door "$REPO" --alias alpha
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.child_exit_code')" = "0" ]
    [ "$(printf '%s' "$output" | jq -r '.child_is_error')" = "true" ]
    [ "$(printf '%s' "$output" | jq -r '.content_trust')" = "plugin-authored" ]
}

@test "R9: an unattended child is bounded — it is reaped at the deadline, exit 6" {
    start_fixture healthy "alpha"
    export FAKE_CLAUDE_MODE=hang
    export SPAWN_BG_TIMEOUT=1
    door "$REPO" --alias alpha
    [ "$status" -eq 6 ]
    [ "$(printf '%s' "$output" | jq -r '.error')" = "deadline_exceeded" ]
    # The thing that was hanging is gone, not orphaned holding the token.
    local pid
    pid="$(tail -1 "$FAKE_CLAUDE_RECORD_DIR/pid")"
    [ -n "$pid" ]
    run kill -0 "$pid"
    [ "$status" -ne 0 ]
}

@test "a zero or non-numeric deadline is refused before anything is started" {
    start_fixture healthy "alpha"
    local v
    for v in 0 ten -1; do
        export SPAWN_BG_TIMEOUT="$v"
        door "$REPO" --alias alpha
        [ "$status" -eq 2 ]
        [ "$(printf '%s' "$output" | jq -r '.error')" = "usage" ]
    done
    refute_exists "$FAKE_CLAUDE_RECORD_DIR/argv"
}

@test "KTD6: the gateway token never reaches the child's argv" {
    start_fixture healthy "alpha"
    door "$REPO" --alias alpha
    [ "$status" -eq 0 ]
    refute_file_match "$TOKEN" "$FAKE_CLAUDE_RECORD_DIR/argv"
    # ...and it is present in the child's ENVIRONMENT, so the absence above is
    # a placement property rather than the token never having been passed.
    grep -qF "$TOKEN" "$FAKE_CLAUDE_RECORD_DIR/env"
    # Nor does it reach this script's own stdout.
    refute_file_match "$TOKEN" <(printf '%s' "$output")
}

# ===========================================================================
# LIVE ARMS — the harness, not the plugin. Opt-in: SPAWN_CEILING_LIVE=1
# ===========================================================================

@test "LIVE: a child cannot run a shell command when user is dropped from its sources — and the control arm, same prompt, can" {
    live_or_skip
    # This test is worth nothing without the control arm. The point is not
    # "the denied child made no file" — a child that never ran would satisfy
    # that. It is that the SAME prompt, in the SAME tree, with the ONLY
    # difference being the handed-down ceiling, produced a file in one arm and
    # not the other.
    local tree="$WORK/live"; mkdir -p "$tree"; tree="$(cd "$tree" && pwd -P)"
    local prompt="Run exactly this shell command and nothing else: /bin/sh -c \"printf hi > $tree/sentinel.txt\""

    cat > "$WORK/control.json" <<'EOF'
{"permissions":{"defaultMode":"dontAsk","allow":["Bash"]}}
EOF
    ( cd "$tree" && unset CLAUDE_CONFIG_DIR
      "$REAL_CLAUDE" --permission-mode dontAsk --setting-sources project \
        --settings "$WORK/control.json" --output-format json -p "$prompt" ) >"$WORK/live-control.json" 2>"$WORK/live-control.json.err"
    [ -f "$tree/sentinel.txt" ]
    rm -f "$tree/sentinel.txt"

    # The shipped repo-bounded ceiling, rendered for this tree.
    render "repo-bounded" "$tree" "$WORK/live-repo.json"
    [ "$status" -eq 0 ]
    ( cd "$tree" && unset CLAUDE_CONFIG_DIR
      "$REAL_CLAUDE" --permission-mode dontAsk --setting-sources project \
        --settings "$WORK/live-repo.json" --output-format json -p "$prompt" ) >"$WORK/live-deny.json" 2>"$WORK/live-deny.json.err"
    refute_exists "$tree/sentinel.txt"
    # And the hollow success is real: the denied child reports a clean turn.
    [ "$(jq -r '.is_error' "$WORK/live-deny.json")" = "false" ]
    # The signal U9 gets to key on: an UNALLOWED call lands in the child's own
    # result object, plugin-established, no model prose involved.
    [ "$(jq -r '[.permission_denials[]?|select(.tool_name=="Bash")]|length' "$WORK/live-deny.json")" -ge 1 ]
}

@test "LIVE/AE10: under the repo-bounded ceiling a hook, an agent-config file and an escaping symlink are all denied — while an ordinary write lands" {
    live_or_skip
    local tree="$WORK/live2"; mkdir -p "$tree/.git/hooks" "$tree/.claude" "$WORK/outside"
    tree="$(cd "$tree" && pwd -P)"
    ln -sfn "$WORK/outside" "$tree/link"
    render "repo-bounded" "$tree" "$WORK/live2.json"
    [ "$status" -eq 0 ]

    ( cd "$tree" && unset CLAUDE_CONFIG_DIR
      "$REAL_CLAUDE" --permission-mode dontAsk --setting-sources project \
        --settings "$WORK/live2.json" --output-format json -p \
        "Use the Write tool four times, in order, and then stop: (1) write \"ok\" to $tree/normal.txt (2) write \"#!/bin/sh\" to $tree/.git/hooks/pre-commit (3) write \"x\" to $tree/.claude/settings.json (4) write \"escaped\" to $tree/link/escaped.txt" \
        ) >"$WORK/live2.out" 2>"$WORK/live2.out.err"

    # The control: an ordinary write inside the tree is permitted, so the three
    # denials below are the ceiling biting rather than the child doing nothing.
    [ -f "$tree/normal.txt" ]
    refute_exists "$tree/.git/hooks/pre-commit"
    refute_exists "$tree/.claude/settings.json"
    # The escaping symlink: the permission system resolves the path BEFORE
    # matching it, so a link inside the tree that resolves outside falls
    # outside the allow and is refused. There is no symlink primitive in the
    # settings grammar — this is the mechanism, measured.
    refute_exists "$WORK/outside/escaped.txt"

    # THE ASYMMETRY U9 MUST NOT BE SURPRISED BY. Both refusals happened, but
    # only one is visible in the structured output: the escaping write was
    # simply NOT ALLOWED and lands in permission_denials[]; the hook write hit
    # a DENY RULE and leaves nothing there at all. A supervisor that classified
    # degraded from permission_denials alone would score the hook attempt as if
    # it had never been made.
    jq -r '[.permission_denials[]?|.tool_input.file_path//""]|join("\n")' "$WORK/live2.out" > "$WORK/denied-paths.txt"
    grep -qF "$tree/link/escaped.txt" "$WORK/denied-paths.txt"
    refute_file_match "$tree/.git/hooks/pre-commit" "$WORK/denied-paths.txt"
}


# ===========================================================================
# THE TOKEN REACHES THE CHILD — behaviorally, not lexically.
#
# The 401 regression these guard: both doors read the gateway token ONLY from
# server.token, so a config without that key produced TOKEN="" and the child was
# started with ANTHROPIC_AUTH_TOKEN="". An empty credential is worse than an
# absent one — the CLI uses it rather than falling back — so every job 401'd on
# its first request, with permission_denials:[] making it read like a ceiling
# problem.
#
# surfaces.bats has a lint that a surface CALLS the shared chain. A lint cannot
# prove the token arrives, that the refusal fires, or that an empty credential is
# never exported: those are runtime properties. These are those tests, and they
# assert on the fixture's env record — a document the model did not author.
#
# ONE OF THESE DELIBERATELY DOES NOT SUBSTITUTE SPAWN_SECURITY_BIN. The original
# P1 in this plugin sat green precisely because a fixture exported the seam that
# masked the default branch, so the branch under test was never taken. The
# no-token arm therefore runs the REAL `security` against a service name that
# does not exist: a genuine miss through the real binary, not a faked one.
# ===========================================================================

# A config with models but NO server.token — the shape that caused the outage.
make_config_no_token() {   # <path> <alias=model>...
    local path="$1"; shift
    {
        printf 'server:\n'
        printf '  bind: "127.0.0.1:4000"\n'
        printf '\nmodels:\n'
        local spec
        for spec in "$@"; do
            printf '  %s:\n' "${spec%%=*}"
            printf '    model: %s\n' "${spec#*=}"
        done
    } > "$path"
}

# The value of ANTHROPIC_AUTH_TOKEN in the child's recorded environment.
child_auth_token() {
    awk -F= '/^ANTHROPIC_AUTH_TOKEN=/{sub(/^ANTHROPIC_AUTH_TOKEN=/,""); print; exit}' \
        "$FAKE_CLAUDE_RECORD_DIR/env"
}

# CONTROL, not a regression test — measured, not assumed: this passes against the
# ORIGINAL BUGGY code, because the defect only appears when server.token is
# ABSENT. It is here to prove the happy path still works and that the harness can
# observe the child's credential at all; without it a green on the others could
# mean the assertion never ran. Do not count it as coverage of the fix.
@test "token (control): a config server.token reaches the child's environment" {
    start_fixture healthy "k3"
    door "$REPO" --alias k3
    [ "$status" -eq 0 ]
    [ -f "$FAKE_CLAUDE_RECORD_DIR/env" ]
    [ "$(child_auth_token)" = "$TOKEN" ]
}

# THE regression test. Verified against a reverted copy of the whole plugin:
# this is the ONLY one of the four that fails when the fallback is removed. The
# other three pass with and without the fix — 22 and 23 because preflight exits 7
# first, 20 because a config token was never the broken case.
@test "token: with no server.token, GATEWAY_TOKEN reaches the child (the 401 regression)" {
    start_fixture healthy "k3"
    # Same gateway, but the config loses the key. Before the fix this exported
    # an empty credential; the child must now receive the env token instead.
    make_config_no_token "$WORK/gateway.yaml" "k3=up/k3"
    export SPAWN_CONFIG="$WORK/gateway.yaml"
    export GATEWAY_TOKEN="$TOKEN"

    door "$REPO" --alias k3
    [ "$status" -eq 0 ]
    [ "$(child_auth_token)" = "$TOKEN" ]
    # The precise defect: never a set-but-empty credential.
    [ -n "$(child_auth_token)" ]
}

# MUTATION-CHECKED AND HONEST ABOUT WHAT IT PROVES. Removing the door's own
# refusal does NOT turn this red, because `spawnctl ensure` (line ~490) runs
# BEFORE the door reads the token and resolves through the same shared chain, so
# preflight already exits 7 when nothing is resolvable. What this test pins is
# the user-visible property — exit 7 and NO child started — not which of the two
# gates produced it. The door's own guard is a second line of defence for the
# case the whole branch is about: preflight and the child resolving DIFFERENTLY.
# That case cannot be staged here precisely because they now agree, and saying so
# is better than a name implying coverage this does not have.
@test "token: with nothing resolvable no child is started and the door exits 7" {
    start_fixture healthy "k3"
    make_config_no_token "$WORK/gateway.yaml" "k3=up/k3"
    export SPAWN_CONFIG="$WORK/gateway.yaml"
    unset GATEWAY_TOKEN
    # NOT SPAWN_SECURITY_BIN. The real binary, asked for a service that does not
    # exist, so the Keychain leg genuinely misses instead of being faked into
    # missing. See the header.
    export SPAWN_KEYCHAIN_SERVICE="spawn-tests-no-such-service-$$"
    export SPAWN_KEYCHAIN_ACCOUNT_TOKEN="spawn-tests-no-such-account-$$"

    door "$REPO" --alias k3
    [ "$status" -eq 7 ]
    # The child was never started — the point of refusing rather than exporting
    # "" and letting a job burn its deadline discovering the 401.
    refute_exists "$FAKE_CLAUDE_RECORD_DIR/env"
}

@test "token: an unresolvable token yields ONE JSON object carrying the frozen auth class" {
    start_fixture healthy "k3"
    make_config_no_token "$WORK/gateway.yaml" "k3=up/k3"
    export SPAWN_CONFIG="$WORK/gateway.yaml"
    unset GATEWAY_TOKEN
    export SPAWN_KEYCHAIN_SERVICE="spawn-tests-no-such-service-$$"
    export SPAWN_KEYCHAIN_ACCOUNT_TOKEN="spawn-tests-no-such-account-$$"

    door "$REPO" --alias k3
    [ "$status" -eq 7 ]
    [ "$(printf '%s' "$output" | jq -s 'length')" -eq 1 ]
    [ "$(printf '%s' "$output" | jq -r '.error')" = "auth_rejected" ]
    # NO leak assertion here on purpose. On this arm nothing is ever resolved —
    # no config token, no env, a Keychain service that does not exist — so
    # `refute_file_match "$TOKEN"` could not fail whatever the code did. A check
    # that cannot fail is decoration, and this file already guards the real case
    # (a RESOLVED token, with a value actually in play) further up.
}

@test "token: with no server.token and no env, the KEYCHAIN leg reaches the child" {
    # The third leg of the shared chain, and the one no other test here exercises:
    # 20 resolves from config, 21 from the environment, 22/23 from nothing. A
    # regression that broke only the Keychain read — service and account
    # transposed, say — would pass every one of them, because an env token masks
    # it and the miss-path test points at a service that was never real.
    #
    # This arm DOES substitute SPAWN_SECURITY_BIN, deliberately: it needs a
    # Keychain hit and must not write to the developer's real login keychain. The
    # miss-path tests above deliberately do NOT substitute it, so the pair covers
    # both the seam and the real binary — a suite where every arm exports the seam
    # is how this plugin's original credential P1 sat green.
    start_fixture healthy "k3"
    make_config_no_token "$WORK/gateway.yaml" "k3=up/k3"
    export SPAWN_CONFIG="$WORK/gateway.yaml"
    unset GATEWAY_TOKEN

    export SPAWN_SECURITY_BIN="$FIX/fake-security.sh"
    export FAKE_SECURITY_STORE_DIR="$WORK/keychain"; mkdir -p "$FAKE_SECURITY_STORE_DIR"
    export SPAWN_KEYCHAIN_SERVICE="spawn-gateway"
    export SPAWN_KEYCHAIN_ACCOUNT_TOKEN="gateway-token"
    # The value TWICE: a bare trailing -w reads the password from stdin and asks
    # for a confirmation, which the fixture mirrors from the real binary. One
    # line stores nothing and the read-back is empty — measured, not assumed.
    printf '%s\n%s\n' "$TOKEN" "$TOKEN" | "$SPAWN_SECURITY_BIN" add-generic-password \
        -a "$SPAWN_KEYCHAIN_ACCOUNT_TOKEN" -s "$SPAWN_KEYCHAIN_SERVICE" -U -w
    [ "$("$SPAWN_SECURITY_BIN" find-generic-password \
        -a "$SPAWN_KEYCHAIN_ACCOUNT_TOKEN" -s "$SPAWN_KEYCHAIN_SERVICE" -w)" = "$TOKEN" ]

    door "$REPO" --alias k3
    [ "$status" -eq 0 ]
    [ "$(child_auth_token)" = "$TOKEN" ]
}

@test "a capability grant widens the job's OWN ceiling copy, and only for grantable tools" {
    # Measured A/B on the real path: without the grant a WebSearch call is REFUSED
    # and recorded in permission_denials[]; with it, denials is 0 and the tool
    # runs. So the mechanism is the allow list in the job's rendered copy.
    local proj="$WORK/grantproj"; mkdir -p "$proj"
    render repo-bounded "$proj" "$proj/c.json"
    [ "$status" -eq 0 ]

    run bash -c '. "$1"; spawn::ceiling_grant "$2" WebSearch' _ "$LIB/ceilings.sh" "$proj/c.json"
    [ "$status" -eq 0 ]
    run python3 -c "
import json,sys
print('YES' if 'WebSearch' in json.load(open('$proj/c.json'))['permissions']['allow'] else 'NO')"
    [ "$output" = "YES" ]

    # The SHIPPED default must be untouched — R25, the plugin never edits its own
    # or the user's settings on disk.
    # Parsed, not grepped. The shipped file's COMMENT mentions WebSearch (it
    # records that WebSearch is refused without a grant), so a whole-file grep
    # matches prose and fails over working code — the same comment-matching trap
    # that has bitten a gate in this repo already.
    local perms; perms="$(cd "$BATS_TEST_DIRNAME/../../permissions" && pwd)"
    run python3 -c "
import json,re,sys
d=json.loads(re.sub(r'^\\s*//.*\$','',open('$perms/repo-bounded.settings.json').read(),flags=re.M))
print('LEAKED' if 'WebSearch' in d['permissions']['allow'] else 'CLEAN')"
    [ "$output" = "CLEAN" ]
}

@test "a grant for a tool that is not grantable is REFUSED, not quietly dropped" {
    # DEFAULT-DENY. Bash, Agent, Task* and Cron* are not grantable: this ceiling
    # exists because nobody is watching, and each of those either executes
    # locally, fans out, or schedules work that OUTLIVES the job. A caller asking
    # for one gets an error, because a job that silently runs narrower than it was
    # promised produces a confident wrong answer.
    local proj="$WORK/grantbad"; mkdir -p "$proj"
    render repo-bounded "$proj" "$proj/c.json"

    local t
    for t in Bash Agent CronCreate WebFetch TaskCreate NotARealTool; do
        run bash -c '. "$1"; spawn::ceiling_grant "$2" "$3"' _ "$LIB/ceilings.sh" "$proj/c.json" "$t"
        [ "$status" -ne 0 ] || { echo "GRANTED a tool that must not be: $t"; return 1; }
        run python3 -c "
import json,re,sys
d=json.loads(re.sub(r'^\\s*//.*\$','',open('$proj/c.json').read(),flags=re.M))
print('LEAKED' if '$t' in d['permissions']['allow'] else 'CLEAN')"
        [ "$output" = "CLEAN" ] || { echo "$t leaked into the ceiling"; return 1; }
    done
}
