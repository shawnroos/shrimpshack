#!/usr/bin/env bats
# The runner's own rules. Both exist because a green line over a broken rule is
# worse than no line: the version fields drift silently, and spawn's credential
# patterns do not match the one credential this plugin actually handles.

bats_require_minimum_version 1.5.0

setup() {
    RUNNER="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)/tests/run-tests.sh"
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/hl-wire.XXXXXX")"
    WORK="$(cd "$WORK" && pwd -P)"
    . "$RUNNER"
}

teardown() {
    [ -n "${WORK:-}" ] && rm -rf "$WORK"
    return 0
}

manifest() { printf '{"name":"work","version":"%s"}' "$1" > "$WORK/plugin.json"; }
marketplace() { printf '{"plugins":[{"name":"%s","version":"%s"}]}' "$1" "$2" > "$WORK/marketplace.json"; }

@test "matching versions pass" {
    manifest 0.1.0; marketplace work 0.1.0
    run version_sync_check "$WORK/plugin.json" "$WORK/marketplace.json"
    [ "$status" -eq 0 ]
}

@test "drifted versions fail and name both" {
    manifest 0.1.0; marketplace work 0.2.0
    run version_sync_check "$WORK/plugin.json" "$WORK/marketplace.json"
    [ "$status" -ne 0 ]
    [[ "$output" == *"0.1.0"* ]]
    [[ "$output" == *"0.2.0"* ]]
}

@test "an unregistered plugin fails" {
    manifest 0.1.0; marketplace something-else 0.1.0
    run version_sync_check "$WORK/plugin.json" "$WORK/marketplace.json"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not registered"* ]]
}

@test "a Linear key shape is caught" {
    printf 'KEY=lin_api_%s\n' "AbCdEfGhIjKlMnOpQrStUv" > "$WORK/leak.txt"
    run scan_paths "$WORK"
    [ "$status" -ne 0 ]
}

@test "an Anthropic key shape is caught" {
    printf 'KEY=sk-ant-%s\n' "AbCdEfGhIjKlMnOpQrStUv" > "$WORK/leak.txt"
    run scan_paths "$WORK"
    [ "$status" -ne 0 ]
}

@test "a clean tree passes" {
    printf 'nothing to see here\n' > "$WORK/clean.txt"
    run scan_paths "$WORK"
    [ "$status" -eq 0 ]
}

# --- run_suite: a directory with zero .bats files must FAIL, not pass silently ---

@test "run_suite fails loudly on an empty directory" {
    run run_suite "$WORK"
    [ "$status" -ne 0 ]
    [[ "$output" == *"zero .bats files found under"* ]]
    [[ "$output" == *"$WORK"* ]]
}

@test "run_suite fails when the suite count drops below the floor" {
    cat > "$WORK/one.bats" <<'EOF'
@test "trivially true" { [ 1 -eq 1 ]; }
EOF
    HERDR_LINEAR_MIN_SUITES=2 run run_suite "$WORK"
    [ "$status" -ne 0 ]
    [[ "$output" == *"expected at least 2"* ]]
}

@test "run_suite passes when the suite count meets the floor and tests pass" {
    cat > "$WORK/one.bats" <<'EOF'
@test "trivially true" { [ 1 -eq 1 ]; }
EOF
    HERDR_LINEAR_MIN_SUITES=1 run run_suite "$WORK"
    [ "$status" -eq 0 ]
}

# --- skill_lib_sync_check: a skill's declared sourcing must cover the real
# dependency closure of the functions it calls, computed from the lib files
# themselves rather than trusted by inspection ---

# owned_docs is a fixed list inside the check, so a fixture root needs a
# (possibly empty) file for every path it names -- all eight skills and the
# command -- or the check reports them as missing, which would mask the thing
# under test.
sync_fixture() {
    local root="$1" describe_block="$2"
    mkdir -p "$root/lib"
    cat > "$root/lib/a.sh" <<'EOF'
herdr_linear::fn_a() { :; }
EOF
    cat > "$root/lib/b.sh" <<'EOF'
herdr_linear::fn_b() { herdr_linear::fn_a; }
EOF
    for s in new new-sub-issue new-project bind layout start doc; do
        mkdir -p "$root/skills/$s"
        printf -- '---\nname: %s\n---\nno bash here\n' "$s" > "$root/skills/$s/SKILL.md"
    done
    mkdir -p "$root/commands"
    printf -- 'no bash here\n' > "$root/commands/work.md"
    mkdir -p "$root/skills/describe"
    printf -- '---\nname: describe\n---\n%s\n' "$describe_block" > "$root/skills/describe/SKILL.md"
}

@test "sync check fails when a skill sources too few lib files" {
    sync_fixture "$WORK" '```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/b.sh"
herdr_linear::fn_b
```'
    run skill_lib_sync_check "$WORK"
    [ "$status" -ne 0 ]
    [[ "$output" == *"missing"*"'a'"* ]] || [[ "$output" == *"missing ['a']"* ]]
}

@test "sync check passes when sourcing covers the full dependency closure" {
    sync_fixture "$WORK" '```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/a.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/b.sh"
herdr_linear::fn_b
```'
    run skill_lib_sync_check "$WORK"
    [ "$status" -eq 0 ]
}

@test "sync check flags a call to a function defined nowhere" {
    sync_fixture "$WORK" '```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/a.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/b.sh"
herdr_linear::fn_never_defined
```'
    run skill_lib_sync_check "$WORK"
    [ "$status" -ne 0 ]
    [[ "$output" == *"undefined function"* ]]
    [[ "$output" == *"fn_never_defined"* ]]
}


# commands/work.md calls lib verbs and was scanned by nothing until U5. Without
# this case the extended list is an assertion; with it, it is proven.
@test "sync check covers the command, not only the skills" {
    sync_fixture "$WORK" 'no bash here'
    cat > "$WORK/commands/work.md" <<'CMD'
```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/b.sh"
herdr_linear::fn_b
```
CMD
    run skill_lib_sync_check "$WORK"
    [ "$status" -ne 0 ]
    [[ "$output" == *"commands/work.md"* ]]
    [[ "$output" == *"missing"*"'a'"* ]]
}


# --- the delegation briefs ---
#
# consent_caller_check greps lib/, hooks/ and commands/ only: a write skill
# legitimately calls consent_confirm in its own fence, so skills/ cannot be
# swept wholesale. That leaves one gap. U9 tells three skills to hand a step to
# a subagent, and a subagent has no prompt channel -- so a brief that says "ask
# which one" or calls a record verb loses a decision or answers the person's
# question for them, and ships green today. The brief is fenced as ```text so
# it can be read back and held to that.

brief_check() {
    python3 - "$1" <<'PYEOF'
import sys, os, re

root = sys.argv[1]
BANNED = ("consent_confirm", "consent_propose", "binding_confirm",
          "workspace_confirm", "binding_add_child", "AskUserQuestion",
          "blocking question tool")
rc = 0
for skill in ("bind", "layout", "describe"):
    p = os.path.join(root, "skills", skill, "SKILL.md")
    if not os.path.exists(p):
        print("%s: missing" % p); rc = 1; continue
    briefs = re.findall(r'```text\n(.*?)```', open(p).read(), re.S)
    if not briefs:
        print("%s: carries no subagent brief" % p); rc = 1; continue
    for b in briefs:
        for word in BANNED:
            if word in b:
                print("%s: the brief tells a subagent to ask or record (%s)"
                      % (p, word)); rc = 1
sys.exit(rc)
PYEOF
}

@test "no shipped brief tells a subagent to ask or record" {
    run brief_check "$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    [ "$status" -eq 0 ]
}

@test "a brief that records an answer is caught, and the file is named" {
    for s in bind layout describe; do
        mkdir -p "$WORK/skills/$s"
        printf -- '```text\nRead them and reply with the path.\n```\n' > "$WORK/skills/$s/SKILL.md"
    done
    printf -- '```text\nRead them, then run herdr_linear::consent_confirm.\n```\n' \
        > "$WORK/skills/describe/SKILL.md"
    run brief_check "$WORK"
    [ "$status" -ne 0 ]
    [[ "$output" == *"describe/SKILL.md"* ]]
    [[ "$output" == *"consent_confirm"* ]]
}

@test "a skill that lost its brief is caught" {
    for s in bind layout describe; do
        mkdir -p "$WORK/skills/$s"
        printf -- '```text\nRead them and reply with the path.\n```\n' > "$WORK/skills/$s/SKILL.md"
    done
    printf -- 'the delegation section was deleted\n' > "$WORK/skills/layout/SKILL.md"
    run brief_check "$WORK"
    [ "$status" -ne 0 ]
    [[ "$output" == *"layout/SKILL.md"* ]]
    [[ "$output" == *"carries no subagent brief"* ]]
}
