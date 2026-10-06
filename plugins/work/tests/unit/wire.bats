#!/usr/bin/env bats

load setup_common

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

# --- suite_setup_check: a suite without the shared setup reads the developer's
# own environment, and reports green while doing it ---

@test "suite isolation check names a suite that does not load the shared setup" {
    printf '%s\n' '@test "t" { true; }' > "$WORK/forgot.bats"
    printf 'load setup_common\n@test "t" { true; }\n' > "$WORK/remembered.bats"
    run suite_setup_check "$WORK"
    [ "$status" -ne 0 ]
    [[ "$output" == *"forgot.bats"* ]]
    [[ "$output" != *"remembered.bats"* ]]
}

@test "suite isolation check passes when every suite loads the shared setup" {
    printf 'load setup_common\n@test "t" { true; }\n' > "$WORK/a.bats"
    run suite_setup_check "$WORK"
    [ "$status" -eq 0 ]
    [[ "$output" == *"all 1 suite(s)"* ]]
}

@test "suite isolation check refuses a directory it found no suite in" {
    run suite_setup_check "$WORK"
    [ "$status" -ne 0 ]
    [[ "$output" == *"nothing was checked"* ]]
}

# --- skill_lib_sync_check: a skill's declared sourcing must cover the real
# dependency closure of the functions it calls, computed from the lib files
# themselves rather than trusted by inspection ---

# The skill under test is `start`; the other two kept skills and the command
# are present without bash, so the fixture has the shape of the real tree.
sync_fixture() {
    local root="$1" start_block="$2"
    mkdir -p "$root/lib"
    cat > "$root/lib/a.sh" <<'EOF'
herdr_linear::fn_a() { :; }
EOF
    cat > "$root/lib/b.sh" <<'EOF'
herdr_linear::fn_b() { herdr_linear::fn_a; }
EOF
    for s in layout linear-rules; do
        mkdir -p "$root/skills/$s"
        printf -- '---\nname: %s\n---\nno bash here\n' "$s" > "$root/skills/$s/SKILL.md"
    done
    mkdir -p "$root/commands"
    printf -- 'no bash here\n' > "$root/commands/work.md"
    mkdir -p "$root/skills/start"
    printf -- '---\nname: start\n---\n%s\n' "$start_block" > "$root/skills/start/SKILL.md"
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


# --- the delegation brief ---
#
# The layout skill hands the read of a parent's children to a subagent, and a
# subagent has no prompt channel -- so a brief that says "ask which one" or
# writes to the tracker loses a decision or answers the person's question for
# them, and ships green. The brief is fenced as ```text so it can be read back
# and held to that.

brief_check() {
    python3 - "$1" <<'PYEOF'
import sys, os, re

root = sys.argv[1]
BANNED = ("AskUserQuestion", "blocking question tool", "save_issue")
rc = 0
for skill in ("layout",):
    p = os.path.join(root, "skills", skill, "SKILL.md")
    if not os.path.exists(p):
        print("%s: missing" % p); rc = 1; continue
    briefs = re.findall(r'```text\n(.*?)```', open(p).read(), re.S)
    if not briefs:
        print("%s: carries no subagent brief" % p); rc = 1; continue
    for b in briefs:
        for word in BANNED:
            if word in b:
                print("%s: the brief tells a subagent to ask or write (%s)"
                      % (p, word)); rc = 1
sys.exit(rc)
PYEOF
}

@test "no shipped brief tells a subagent to ask or write" {
    run brief_check "$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    [ "$status" -eq 0 ]
}

@test "a brief that asks the person is caught, and the file is named" {
    mkdir -p "$WORK/skills/layout"
    printf -- '```text\nRead them, then ask with AskUserQuestion.\n```\n' \
        > "$WORK/skills/layout/SKILL.md"
    run brief_check "$WORK"
    [ "$status" -ne 0 ]
    [[ "$output" == *"layout/SKILL.md"* ]]
    [[ "$output" == *"AskUserQuestion"* ]]
}

@test "a skill that lost its brief is caught" {
    mkdir -p "$WORK/skills/layout"
    printf -- 'the delegation section was deleted\n' > "$WORK/skills/layout/SKILL.md"
    run brief_check "$WORK"
    [ "$status" -ne 0 ]
    [[ "$output" == *"layout/SKILL.md"* ]]
    [[ "$output" == *"carries no subagent brief"* ]]
}

# ------------------------------------------------ the start skill (U6)

start_skill() { cat "$(cd "$BATS_TEST_DIRNAME/../.." && pwd)/skills/start/SKILL.md"; }

# R6, R7. The skill is where the person is, so it is where the repository
# question is asked. Citing the readers by name is what makes it ask from the
# record rather than from wherever it happens to be standing.
@test "the start skill cites the repository readers by name" {
    body="$(start_skill)"
    [[ "$body" == *"herdr_linear::scope_repos"* ]]
    [[ "$body" == *"herdr_linear::no_repo_reason"* ]]
}

# KTD7. An exit the table does not name is an exit the skill reads as failure.
@test "the start skill binds through the board with an explicit cwd" {
    body="$(start_skill)"
    run grep -E '`bind`' <<<"$body"
    [ -n "$output" ]
    run grep -E '`cwd`' <<<"$body"
    [ -n "$output" ]
    [[ "$body" != *"/work:bind"* ]]
}

# R14. No caller supplies the name, so the skill must not tell anyone to.
@test "the start skill passes no worktree name and asks for none" {
    body="$(start_skill)"
    [[ "$body" != *"start_from_issue WEB-3308 panel-empty"* ]]
    [[ "$body" != *"Ask for the short name"* ]]
}

# Without it a wrong answer is recorded forever, and hand-deleting a file in
# the store is no longer the way: the verb exists, so the skill must name it.
@test "the start skill states how to undo a wrongly recorded repository" {
    body="$(start_skill)"
    [[ "$body" == *"forget_scope_repo"* ]]
}

layout_skill() { cat "$(cd "$BATS_TEST_DIRNAME/../.." && pwd)/skills/layout/SKILL.md"; }
layout_fences() { awk '/^```bash/ {f=1; next} /^```/ {f=0} f' <<<"$(layout_skill)"; }

@test "the layout skill names no retired skill" {
    body="$(layout_skill)"
    for s in bind declare describe doc new new-project new-sub-issue board; do
        run grep -qE "/work:${s}([^a-z-]|\$)" <<<"$body"
        [ "$status" -ne 0 ] || { echo "names /work:$s"; return 1; }
    done
}

@test "the layout skill's bash fences source only kept libraries" {
    fences="$(layout_fences)"
    [[ "$fences" == *"lib/herdr-read.sh"* ]]
    run bash -c "grep -oE 'lib/[A-Za-z0-9_-]+\.sh' <<<\"\$1\" \
        | grep -vxE 'lib/(contain|sanitize|schemes|secrets|herdr-read|repos)\.sh'" _ "$fences"
    [ -z "$output" ] || { echo "sources: $output"; return 1; }
}

# Nothing else checks a skill's fences: the lib-sourcing check sweeps bin/ and
# hooks/ only, so a fence calling a deleted function would ship green.
@test "every function the layout skill's fences call is defined in a library they source" {
    LIB="$(cd "$BATS_TEST_DIRNAME/../../lib" && pwd)"
    fences="$(layout_fences)"
    called="$(grep -oE 'herdr_linear::[A-Za-z0-9_]+' <<<"$fences" | sort -u)"
    [ -n "$called" ]
    sourced="$(grep -oE 'lib/[A-Za-z0-9_-]+\.sh' <<<"$fences" | sort -u | sed "s#^lib/#$LIB/#")"
    [ -n "$sourced" ]
    for fn in $called; do
        run grep -lE "^${fn}\(\)" $sourced
        [ -n "$output" ] || { echo "undefined in sourced libs: $fn"; return 1; }
    done
}

@test "the layout skill binds through the board with an explicit cwd" {
    body="$(layout_skill)"
    run grep -E '`bind`' <<<"$body"
    [ -n "$output" ]
    run grep -E '`cwd`' <<<"$body"
    [ -n "$output" ]
    [[ "$body" != *"layout_build"* ]]
    [[ "$body" != *"binding_add_child"* ]]
}

# The plugin may make a tab and split columns for new work; it never moves,
# closes or relabels what is already there.
@test "the layout skill's fences run no herdr verb but tab create and pane split" {
    fences="$(layout_fences)"
    [[ "$fences" == *"herdr tab create"* ]]
    [[ "$fences" == *"herdr pane split"* ]]
    run bash -c "grep -oE '(^|[;|&)]|\\\$\\() *herdr [a-z-]+ [a-z-]+' <<<\"\$1\" \
        | sed -E 's/^.*herdr /herdr /' \
        | grep -vxE 'herdr (tab create|pane split)'" _ "$fences"
    [ -z "$output" ] || { echo "runs: $output"; return 1; }
}

skill_fences() { awk '/^```bash/ {f=1; next} /^```/ {f=0} f' "$(cd "$BATS_TEST_DIRNAME/../.." && pwd)/skills/$1/SKILL.md"; }

# A title is text someone else wrote. Typed between quotes, a title holding
# the quote character ends the string and the rest of it runs as bash.
@test "no skill's bash fences assign a title or project name inside quotes" {
    for skill in start layout; do
        run grep -nE "(^|[^A-Za-z0-9_])([A-Z_]*TITLE|PROJECT_NAME)=['\"]" <<<"$(skill_fences "$skill")"
        [ -z "$output" ] || { echo "$skill: $output"; return 1; }
    done
}

# A quoted heredoc expands nothing. Only a line equal to the terminator ends
# it, and the skill refuses a title holding a line break or that text.
@test "both skills read titles through a quoted heredoc with a dotted terminator" {
    check() {
        local fences="$1" var="$2" term
        term="$(grep -oE "^IFS= read -r $var <<'[A-Za-z0-9_]+\.[A-Za-z0-9_]+'\$" <<<"$fences" \
            | sed -E "s/.*<<'([^']+)'\$/\1/")"
        [ -n "$term" ] || { echo "no quoted heredoc read for $var"; return 1; }
        grep -qxF "$term" <<<"$fences" || { echo "terminator $term for $var never closes"; return 1; }
    }
    start="$(skill_fences start)"
    layout="$(skill_fences layout)"
    check "$start" TITLE
    check "$start" PROJECT_NAME
    check "$layout" PARENT_TITLE
    check "$layout" CHILD_TITLE
}

rules_skill_path() { echo "$(cd "$BATS_TEST_DIRNAME/../.." && pwd)/skills/linear-rules/SKILL.md"; }
rules_frontmatter() { awk 'NR==1 && /^---$/ {f=1; next} f && /^---$/ {exit} f' "$(rules_skill_path)"; }

@test "the rules skill exists" {
    [ -f "$(rules_skill_path)" ]
}

# The guards it carries are only guards if the model loads the skill on its own.
@test "the rules skill is model-invocable" {
    run rules_frontmatter
    [ "$status" -eq 0 ]
    [[ "$output" == *"description:"* ]]
    [[ "$output" != *"disable-model-invocation"* ]]
}

# The /work command shadows a skill named work.
@test "the rules skill is not named work" {
    run rules_frontmatter
    [[ "$output" == *"name: "* ]]
    run bash -c "awk -F': *' '/^name:/ {print \$2}' <<<\"\$1\"" _ "$output"
    [ -n "$output" ]
    [ "$output" != "work" ]
}

@test "the rules skill links the conventions doc and the board tool reference" {
    body="$(cat "$(rules_skill_path)")"
    [[ "$body" == *"docs/linear-conventions.md"* ]]
    [[ "$body" == *"board skill"* ]]
}

work_command() { cat "$(cd "$BATS_TEST_DIRNAME/../.." && pwd)/commands/work.md"; }

@test "the command names no retired skill" {
    body="$(work_command)"
    for s in bind declare describe doc new new-project new-sub-issue board; do
        run grep -qE "/work:${s}([^a-z-]|\$)" <<<"$body"
        [ "$status" -ne 0 ] || { echo "names /work:$s"; return 1; }
    done
}

@test "the command's bash fences source only kept libraries" {
    run bash -c "awk '/^\`\`\`bash/ {f=1; next} /^\`\`\`/ {f=0} f' <<<\"\$1\" \
        | grep -oE 'lib/[A-Za-z0-9_-]+\.sh' \
        | grep -vxE 'lib/(contain|sanitize|schemes|secrets|herdr-read|repos)\.sh'" _ "$(work_command)"
    [ -z "$output" ] || { echo "sources: $output"; return 1; }
}

@test "the command runs the board health checks" {
    body="$(work_command)"
    [[ "$body" == *"board version --json"* ]]
    [[ "$body" == *"board linear report --help"* ]]
    [[ "$body" == *"claude mcp list"* ]]
    [[ "$body" == *"claude mcp add --scope user board -- board mcp"* ]]
    [[ "$body" == *"board daemon stop"* ]]
}

# Setup reads its skill file and loads the deferred board tools itself.
@test "the command allows Read and ToolSearch" {
    run awk -F': *' '/^allowed-tools:/ {print $2}' <<<"$(work_command)"
    [[ ", $output," == *", Read,"* ]]
    [[ ", $output," == *", ToolSearch,"* ]]
}

@test "the command keeps the start hand-off and the credential line" {
    body="$(work_command)"
    [[ "$body" == *"/work:start"* ]]
    [[ "$body" == *"bin/migrate-credential.sh"* ]]
}

# --- hook_source_stderr_check: a hook that sources lib must discard stderr ---

hook_tree() {
    mkdir -p "$WORK/h/hooks"
    printf '#!/bin/bash\nfor f in a.sh; do\n    [ -r "$LIB/$f" ] && . "$LIB/$f" 2>/dev/null\ndone\n' > "$WORK/h/hooks/ground.sh"
    printf '#!/bin/bash\ncommand -v board >/dev/null 2>&1 || exit 0\nboard linear report >/dev/null 2>&1\n' > "$WORK/h/hooks/board-behind.sh"
}

@test "the real hooks pass the source-stderr check" {
    run hook_source_stderr_check
    [ "$status" -eq 0 ]
}

@test "a hook that sources nothing passes beside one that discards stderr" {
    hook_tree
    run hook_source_stderr_check "$WORK/h"
    [ "$status" -eq 0 ]
}

@test "a hook that sources lib without discarding stderr turns the check red" {
    hook_tree
    printf '. "$LIB/contain.sh"\n' >> "$WORK/h/hooks/board-behind.sh"
    run hook_source_stderr_check "$WORK/h"
    [ "$status" -ne 0 ]
    [[ "$output" == *"board-behind.sh"* ]]
}

@test "the source-stderr check refuses a tree where no hook sources anything" {
    hook_tree
    printf '#!/bin/bash\nexit 0\n' > "$WORK/h/hooks/ground.sh"
    run hook_source_stderr_check "$WORK/h"
    [ "$status" -ne 0 ]
    [[ "$output" == *"no source line recognised"* ]]
}

# --- nothing shipped writes the old store or calls Linear with the plugin key ---
#
# Code is lib/, bin/, hooks/ and the bash fences of skills and the command; prose
# may name the old store to say it is no longer written. The one code reference
# to the old store allowed is the read-only fallback that prints its path in
# lib/repos.sh; repos.bats proves that read leaves the store unchanged. The
# Linear endpoint may appear only in the credential check.

retired_write_check() {
    python3 - "$1" <<'PYEOF'
import glob, os, re, sys

root = sys.argv[1]
STORE = re.compile(r'HERDR_LINEAR_STORE_DIR|\.claude/work(?![A-Za-z0-9_-])')
API = "api.linear.app"
FALLBACK = ("lib/repos.sh", "herdr_linear::_scope_old_dir")
DEF = re.compile(r'^(herdr_linear::[A-Za-z0-9_]+|[A-Za-z_][A-Za-z0-9_]*)\(\)\s*\{')

def code_lines(rel):
    text = open(os.path.join(root, rel), errors="replace").read()
    if rel.endswith(".md"):
        for fence in re.findall(r'```bash\n(.*?)```', text, re.S):
            for line in fence.splitlines():
                yield None, line
        return
    fn = None
    for line in text.splitlines():
        m = DEF.match(line)
        if m:
            fn = m.group(1)
        if line.startswith("}"):
            yield fn, line
            fn = None
            continue
        yield fn, line

code = []
for pat in ("lib/*.sh", "bin/*.sh", "hooks/*.sh", "skills/*/SKILL.md", "commands/*.md"):
    code += sorted(os.path.relpath(p, root) for p in glob.glob(os.path.join(root, pat)))
if not code:
    print("no shipped code under %s; nothing was checked" % root); sys.exit(1)

hits = []
for rel in code:
    for fn, line in code_lines(rel):
        if line.lstrip().startswith("#"):
            continue
        if STORE.search(line) and (rel, fn) != FALLBACK:
            hits.append("%s: names the old store: %s" % (rel, line.strip()))

for base, dirs, files in os.walk(root):
    dirs[:] = [d for d in dirs if d not in (".git", "tests")]
    for n in files:
        rel = os.path.relpath(os.path.join(base, n), root)
        if rel == "bin/migrate-credential.sh":
            continue
        try:
            if API in open(os.path.join(base, n), errors="replace").read():
                hits.append("%s: names %s" % (rel, API))
        except OSError:
            pass

print("\n".join(hits))
sys.exit(1 if hits else 0)
PYEOF
}

@test "nothing shipped writes the old store or calls Linear outside the credential check" {
    run retired_write_check "$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

retired_tree() {
    mkdir -p "$WORK/r/lib" "$WORK/r/bin" "$WORK/r/hooks" "$WORK/r/skills/start"
    printf 'herdr_linear::_scope_old_dir() {\n    printf "%%s/scopes" "${HERDR_LINEAR_STORE_DIR:-$HOME/.claude/work}"\n}\n' > "$WORK/r/lib/repos.sh"
    printf 'curl -s --config - <<<"url = \\"https://api.linear.app/graphql\\""\n' > "$WORK/r/bin/migrate-credential.sh"
    printf -- '---\nname: start\n---\nIt writes nothing under `~/.claude/work`.\n' > "$WORK/r/skills/start/SKILL.md"
}

@test "the retired-write check passes the read-only fallback and the credential check" {
    retired_tree
    run retired_write_check "$WORK/r"
    [ "$status" -eq 0 ]
}

@test "a library that writes under the old store turns the retired-write check red" {
    retired_tree
    printf 'herdr_linear::keep() {\n    printf x > "$HERDR_LINEAR_STORE_DIR/x"\n}\n' > "$WORK/r/lib/keep.sh"
    run retired_write_check "$WORK/r"
    [ "$status" -ne 0 ]
    [[ "$output" == *"lib/keep.sh"* ]]
}

@test "a second function in repos.sh that names the old store turns the check red" {
    retired_tree
    printf 'herdr_linear::scope_write() {\n    mkdir -p "$HOME/.claude/work/scopes"\n}\n' >> "$WORK/r/lib/repos.sh"
    run retired_write_check "$WORK/r"
    [ "$status" -ne 0 ]
    [[ "$output" == *"lib/repos.sh"* ]]
}

@test "a skill fence that writes the old store turns the retired-write check red" {
    retired_tree
    printf -- '```bash\nmkdir -p ~/.claude/work/scopes\n```\n' >> "$WORK/r/skills/start/SKILL.md"
    run retired_write_check "$WORK/r"
    [ "$status" -ne 0 ]
    [[ "$output" == *"skills/start/SKILL.md"* ]]
}

@test "a hook that calls the Linear API turns the retired-write check red" {
    retired_tree
    printf 'curl https://api.linear.app/graphql\n' > "$WORK/r/hooks/sync.sh"
    run retired_write_check "$WORK/r"
    [ "$status" -ne 0 ]
    [[ "$output" == *"hooks/sync.sh"* ]]
}

# ------------------------------------------------ the setup skill

setup_skill_path() { echo "$(cd "$BATS_TEST_DIRNAME/../.." && pwd)/skills/setup/SKILL.md"; }
setup_skill() { cat "$(setup_skill_path)"; }
setup_frontmatter() { awk 'NR==1 && /^---$/ {f=1; next} f && /^---$/ {exit} f' "$(setup_skill_path)"; }
# Its fences sit inside numbered steps, so they are indented.
setup_fences() { awk '/^ *```bash/ {f=1; next} /^ *```/ {f=0} f' "$(setup_skill_path)"; }

@test "the setup skill exists" {
    [ -f "$(setup_skill_path)" ]
}

# The /work command shadows a skill named work, and setup changes the machine,
# so only the person starts it.
@test "the setup skill is user-invoked and named setup" {
    run setup_frontmatter
    [[ "$output" == *"disable-model-invocation: true"* ]]
    run bash -c "awk -F': *' '/^name:/ {print \$2}' <<<\"\$1\"" _ "$output"
    [ "$output" = "setup" ]
}

@test "the setup skill's bash fences source only kept libraries and call only the two scripts" {
    fences="$(setup_fences)"
    [[ "$fences" == *"bin/setup-check.sh"* ]]
    run bash -c "grep -oE 'lib/[A-Za-z0-9_-]+\.sh' <<<\"\$1\" \
        | grep -vxE 'lib/(contain|sanitize|secrets)\.sh'" _ "$fences"
    [ -z "$output" ] || { echo "sources: $output"; return 1; }
    run bash -c "grep -oE 'bin/[A-Za-z0-9_-]+\.sh' <<<\"\$1\" \
        | grep -vxE 'bin/(setup-check|migrate-credential)\.sh'" _ "$fences"
    [ -z "$output" ] || { echo "calls: $output"; return 1; }
}

@test "the setup skill names no retired skill" {
    body="$(setup_skill)"
    for s in bind declare describe doc new new-project new-sub-issue board; do
        run grep -qE "/work:${s}([^a-z-]|\$)" <<<"$body"
        [ "$status" -ne 0 ] || { echo "names /work:$s"; return 1; }
    done
}

@test "the setup skill binds through the board with an explicit cwd" {
    body="$(setup_skill)"
    run grep -E '`bind`' <<<"$body"
    [ -n "$output" ]
    run grep -E '`cwd`' <<<"$body"
    [ -n "$output" ]
    [[ "$body" == *"linear-rules"* ]]
}

# The space binding is the person's, in the TUI: the agent opens the board
# beside them, never focused, and closes only what it opened.
@test "the setup skill opens the board as a split and closes it" {
    body="$(setup_skill)"
    [[ "$body" == *'`open_board`'* ]]
    run grep -E 'placement.*`split`' <<<"$body"
    [ -n "$output" ]
    [[ "$body" == *'`close_board`'* ]]
}

# setup_section <n>: the body of "## <n>." up to the next "## ".
setup_section() { awk -v n="## $1." 'index($0, n) == 1 {f=1; next} f && /^## / {exit} f' "$(setup_skill_path)"; }

# The board tools are deferred in a session that has them, so both binding
# steps load them first, and fall back to a new session when they do not load.
@test "both binding steps load the board tools before using them" {
    for n in 6 7; do
        body="$(setup_section "$n")"
        [[ "$body" == *'select:mcp__board__open_board,mcp__board__close_board,mcp__board__bind,mcp__board__state'* ]] \
            || { echo "step $n does not load the board tools"; return 1; }
        [[ "$body" == *"new Claude Code session"* ]] || { echo "step $n has no new-session path"; return 1; }
    done
}

@test "an old store to import ends with the final table, not a bare stop" {
    body="$(setup_section 3)"
    [[ "$body" == *"step 8"* ]]
    [[ "$body" != *"stop setup here"* ]]
}

# Placement and focus are the board's job; the skill's own bash moves nothing.
@test "the setup skill's fences run no herdr command" {
    [ -n "$(setup_fences)" ]
    run grep -nE '(^|[;|&(]|\$\() *herdr ' <<<"$(setup_fences)"
    [ -z "$output" ] || { echo "runs: $output"; return 1; }
}

@test "the setup skill edits no herdr config and installs nothing from upstream" {
    [ -n "$(setup_fences)" ]
    [[ "$(setup_fences)" != *"config.toml"* ]]
    [[ "$(setup_skill)" != *"nelsonPires5"* ]]
}

# A fix runs only when the check marks it a command; an instruction is the
# person's to do.
@test "the setup skill runs a fix only when its fix_kind is command" {
    body="$(setup_skill)"
    [[ "$body" == *"fix_kind"* ]]
    [[ "$body" == *'`command`'* ]]
    [[ "$body" == *'`instruction`'* ]]
}

# ------------------------------------------------ /work setup

@test "the command hands setup to the setup skill" {
    body="$(work_command)"
    [[ "$body" == *'## With `setup`'* ]]
    [[ "$body" == *'${CLAUDE_PLUGIN_ROOT}/skills/setup/SKILL.md'* ]]
    run awk -F': *' '/^argument-hint:/ {print $2}' <<<"$body"
    [[ "$output" == *setup* ]]
}

# /work's health block and setup-check.sh both judge the board, its daemon, the
# board mcp registration and a duplicate report hook. Each fixture below breaks
# one of those and runs both surfaces against the same fakes on PATH, so the two
# cannot drift into disagreeing about the same machine.

health_fence() {
    awk '/^### 2\. Health/ {h=1} h && /^```bash/ {f=1; next} f && /^```/ {exit} f' \
        "$(cd "$BATS_TEST_DIRNAME/../.." && pwd)/commands/work.md"
}

surfaces() {
    FIX="$BATS_TEST_DIRNAME/../fixtures"
    export HOME="$WORK/home"
    ANS="$WORK/answers"
    SBIN="$WORK/bin"
    mkdir -p "$HOME" "$ANS" "$SBIN" "$WORK/project"
    ln -s "$(command -v python3)" "$SBIN/python3"
    ln -s "$(command -v git)" "$SBIN/git"
    cp "$FIX/fake-board.sh" "$SBIN/board"
    cat > "$SBIN/claude" <<'SH'
#!/usr/bin/env bash
if [ "${FAKE_CLAUDE_MCP:-present}" = present ]; then
    case "$*" in
        "mcp list") printf 'board: board mcp - Connected\n'; exit 0 ;;
        "mcp get board") printf 'board:\n  Status: connected\n'; exit 0 ;;
    esac
fi
printf 'No MCP server named "board".\n'
exit 1
SH
    chmod +x "$SBIN/claude"
    printf '' > "$ANS/linear_report"
    printf '{"cli_version":"0.18.0","daemon_version":"0.18.0"}\n' > "$ANS/version"
    export FAKE_BOARD_RESPONSE_DIR="$ANS" FAKE_BOARD_LOG="$WORK/board.log"
    export HERDR_BIN="$FIX/fake-herdr.sh" FAKE_HERDR_RECORD_DIR="$WORK/herdr" FAKE_HERDR_VERSION=0.9.3
    export CLAUDE_PROJECT_DIR="$WORK/project"
    unset HERDR_LINEAR_CLAUDE_BIN HERDR_LINEAR_BOARD_BIN
    SPATH="$SBIN:/usr/bin:/bin"
}

run_health() {
    run env PATH="$SPATH" bash -c "$(health_fence)" </dev/null
}

check_state() {
    run env PATH="$SPATH" bash "$(cd "$BATS_TEST_DIRNAME/../.." && pwd)/bin/setup-check.sh" </dev/null
    [ "$status" -eq 0 ]
    printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]]["state"])' "$1"
}

@test "with every shared check passing, neither surface reports a failure" {
    surfaces
    run_health
    [ "$status" -eq 0 ]
    [ -z "$output" ] || { echo "health: $output"; return 1; }
    for k in board daemon board_mcp duplicate_hook; do
        s="$(check_state "$k")"
        [ "$s" = ok ] || { echo "$k: $s"; return 1; }
    done
}

@test "no board fails on both surfaces, and /work points at setup" {
    surfaces
    rm "$SBIN/board"
    run_health
    [[ "$output" == *"board is not installed"* ]]
    [[ "${lines[${#lines[@]}-1]}" == "Run /work setup to fix these." ]]
    [ "$(check_state board)" = missing ]
}

@test "a daemon that is not answering fails on both surfaces" {
    surfaces
    printf '{"cli_version":"0.18.0","daemon_version":null}\n' > "$ANS/version"
    run_health
    [[ "$output" == *"daemon is not answering"* ]]
    [[ "$output" == *"Run: board daemon status"* ]]
    [[ "$output" != *"daemon start"* ]]
    [[ "${lines[${#lines[@]}-1]}" == "Run /work setup to fix these." ]]
    [ "$(check_state daemon)" = missing ]
}

@test "a daemon on another version than the CLI fails on both surfaces" {
    surfaces
    printf '{"cli_version":"0.18.0","daemon_version":"0.17.9"}\n' > "$ANS/version"
    run_health
    [[ "$output" == *"daemon runs 0.17.9 and the CLI is 0.18.0"* ]]
    [[ "${lines[${#lines[@]}-1]}" == "Run /work setup to fix these." ]]
    [ "$(check_state daemon)" = old ]
}

@test "an unregistered board mcp fails on both surfaces" {
    surfaces
    export FAKE_CLAUDE_MCP=absent
    run_health
    [[ "$output" == *"board mcp is not registered"* ]]
    [[ "${lines[${#lines[@]}-1]}" == "Run /work setup to fix these." ]]
    [ "$(check_state board_mcp)" = missing ]
}

@test "a duplicate report hook fails on both surfaces" {
    surfaces
    mkdir -p "$HOME/.claude"
    printf '{"hooks":{"PostToolUse":[{"command":"board linear report"}]}}\n' > "$HOME/.claude/settings.json"
    run_health
    [[ "$output" == *"$HOME/.claude/settings.json has its own board linear report hook"* ]]
    [[ "${lines[${#lines[@]}-1]}" == "Run /work setup to fix these." ]]
    [ "$(check_state duplicate_hook)" = missing ]
}
