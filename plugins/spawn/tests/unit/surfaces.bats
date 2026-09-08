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
    [ "$output" -ge 6 ]

    run bash -c "$(declare -f skill_names); SKILL_DIR='$SKILL_DIR'; skill_names | grep -c ."
    [ "$status" -eq 0 ]
    [ "$output" -ge 5 ]

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

@test "R1 — every declared verb is the command surface, and no shadowing name came back" {
    # The list, NOT the glob, is the assertion here: R1 says these particular
    # names are the command surface, so a glob would restate whatever is on
    # disk and assert nothing. The list therefore has to be maintained — and it
    # was not. This read "the FOUR declared verbs" over four names while six
    # commands shipped: `setup.md` was the fifth and `team.md` the sixth, so the
    # test NAME asserted an invariant its BODY had stopped covering.
    #
    # The count check below is what makes the staleness visible next time
    # instead of silent: a seventh command must fail here and be named, rather
    # than joining the directory unmentioned.
    local v
    for v in agent bg-agent session report setup team; do
        [ -f "$CMD_DIR/$v.md" ]
    done
    [ "$(command_names | grep -c .)" -eq 6 ]

    # And the shadowing names are gone, not merely joined.
    for v in lens launch status; do
        [ ! -e "$CMD_DIR/$v.md" ]
    done
}

@test "R2 — every implementation skill keeps its own name" {
    # GLOBBED. This iterated `lens launch status` under the name "the three
    # skills" while five skill directories shipped — `spawn` and `team-run`
    # were outside it. The invariant is that no skill directory collides with a
    # command name (R1 checks the other direction) and that each one really
    # carries a SKILL.md, which is true of every skill, not of three of them.
    local d checked=0
    for d in "$SKILL_DIR"/*/; do
        [ -d "$d" ] || continue
        [ -f "$d/SKILL.md" ]
        checked=$((checked + 1))
    done
    # Guard the guard: an empty glob must fail loudly, not pass over nothing.
    [ "$checked" -ge 5 ]
    # The three original names are still asserted by hand: they are the ones the
    # collision fault was about, and losing one must fail here by name.
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
        "team:lib/team.sh"
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

# --- U16: the team surface ------------------------------------------------
#
# STATIC ONLY, AND SAID PLAINLY. Nothing here runs a model, so none of it can
# show that a live session follows the loop, picks a sane cap, actually issues
# the wakeup, or reports honestly. Those are uncheckable in this repo and are
# named as such in the plan rather than covered by a test that looks like it
# covers them. What IS checkable is that the two surfaces exist, name the right
# script, carry the namespaced wake prompt, and handle four intents rather than
# the three an earlier draft shipped.

# Every line in <file> where ScheduleWakeup is called with a quoted prompt.
# The prose mentions of the tool name — "the wakeup is this skill's call" —
# carry no prompt and are not what this is about.
wake_prompt_lines() {   # <file>
    grep -n 'ScheduleWakeup(.*"' "$1"
}

@test "U16 — every armed wake prompt is the namespaced /spawn:team form" {
    # A bare command name fired from ScheduleWakeup resolves to nothing. The
    # command and the skill both quote the prompt, so both are scanned.
    local f found=0 line
    for f in "$CMD_DIR/team.md" "$SKILL_DIR/team-run/SKILL.md"; do
        [ -f "$f" ]
        while IFS= read -r line; do
            found=$((found + 1))
            case "$line" in
                */spawn:team*) ;;
                *)
                    printf '%s: wake prompt is not namespaced: %s\n' "$f" "$line" >&2
                    return 1
                    ;;
            esac
        done < <(wake_prompt_lines "$f")
    done
    # Vacuity guard: a rotted matcher that finds no arming instruction at all
    # would otherwise pass this test for exactly the wrong reason.
    [ "$found" -ge 2 ]

    # NOT VACUOUS, part two: the matcher must still fire on the bare-name shape
    # it exists to reject. Same synthetic-control pattern the setup.md gate uses.
    local control="$BATS_TEST_TMPDIR/bare-wake.md"
    cat > "$control" <<'CTL'
ScheduleWakeup(intent.delay, "team <run-id>")
CTL
    run bash -c "$(declare -f wake_prompt_lines); wake_prompt_lines '$control'"
    [ "$status" -eq 0 ]
    printf '%s' "$output" | grep -qF 'ScheduleWakeup'
    refute_file_match '/spawn:team' "$control"
}

@test "U16 — both team surfaces name the namespaced command" {
    grep -qF '/spawn:team' "$CMD_DIR/team.md"
    grep -qF '/spawn:team' "$SKILL_DIR/team-run/SKILL.md"
}

@test "U16 — the team-run body names all four intents" {
    # PRESENCE ONLY, and it cannot prove correct handling of any of them. It
    # goes red on the omission this plan itself shipped in an earlier draft: a
    # body that handled three intents of four.
    #
    # THE ROW, NOT THE WORD. The first version of this asserted each intent word
    # appeared anywhere in the body, and deleting the whole `waiting` row from
    # the dispatch table left it GREEN — every one of those four words also
    # appears in surrounding prose, so "the body mentions waiting" was true of a
    # body that had stopped dispatching on it. The table row is where an intent
    # is actually given an action, so that is what is pinned.
    local md="$SKILL_DIR/team-run/SKILL.md"
    [ -f "$md" ]
    local body w
    body="$(awk 'NR==1 && $0=="---" { inb=1; next } inb && $0=="---" { inb=0; next } !inb' "$md")"
    [ -n "$body" ]
    for w in continue waiting stop noop; do
        if ! printf '%s\n' "$body" | grep -q "^| \`$w\` |"; then
            printf 'team-run/SKILL.md has no dispatch-table row for the `%s` intent\n' "$w" >&2
            return 1
        fi
    done
}

# --- the skills stay reachable without re-colliding -----------------------

@test "each SKILL.md description carries the do-not-self-trigger clause" {
    # GLOBBED, not a hardcoded list. This used to iterate `lens launch status`
    # while claiming "each SKILL.md", so a skill added later was invisible to it
    # — the check was narrower than the invariant its own name states, and a new
    # skill could self-trigger with nothing going red.
    #
    # ONE deliberate exception, named here rather than silently skipped: the
    # `spawn` router IS the conversational front door. Its whole job is to be
    # reachable from "get me a second opinion" and then delegate. If it carried
    # the clause, nothing in the plugin could be entered conversationally and the
    # four surfaces would only be reachable by someone who already knew which one
    # they wanted — which is the problem the router exists to solve.
    local d name
    local checked=0
    for d in "$SKILL_DIR"/*/; do
        name="$(basename "$d")"
        [ -f "$d/SKILL.md" ] || continue
        if [ "$name" = "spawn" ]; then
            # The exception is asserted, not assumed: the router must NOT carry
            # the clause. If someone adds it, this fails and they have to think.
            run bash -c "$(declare -f frontmatter); frontmatter '$d/SKILL.md'"
            [ "$status" -eq 0 ]
            printf '%s' "$output" | grep -qF 'conversationally triggerable'
            if printf '%s' "$output" | grep -qF 'do NOT'; then
                echo "the spawn router must NOT carry the do-not-self-trigger clause —"
                echo "it is the conversational front door. Remove the clause, or if the"
                echo "router is genuinely no longer the entry point, update this test."
                return 1
            fi
            continue
        fi
        run bash -c "$(declare -f frontmatter); frontmatter '$d/SKILL.md'"
        [ "$status" -eq 0 ]
        printf '%s' "$output" | grep -qF 'do NOT'
        printf '%s' "$output" | grep -qF 'conversational phrasing'
        checked=$((checked + 1))
    done
    # Guard the guard: if the glob ever matches nothing, this must fail loudly
    # rather than pass over an empty loop.
    [ "$checked" -ge 4 ]
}

@test "every implementation skill is hidden from the slash menu" {
    # The do-not-self-trigger clause above is PROSE — it asks the model not to
    # fire the skill on conversational phrasing. It does nothing about the `/`
    # menu, so lens, launch and status still offered themselves to a person
    # choosing a surface, alongside the four commands that are the real front
    # doors. `user-invocable: false` is the mechanism: the harness parses it
    # (default true) and registers the skill with isHidden set, which keeps it
    # out of the menu while leaving it reachable by name through the Skill tool.
    # Model reachability is gated by `disable-model-invocation`, a DIFFERENT
    # field which is NOT set here on purpose — it would block the Skill tool and
    # contradict the clause's own "invoked by name only (via the Skill tool)".
    #
    # GLOBBED for the same reason the clause test is: a hardcoded trio stops
    # protecting the moment a fourth implementation skill is added.
    #
    # ONE exception, asserted rather than skipped: the `spawn` router is the
    # conversational front door and must stay in the menu.
    local d name checked=0
    for d in "$SKILL_DIR"/*/; do
        name="$(basename "$d")"
        [ -f "$d/SKILL.md" ] || continue
        run bash -c "$(declare -f frontmatter); frontmatter '$d/SKILL.md'"
        [ "$status" -eq 0 ]
        if [ "$name" = "spawn" ]; then
            if printf '%s' "$output" | grep -qE '^user-invocable:'; then
                echo "the spawn router must stay user-invocable — it is the"
                echo "conversational front door and the one surface a person can"
                echo "reach without already knowing which of the four they want."
                return 1
            fi
            continue
        fi
        if ! printf '%s' "$output" | grep -qE '^user-invocable:[[:space:]]*false[[:space:]]*$'; then
            printf '%s: frontmatter has no `user-invocable: false`, so it still appears in the / menu\n' \
                "$d/SKILL.md" >&2
            return 1
        fi
        # The field must also be DECLARED FRONTMATTER, not prose that happens to
        # start a line in the body — frontmatter() already bounds that.
        checked=$((checked + 1))
    done
    # Guard the guard: an empty loop must fail loudly, not pass silently.
    [ "$checked" -ge 4 ]
}

@test "no skill body points at a command name this unit deleted" {
    # GLOBBED, for the third time in this file and for the same reason: it
    # iterated `lens launch status`, so `spawn/SKILL.md` and `team-run/SKILL.md`
    # were never scanned. The deleted names are repo-wide — a body anywhere that
    # tells a reader to run `/spawn:lens` sends them at a command that does not
    # exist, and which of the five files it lives in changes nothing about that.
    local d checked=0
    for d in "$SKILL_DIR"/*/; do
        [ -f "$d/SKILL.md" ] || continue
        refute_file_match '/spawn:status' "$d/SKILL.md"
        refute_file_match '/spawn:lens' "$d/SKILL.md"
        refute_file_match '/spawn:launch' "$d/SKILL.md"
        checked=$((checked + 1))
    done
    # Guard the guard: an empty glob must fail loudly, not pass over nothing.
    [ "$checked" -ge 5 ]
}

@test "a doc that tells a caller about Bash also tells them it is grantable" {
    # THE INVARIANT, not the wording. Bash became grantable on 2026-08-25, and
    # before that these docs told a caller flatly that a bg-agent child has no
    # Bash — wrong in the direction that costs work, because a reader believes
    # the capability is unreachable and routes around a surface that has it.
    #
    # Banning phrases does not express that. "no Bash" appears in the CORRECT
    # sentence "no Bash unless you grant it", and "cannot run shell commands"
    # appears in the correct "by default a job cannot run shell commands" — a
    # substring pin fails on both while the defect it names is absent. So the
    # rule is co-occurrence: a doc may say whatever it likes about Bash as long
    # as it also names the flag that grants it.
    #
    # An EXPLICIT file list, not a walk of the doc tree. README.md documents
    # neither --allow nor the older WebSearch grant, so a tree-wide pin would
    # drag a staleness this change did not create into scope.
    # The `continue` below is what makes this test able to assert nothing at all:
    # if a future rewrite stopped naming Bash in both files, every iteration would
    # skip and the test would pass having checked nothing. Count the files that
    # actually fired and fail when none did — the same can't-fail hole this change
    # already closed three times elsewhere.
    local f matched=0
    for f in "$CMD_DIR/bg-agent.md" "$SKILL_DIR/spawn/SKILL.md"; do
        grep -qF 'Bash' "$f" || continue
        matched=$((matched + 1))
        grep -qF -- '--allow Bash' "$f" \
            || { echo "$f discusses Bash without naming --allow Bash"; return 1; }
    done
    [ "$matched" -gt 0 ] \
        || { echo "no shipped doc mentions Bash at all — this test asserted nothing"; return 1; }
}

@test "no doc still carries the retracted permission model" {
    # These two claims were measured false and are load-bearing next to a Bash
    # grant: a reader who believes the allow list is inert concludes that adding
    # a tool to it is pointless, and that omission is permissive. Unlike the
    # co-occurrence rule above, these are exact retracted sentences that have no
    # correct form — banning them cannot catch honest prose.
    local f
    for f in "$CMD_DIR/bg-agent.md" "$SKILL_DIR/spawn/SKILL.md"; do
        refute_file_match 'the allow list constrains nothing on its own' "$f"
        refute_file_match 'deny list is the whole enforcement' "$f"
    done
}

@test "the grantable tools a doc names match the ones the code grants" {
    # A doc that drifts from spawn::ceiling_grantable is how a caller learns the
    # wrong ceiling — either asking for a tool that will refuse and kill the job,
    # or not asking for one that would have worked. Read the arm out of the code
    # and require each name to appear in the command doc.
    # Read the grantable names OUT OF THE CASE ARM, never from a list written
    # here. Probing a hardcoded set of candidates would never ask about the next
    # tool someone makes grantable — the drift this test exists to catch is
    # exactly a new name the docs do not mention.
    local lib; lib="$(cd "$BATS_TEST_DIRNAME/../../lib" && pwd)"
    local names
    names="$(sed -n '/^spawn::ceiling_grantable()/,/^}/p' "$lib/ceilings.sh" \
        | sed -n 's/^[[:space:]]*\([A-Za-z|]*\))[[:space:]]*return 0[[:space:]]*;;.*/\1/p' \
        | tr '|' '\n' | grep -v '^$')"
    [ -n "$names" ] \
        || { echo "could not read any grantable name out of spawn::ceiling_grantable"; return 1; }

    local t
    for t in $names; do
        grep -q -- "$t" "$CMD_DIR/bg-agent.md" \
            || { echo "code grants '$t' but commands/bg-agent.md never names it"; return 1; }
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

# --- R26: setup ships as ONE surface, so its command defers to nothing -----
#
# KD9: setup ships as a command with no same-named skill, which means
# commands/setup.md has to carry its own contract — there is no second surface
# to hand off to. R3 above forbids the two Skill-tool phrasings across every
# command; this is wider, because a command can send the caller elsewhere by
# naming a skill path or a slash command without ever using the word "invoke".

@test "commands/setup.md instructs the caller to invoke no other surface (R26)" {
    local md="$CMD_DIR/setup.md"
    [ -f "$md" ]

    local pat
    for pat in 'Use the Skill tool' 'Skill tool to invoke' 'skills/' 'SKILL\.md' '/spawn:'; do
        if grep -qE -- "$pat" "$md"; then
            printf 'commands/setup.md reaches another surface: matched %s\n' "$pat" >&2
            return 1
        fi
    done

    # NOT VACUOUS. The original anchored this on a sibling command that
    # legitimately deferred to its skill; R3 has since removed that shape from
    # every command, so that anchor is now structurally impossible rather than
    # merely missing. A synthetic control replaces it — the same pattern set,
    # run over text that DOES reach another surface, must fire on every
    # pattern. A regex that had rotted into matching nothing anywhere would
    # otherwise pass this test for exactly the wrong reason.
    local control="$BATS_TEST_TMPDIR/reaches-out.md"
    cat > "$control" <<'CTL'
Use the Skill tool to invoke it.
See skills/lens/SKILL.md, or just run /spawn:status instead.
CTL
    for pat in 'Use the Skill tool' 'Skill tool to invoke' 'skills/' 'SKILL\.md' '/spawn:'; do
        grep -qE -- "$pat" "$control"
    done
}

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
    grep -q -- '--consent-shell-rc' "$CMD_DIR/setup.md"
    grep -q -- 'consent_required' "$CMD_DIR/setup.md"
}

@test "the EX_* enum is IDENTICAL in setup.sh and setup-lib.sh" {
    # setup.sh restates setup-lib.sh's contract constants because this suite
    # derives the exit-code table in commands/setup.md from THIS file's
    # `EX_*=<n>` lines. Its own comment says "a change here without the matching
    # change in setup-lib.sh is a defect" — and nothing asserted it, so the
    # defect it names could ship. A comment naming a failure class is not a
    # guard against it.
    #
    # The right fix is arguably to stop restating them, but that means changing
    # where this suite reads the table from, which is a bigger change than the
    # risk warrants. Pinning the invariant costs four lines and closes it now.
    local lib="$(cd "$BATS_TEST_DIRNAME/../../lib" && pwd)"
    local a b
    a="$(grep -oE '^EX_[A-Z]+=[0-9]+' "$lib/setup.sh" | sort)"
    b="$(grep -oE '^EX_[A-Z]+=[0-9]+' "$lib/setup-lib.sh" | sort)"

    # Guard the guard: both actually matched something, or "they are equal" is a
    # statement about two empty strings.
    [ -n "$a" ]
    [ -n "$b" ]
    [ "$(printf '%s\n' "$a" | wc -l | tr -d ' ')" -ge 5 ]

    if [ "$a" != "$b" ]; then
        echo "setup.sh and setup-lib.sh disagree on the frozen exit-code enum:"
        diff <(printf '%s\n' "$a") <(printf '%s\n' "$b") || true
        return 1
    fi
}

@test "the size justification's line counts match the file it is arguing about" {
    # A justification is only as good as its measurement, and this one's numbers
    # have gone stale THREE times in a single review round — each time because
    # the file changed after the argument was written. Twice I refreshed them by
    # hand and wrote a note telling the next reader to recount; the third time
    # proved that a note is not a mechanism.
    #
    # So the doc's own figures are now checked against the file on every run. If
    # this fails, RECOUNT AND UPDATE THE DOC — do not delete the assertion. The
    # whole point of the recorded decision is that a reader can verify the
    # numbers it rests on, and a stale figure reads as rationalisation whether
    # or not the argument behind it still holds.
    local doc="$(cd "$BATS_TEST_DIRNAME/../../../.." && pwd)/docs/residual-review-findings/spawn-quality-audit.md"
    local f="$(cd "$BATS_TEST_DIRNAME/../../lib" && pwd)/spawnctl.sh"
    [ -f "$doc" ]
    [ -f "$f" ]

    local claimed_total claimed_code
    claimed_total="$(grep -oE '[0-9]+ lines total' "$doc" | head -1 | grep -oE '[0-9]+')"
    claimed_code="$(grep -oE 'but [0-9]+ lines of code' "$doc" | head -1 | grep -oE '[0-9]+')"

    # Guard the guard: if the wording changes so the numbers stop being found,
    # this must fail loudly rather than compare two empty strings and pass.
    [ -n "$claimed_total" ]
    [ -n "$claimed_code" ]

    local actual_total actual_comment actual_blank actual_code
    actual_total="$(wc -l < "$f" | tr -d ' ')"
    actual_comment="$(grep -cE '^[[:space:]]*#' "$f")"
    actual_blank="$(grep -cE '^[[:space:]]*$' "$f")"
    actual_code=$((actual_total - actual_comment - actual_blank))

    if [ "$claimed_total" != "$actual_total" ] || [ "$claimed_code" != "$actual_code" ]; then
        echo "spawn-quality-audit.md is stale about spawnctl.sh:"
        echo "  doc says:  $claimed_total total, $claimed_code code"
        echo "  file is:   $actual_total total, $actual_code code"
        echo "Recount and update the doc; do not delete this check."
        return 1
    fi

    # The argument itself is that the file is under the bar ON CODE LINES. If
    # that ever stops being true the decision has to be re-taken, not re-quoted.
    [ "$actual_code" -lt 1000 ]
}

# ---------------------------------------------------------------------------
# THE SHARED TOKEN CHAIN, ENFORCED RATHER THAN ASSERTED IN A COMMENT.
#
# secrets.sh's header already states the rule — "One chain, one place, is the
# enforcement" — and explains that R27 shipped this bug once: a surface reading
# server.token alone kept working until setup retired that key, after which the
# probe authenticated and the surface 401'd. Nothing mechanically held the rule,
# so bg-agent.sh was written afterwards WITHOUT the fallback and shipped the
# identical defect: on any box whose gateway.yaml omits server.token, every job
# exported an empty credential and died on its first request, with
# permission_denials:[] making it read like a ceiling problem.
#
# The invariant is not "bg-agent.sh sources secrets.sh" — that is today's shape,
# and a check that narrow goes green the moment a FIFTH surface is added. The
# invariant is: any lib that hands ANTHROPIC_AUTH_TOKEN to a child must resolve
# it through the shared chain. So this globs, and each new surface is caught by
# existing without opting in rather than by anyone remembering to list it.
# ---------------------------------------------------------------------------
# WHAT THIS GATE IS, AND WHAT IT IS NOT.
#
# It is a LINT over known credential-passing spellings. It is NOT proof that the
# invariant holds, and it must not be described as closing the regression class.
# Three independent reviewers and this repo's own solution doc
# (docs/solutions/logic-errors/default-allow-regex-projection-gate-silently-drops-nudges.md)
# say the same thing: enumerating permitted forms is default-allow, and "the
# surface is everything nobody thought of". Widening the enumeration a fourth
# time does not change that.
#
# Known and accepted holes, all lexical by nature — do not paper over them by
# adding another alternation and calling it closed:
#   * dead code passes:      if false; then spawn::resolve_token; fi
#   * ordering is unchecked: a real call placed AFTER the export still passes
#   * indirection is blind:  v=ANTHROPIC_AUTH_TOKEN; env "$v=$tok" cmd
#   * a call inside a function that is never invoked still counts
#
# What would actually close it is a BEHAVIORAL test: run each surface against a
# fake claude, a fake config and a fake Keychain, and assert on the child's
# environment — token present from each source in turn, and NO child spawned
# when nothing resolves. That does not exist yet and is recorded as the top
# residual finding for this change. Until it does, this gate buys one thing:
# a new surface written in an ordinary spelling cannot silently skip the chain.
@test "every surface that exports a gateway credential resolves it through the shared chain" {
    local offenders=() f base
    for f in "$ROOT"/lib/*.sh; do
        base="$(basename "$f")"
        # secrets.sh IS the chain; it necessarily mentions the variable.
        [ "$base" = "secrets.sh" ] && continue
        # DISCOVERY must be wider than one spelling. `export VAR=`, `declare -x`,
        # and an `env VAR=` prefix all hand a credential to a child; matching only
        # the first would let a new surface evade the gate by writing it another
        # way, which is the same "narrower than the invariant" failure this gate
        # exists to close. (`env VAR=` is separately forbidden — KTD6, argv is
        # world-readable — but a gate should not depend on another rule holding.)
        # Strip comments ONCE, then do BOTH tests on the stripped text. Order is
        # load-bearing and was wrong: discovery ran on the raw file while the
        # helper check ran on stripped text, so a commented-OUT export selected a
        # file that exports nothing (false fail) and an INLINE comment naming the
        # helper satisfied the requirement (false pass). Both were reproduced.
        # `sed 's/#.*$//'` is NOT a shell lexer and cutting at the first `#`
        # anywhere destroys real code: `[ "$#" -gt 0 ] && export TOKEN=...`
        # becomes `[ "$`, so a genuine exporter vanishes and the gate passes
        # over it — the original false-pass class, reintroduced by the fix for
        # it. Drop whole-line comments, then cut only at WHITESPACE-hash, which
        # leaves `$#` and `${v##*/}` intact while still removing the trailing
        # `# spawn::resolve_token` that defeated the first version.
        local code; code="$(grep -v '^[[:space:]]*#' "$f" | sed 's/[[:space:]]#.*$//')"
        printf '%s' "$code" | grep -qE '(export|declare -x|declare -gx|typeset -x)[[:space:]]+ANTHROPIC_AUTH_TOKEN|(^|[[:space:];&|(]) *ANTHROPIC_AUTH_TOKEN=' || continue
        printf '%s' "$code" | grep -q 'spawn::resolve_token\|spawn::token_fallback' \
            || offenders+=("$base")
    done

    if [ "${#offenders[@]}" -ne 0 ]; then
        echo "These libs export ANTHROPIC_AUTH_TOKEN to a child but never consult"
        echo "the shared env/Keychain chain, so they authenticate with whatever the"
        echo "config alone yields — an empty string when server.token is absent:"
        printf '  %s\n' "${offenders[@]}"
        echo "Source secrets.sh and call spawn::resolve_token after the config read."
        return 1
    fi

    # The gate is only worth having if it can see a real surface. If the glob
    # ever matches nothing that exports the credential, it would pass vacuously.
    local exporters=0
    for f in "$ROOT"/lib/*.sh; do
        grep -v '^[[:space:]]*#' "$f" | sed 's/[[:space:]]#.*$//' \
            | grep -qE '(export|declare -x|declare -gx|typeset -x)[[:space:]]+ANTHROPIC_AUTH_TOKEN|(^|[[:space:];&|(]) *ANTHROPIC_AUTH_TOKEN=' \
            && exporters=$((exporters + 1))
    done
    [ "$exporters" -ge 2 ]
}

@test "every file that defines an EX_* code agrees with every other on its value" {
    # The enum is FROZEN and it is restated in several files rather than shared,
    # so the only thing keeping the copies honest is a check. This branch added a
    # third definition of EX_AUTH (ceilings.sh, because its `die` call was reading
    # an UNSET one and living on a `:-7` default) — three copies of a constant
    # with nothing asserting they agree is the same shape as the bug this branch
    # exists to fix, so it gets a guard rather than a comment.
    #
    # Pairwise on NAME, not per-file: a file is free to define only the codes it
    # produces. What is forbidden is two files giving the same name two values.
    local lib="$(cd "$BATS_TEST_DIRNAME/../../lib" && pwd)"
    local f name val seen conflicts=""
    local -a pairs=()

    for f in "$lib"/*.sh; do
        while IFS= read -r line; do
            name="${line%%=*}"; val="${line#*=}"
            pairs+=("$name $val $(basename "$f")")
        done < <(grep -oE '^EX_[A-Z]+=[0-9]+' "$f")
    done

    # The guard's own guard: if nothing matched, "no conflicts" is vacuous.
    [ "${#pairs[@]}" -ge 5 ]

    for name in $(printf '%s\n' "${pairs[@]}" | awk '{print $1}' | sort -u); do
        seen="$(printf '%s\n' "${pairs[@]}" | awk -v n="$name" '$1==n {print $2}' | sort -u)"
        if [ "$(printf '%s\n' "$seen" | wc -l | tr -d ' ')" -gt 1 ]; then
            conflicts="$conflicts$name: $(printf '%s\n' "${pairs[@]}" | awk -v n="$name" '$1==n {printf "%s=%s(%s) ", $1, $2, $3}')
"
        fi
    done

    if [ -n "$conflicts" ]; then
        echo "the frozen exit-code enum disagrees across files:"
        printf '%s' "$conflicts"
        return 1
    fi
}

@test "every error class a surface declares has a real, distinct remedy" {
    # A remedy is INSTRUCTION a caller acts on. `upstream_error` told people to
    # retry and then switch alias on a 502 that is really a size ceiling — advice
    # costing two calls that cannot work — and it drifted there because nothing
    # checked it. The class NAME appeared in tests; that proved nothing about the
    # prose. Prose correctness is not mechanically checkable; presence,
    # non-emptiness and distinctness are, and those are what broke.
    run python3 "$BATS_TEST_DIRNAME/../check-remedies.py" \
        "$(cd "$BATS_TEST_DIRNAME/../../lib" && pwd)"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}
