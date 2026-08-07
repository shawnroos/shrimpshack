#!/usr/bin/env bats
# U1 — the command surface.
#
# Static assertions over the plugin's markdown surfaces. No gateway fixture,
# no network, no TMPDIR redirection: nothing here runs a script.
#
# What it pins is the fault that shipped: commands and skills shared all three
# names, the command won every resolution, so the SKILL.md files never loaded —
# and each command body then said "use the Skill tool to invoke spawn:<name>",
# which resolved back to the command. A loop. The structural fix is name
# divergence plus self-sufficient bodies, and both are only true as long as
# something checks them, because the next surface added is the one that
# re-collides.
#
# The enumerations are dynamic on purpose. A hardcoded list of four commands
# stops protecting the moment a fifth is added, and reads green while doing it.

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    CMD_DIR="$ROOT/commands"
    SKILL_DIR="$ROOT/skills"
}

# --- helpers ---------------------------------------------------------------

# NEGATIVE ASSERTIONS. bats runs under `set -e`, but POSIX exempts a pipeline
# beginning with `!` from it — so `! grep -q PATTERN file` NEVER fails a test,
# it evaluates and moves on. That shape already let a token-leak assertion pass
# over genuinely leaking code in this repo. These helpers fail as PLAIN
# commands, which set -e does honour.
refute_file_match() {   # <literal> <file...>
    local pat="$1"; shift
    if grep -qF -- "$pat" "$@"; then
        printf 'refute_file_match: unexpected match for %s in %s\n' "$pat" "$*" >&2
        grep -nF -- "$pat" "$@" >&2
        return 1
    fi
    return 0
}

# Every command basename, without the .md.
command_names() {
    local f
    for f in "$CMD_DIR"/*.md; do
        [ -f "$f" ] || continue
        basename "$f" .md
    done
}

# Every skill directory name.
skill_names() {
    local d
    for d in "$SKILL_DIR"/*/; do
        [ -d "$d" ] || continue
        basename "$d"
    done
}

# The YAML frontmatter block only — everything between the first `---` line and
# the next one. Asserting a `description:` against the whole file would pass on
# the word appearing in prose.
frontmatter() {         # <file>
    awk 'NR==1 && $0=="---" { inb=1; next } inb && $0=="---" { exit } inb' "$1"
}

# --- R1: no command name collides with a skill name ------------------------

@test "R1 — no command filename matches any skill directory name" {
    # Guard the enumerations first. Both globs returning nothing would make the
    # collision check vacuously true, which is the false-green shape here.
    run bash -c "$(declare -f command_names); CMD_DIR='$CMD_DIR'; command_names | grep -c ."
    [ "$status" -eq 0 ]
    [ "$output" -ge 4 ]

    run bash -c "$(declare -f skill_names); SKILL_DIR='$SKILL_DIR'; skill_names | grep -c ."
    [ "$status" -eq 0 ]
    [ "$output" -ge 3 ]

    local c s
    for c in $(command_names); do
        for s in $(skill_names); do
            if [ "$c" = "$s" ]; then
                printf 'command %s.md collides with skill directory %s/ — the command shadows the skill and the SKILL.md never loads\n' \
                    "$c" "$s" >&2
                return 1
            fi
        done
    done
}

@test "R1 — the four declared verbs are the command surface" {
    local v
    for v in agent bg-agent session report; do
        [ -f "$CMD_DIR/$v.md" ]
    done
    # And the shadowing names are gone, not merely joined.
    for v in lens launch status; do
        [ ! -e "$CMD_DIR/$v.md" ]
    done
}

@test "R2 — the three skills keep their own names" {
    local s
    for s in lens launch status; do
        [ -f "$SKILL_DIR/$s/SKILL.md" ]
    done
}

# --- R3: no command redirects to a skill or another command ----------------

@test "R3 — no command body contains 'Use the Skill tool to invoke'" {
    local f found=0
    for f in "$CMD_DIR"/*.md; do
        [ -f "$f" ] || continue
        found=1
        refute_file_match 'Use the Skill tool to invoke' "$f"
    done
    [ "$found" -eq 1 ]
}

@test "R3 — no command body sends the caller to the Skill tool at all" {
    local f
    for f in "$CMD_DIR"/*.md; do
        [ -f "$f" ] || continue
        refute_file_match 'Skill tool to invoke' "$f"
        refute_file_match 'invoke the skill' "$f"
    done
}

# --- R20: each command carries its own instructions -----------------------

@test "R20 — every command's frontmatter carries a description" {
    local f
    for f in "$CMD_DIR"/*.md; do
        [ -f "$f" ] || continue
        run bash -c "$(declare -f frontmatter); frontmatter '$f' | grep -c '^description:'"
        if [ "$output" != "1" ]; then
            printf '%s: frontmatter has %s description: keys (want exactly 1)\n' "$f" "$output" >&2
            return 1
        fi
    done
}

@test "R20 — every command's frontmatter carries an argument-hint" {
    local f
    for f in "$CMD_DIR"/*.md; do
        [ -f "$f" ] || continue
        run bash -c "$(declare -f frontmatter); frontmatter '$f' | grep -c '^argument-hint:'"
        [ "$output" = "1" ]
    done
}

@test "R20 — every command body names the script it runs" {
    # The command layer is only self-sufficient if it names its own executable.
    # This is the assertion that a body cannot satisfy by pointing elsewhere.
    local -a pairs=(
        "agent:lib/lens.sh"
        "session:lib/launch.sh"
        "bg-agent:lib/bg-agent.sh"
        "report:lib/spawnctl.sh"
    )
    local pair name script
    for pair in "${pairs[@]}"; do
        name="${pair%%:*}"
        script="${pair#*:}"
        [ -f "$CMD_DIR/$name.md" ]
        if ! grep -qF -- "\${CLAUDE_PLUGIN_ROOT}/$script" "$CMD_DIR/$name.md"; then
            printf '%s.md does not name ${CLAUDE_PLUGIN_ROOT}/%s\n' "$name" "$script" >&2
            return 1
        fi
    done
}

@test "R20 — report names the status verb, not just the script" {
    grep -qF 'spawnctl.sh" status' "$CMD_DIR/report.md"
}

@test "R20 — bg-agent checks its engine exists before running it" {
    # Always true: the body checks for the script rather than assuming it.
    grep -qF '[ -f "${CLAUDE_PLUGIN_ROOT}/lib/bg-agent.sh" ]' "$CMD_DIR/bg-agent.md"

    # State-conditional. U9 owns the supervisor; until it lands, the body must
    # also SAY the engine is absent so a caller gets an honest answer instead of
    # a silent substitution. Once U9 ships the script that wording is stale, so
    # this half retires with the condition rather than going red in a suite U9
    # does not own.
    if [ ! -e "$ROOT/lib/bg-agent.sh" ]; then
        grep -qF 'does not exist yet' "$CMD_DIR/bg-agent.md"
    else
        refute_file_match 'does not exist yet' "$CMD_DIR/bg-agent.md"
    fi
}

@test "every command body ends by passing \$ARGUMENTS through" {
    local f
    for f in "$CMD_DIR"/*.md; do
        [ -f "$f" ] || continue
        grep -qF '$ARGUMENTS' "$f"
    done
}

# --- the skills stay reachable without re-colliding -----------------------

@test "each SKILL.md description carries the do-not-self-trigger clause" {
    local s
    for s in lens launch status; do
        run bash -c "$(declare -f frontmatter); frontmatter '$SKILL_DIR/$s/SKILL.md'"
        [ "$status" -eq 0 ]
        printf '%s' "$output" | grep -qF 'do NOT'
        printf '%s' "$output" | grep -qF 'conversational phrasing'
    done
}

@test "no skill body points at a command name this unit deleted" {
    local s
    for s in lens launch status; do
        refute_file_match '/spawn:status' "$SKILL_DIR/$s/SKILL.md"
        refute_file_match '/spawn:lens' "$SKILL_DIR/$s/SKILL.md"
        refute_file_match '/spawn:launch' "$SKILL_DIR/$s/SKILL.md"
    done
}

# --- the harness's own view of the plugin ---------------------------------

@test "claude plugin validate reports Validation passed" {
    # R11: the suite must pass from a clean checkout, so a box without the CLI
    # skips rather than fails.
    if ! command -v claude >/dev/null 2>&1; then
        skip "claude CLI is not on PATH"
    fi
    # The exit code LIES — validate returns 0 even when validation fails — so
    # the output is the only signal. Same reason run-tests.sh greps it.
    run bash -c "claude plugin validate '$ROOT' 2>&1"
    printf '%s' "$output" | grep -qF 'Validation passed'
}

# --- the setup command's own contract --------------------------------------
# Carried across the rebase from the gateway-setup branch. The R1/R3/R20 loops
# above already cover commands/setup.md generically; this is the one assertion
# they do not make, because it is specific to that command: its exit-code table
# is derived from lib/setup.sh's real EX_* constants rather than from prose, so
# a code added to the script without a row here fails.

@test "the exit-code table in commands/setup.md lists every code setup.sh can return" {
    [ -f "$CMD_DIR/setup.md" ]
    local script="$ROOT/lib/setup.sh"
    [ -f "$script" ]

    # Derived from the CODE, not from the plan's prose. Only real constant
    # definitions at the start of a line — a mention inside a comment or a die()
    # call is not a definition.
    local codes
    codes="$(grep -Eo '^EX_[A-Z_]+=[0-9]+' "$script" | sed 's/.*=//' | sort -un)"
    [ -n "$codes" ]
    # Guard against a grep that silently stopped matching.
    [ "$(printf '%s\n' "$codes" | wc -l | tr -d ' ')" -ge 5 ]

    # The table rows are ``| `N` |`` — the same shape the README's enum uses.
    local c missing=""
    for c in $codes; do
        grep -qE '^\| `'"$c"'` \|' "$CMD_DIR/setup.md" || missing="$missing $c"
    done
    if [ -n "$missing" ]; then
        printf 'commands/setup.md has no exit-code row for:%s\n' "$missing" >&2
        return 1
    fi

    # 8 and 9 are the two codes this unit introduced, and 8 is useless without
    # the flag to come back with — assert the mapping, not just the row.
    grep -q -- '--consent-overwrite-gw' "$CMD_DIR/setup.md"
    grep -q -- '--consent-shell-rc' "$CMD_DIR/setup.md"
    grep -q -- 'consent_required' "$CMD_DIR/setup.md"
}
