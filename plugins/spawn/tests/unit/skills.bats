#!/usr/bin/env bats
# Skill provisioning for a background child.
#
# A bg-agent child runs with --setting-sources project, so it does NOT inherit
# the operator's skills: a job told to "run ce-code-review" has none. The
# supervisor copies the named skills where the child can read them, and the
# ceiling's deny on .claude/** means the child can use one but not edit it or
# add itself another.
#
# THE LOAD-BEARING TEST IN THIS FILE IS THE TRAVERSAL ONE. An adversarial review
# found that `basename "$name" | tr -d '/'` passes `..` through untouched, so the
# destination resolved to <worktree>/.claude — and teardown rm -rf'd it, taking
# the user's entire agent configuration. Reproduced before it was fixed.

setup() {
    LIB="$(cd "$BATS_TEST_DIRNAME/../../lib" && pwd)"
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/gw-skills.XXXXXX")"; WORK="$(cd "$WORK" && pwd -P)"
    ( cd "$WORK" && git init -q . )
    MAN="$WORK/.manifest"
}
teardown() { rm -rf "$WORK"; }

sk() { bash -c '. "$1"; shift; "$@"' _ "$LIB/skills.sh" "$@"; }

@test "the grammar accepts real skill names and refuses traversal" {
    for good in ce-code-review compound-engineering:ce-code-review agent-browser a_b.c-d; do
        run sk spawn::skill_name_ok "$good"
        [ "$status" -eq 0 ] || { echo "rejected a valid name: $good"; return 1; }
    done
    for bad in .. ../.. . "a/../.." "x;rm -rf /" "" "-lead" "a..b" "/etc/passwd"; do
        run sk spawn::skill_name_ok "$bad"
        [ "$status" -ne 0 ] || { echo "ACCEPTED a bad name: $bad"; return 1; }
    done
}

# A PROPERTY TEST, NOT A REGRESSION TEST — labelled honestly because two earlier
# versions of it were neither. A reviewer reported `..` as a P0 that would
# rm -rf the user's .claude directory. Measured: rm REFUSES a trailing `..`, and
# the copy was already blocked because the destination resolved to an existing
# directory and hit the collision check. The reported defect was not reachable.
#
# Both earlier versions of this test stayed GREEN with the fix reverted, which is
# what proved that rather than any reading of the code. It is kept as a statement
# of the property that must hold — a traversal name never places or removes
# anything outside the skills directory — and NOT dressed up as a regression it
# never was.
@test "property: a traversal name places and removes nothing outside the skills dir" {
    mkdir -p "$WORK/.claude/skills" "$WORK/.claude/precious"
    echo keep > "$WORK/.claude/precious/data.txt"

    local fake="$WORK/fakehome"; mkdir -p "$fake/skills"
    echo "payload" > "$fake/SKILL.md"

    run env SPAWN_SKILLS_HOME="$fake" bash -c \
        '. "$1"; spawn::skill_provision "$2" "$3" ".."' _ "$LIB/skills.sh" "$WORK" "$MAN"
    [ "$status" -ne 0 ]

    [ -f "$WORK/.claude/precious/data.txt" ]
    run bash -c 'ls "$1"/.claude | sort | tr "\n" " "' _ "$WORK"
    [ "$output" = "precious skills " ]

    printf '%s\n' "$WORK/.claude/skills/.." > "$MAN"
    run bash -c '. "$1"; spawn::skill_unprovision "$2"' _ "$LIB/skills.sh" "$MAN"
    [ -d "$WORK/.claude" ]
    [ -f "$WORK/.claude/precious/data.txt" ]
}

@test "resolution picks the INSTALLED plugin version, not any cached one" {
    # ce-code-review exists at several cached versions on a real box; picking
    # 'a match' or 'the highest' hands the job a stale skill that still looks
    # right. The installed record is the only authority.
    run sk spawn::skill_resolve ce-code-review
    [ "$status" -eq 0 ]
    [ -f "$output/SKILL.md" ]
    local want; want="$(python3 -c "
import json,os
d=json.load(open(os.path.expanduser('~/.claude/plugins/installed_plugins.json')))
def w(n):
    if isinstance(n,dict):
        for k,v in n.items():
            if isinstance(v,list):
                for e in v:
                    if isinstance(e,dict) and e.get('installPath'): yield k,e['installPath']
            else: yield from w(v)
for k,p in w(d):
    if 'compound-engineering' in k: print(p); break
" 2>/dev/null)"
    [ -n "$want" ] || skip "compound-engineering not installed on this box"
    [[ "$output" == "$want"* ]]
}

@test "a provisioned skill lands, is invisible to git, and teardown removes exactly it" {
    run sk spawn::skill_git_exclude "$WORK"
    run sk spawn::skill_provision "$WORK" "$MAN" ce-code-review
    [ "$status" -eq 0 ]
    [ -f "$WORK/.claude/skills/ce-code-review/SKILL.md" ]

    # `.claude` is not gitignored in a normal repo here, so without the exclude a
    # 500KB skill lands in git status, one `git add -A` from being committed.
    run bash -c 'cd "$1" && git status --porcelain | grep -c "\.claude/skills"' _ "$WORK"
    [ "$output" = "0" ]

    # A file the USER put beside it must survive teardown.
    mkdir -p "$WORK/.claude/skills/mine"; echo x > "$WORK/.claude/skills/mine/SKILL.md"
    run sk spawn::skill_unprovision "$MAN"
    [ ! -e "$WORK/.claude/skills/ce-code-review" ]
    [ -f "$WORK/.claude/skills/mine/SKILL.md" ]
}

# Most entries in ~/.claude/skills on this box are symlinks into ~/.agents/skills
# — direct-writing, clean-code, agent-browser and more. `cp -R` preserved the
# link, the ceiling resolved it outside the worktree, and every read the child
# made was refused: a job landed degraded blaming permissions for a provisioning
# bug. These tests assert what the CHILD can reach, not what cp was told to do.

# A source tree with both shapes of nested link, plus content outside it that
# must never become a real file inside the worktree.
mk_skill_src() {
    local root="$1"
    mkdir -p "$root/real/nested" "$root/outside"
    echo "the skill" > "$root/real/SKILL.md"
    echo "nested content" > "$root/real/nested/deep.md"
    echo "SECRET" > "$root/outside/secret.md"
    ln -s ../../outside/secret.md "$root/real/nested/escape.md"
    ln -s nested/deep.md "$root/real/inside.md"
    ln -s "$root/real" "$root/link"
}

@test "a symlinked skill source provisions as a real directory the child can read" {
    local home="$WORK/fakehome"; mkdir -p "$home/skills"
    mk_skill_src "$WORK/src"
    ln -s "$WORK/src/link" "$home/skills/linky"

    run env SPAWN_SKILLS_HOME="$home" bash -c \
        '. "$1"; spawn::skill_provision "$2" "$3" linky' _ "$LIB/skills.sh" "$WORK" "$MAN"
    [ "$status" -eq 0 ]

    local d="$WORK/.claude/skills/linky"
    [ ! -L "$d" ] || { echo "destination is still a symlink — the child's read resolves outside"; return 1; }
    [ -d "$d" ]

    # The reachability assertion: every path stays inside the worktree when
    # resolved, which is the thing the ceiling actually matches on.
    [ "$(cat "$d/SKILL.md")" = "the skill" ]
    [ ! -L "$d/SKILL.md" ]
    [ "$(cat "$d/nested/deep.md")" = "nested content" ]
    [ ! -L "$d/nested/deep.md" ]
    local real_deep; real_deep="$(cd "$d/nested" && pwd -P)"
    [[ "$real_deep" == "$WORK"/* ]] || { echo "nested content resolves outside: $real_deep"; return 1; }

    run grep -c . "$MAN"
    [ "$output" = "1" ]
}

@test "a nested link escaping the source root is pruned, not materialised" {
    local home="$WORK/fakehome"; mkdir -p "$home/skills"
    mk_skill_src "$WORK/src"
    ln -s "$WORK/src/link" "$home/skills/linky"

    run env SPAWN_SKILLS_HOME="$home" bash -c \
        '. "$1"; spawn::skill_provision "$2" "$3" linky' _ "$LIB/skills.sh" "$WORK" "$MAN"

    local d="$WORK/.claude/skills/linky"
    # Neither a real file (that would place outside content in the worktree) nor
    # a surviving link (the ceiling refuses it and the reader blames permissions).
    [ ! -e "$d/nested/escape.md" ] && [ ! -L "$d/nested/escape.md" ] || {
        echo "escaping link survived provisioning: $(ls -l "$d/nested/escape.md")"; return 1; }
    run grep -rl SECRET "$d"
    [ -z "$output" ] || { echo "outside content was materialised inside the worktree"; return 1; }
    [ "$(cat "$WORK/src/outside/secret.md")" = "SECRET" ]

    # A link that stays inside the source root is still usable.
    [ -L "$d/inside.md" ]
    [ "$(cat "$d/inside.md")" = "nested content" ]
}

@test "a real-directory source still provisions unchanged" {
    local home="$WORK/fakehome"; mkdir -p "$home/skills/plain"
    echo "plain skill" > "$home/skills/plain/SKILL.md"

    run env SPAWN_SKILLS_HOME="$home" bash -c \
        '. "$1"; spawn::skill_provision "$2" "$3" plain' _ "$LIB/skills.sh" "$WORK" "$MAN"
    [ "$status" -eq 0 ]
    [ ! -L "$WORK/.claude/skills/plain" ]
    [ "$(cat "$WORK/.claude/skills/plain/SKILL.md")" = "plain skill" ]
    run grep -c . "$MAN"
    [ "$output" = "1" ]
}

@test "teardown removes a symlink-sourced skill without touching its source" {
    local home="$WORK/fakehome"; mkdir -p "$home/skills"
    mk_skill_src "$WORK/src"
    ln -s "$WORK/src/link" "$home/skills/linky"

    run env SPAWN_SKILLS_HOME="$home" bash -c \
        '. "$1"; spawn::skill_provision "$2" "$3" linky' _ "$LIB/skills.sh" "$WORK" "$MAN"
    run sk spawn::skill_unprovision "$MAN"
    [ ! -e "$WORK/.claude/skills/linky" ]
    # The dereferenced copy means teardown deletes real files — the source must
    # not be one of them.
    [ "$(cat "$WORK/src/real/SKILL.md")" = "the skill" ]
    [ "$(cat "$WORK/src/real/nested/deep.md")" = "nested content" ]
    [ -L "$WORK/src/real/nested/escape.md" ]
}

@test "provisioning refuses to overwrite a skill that already exists" {
    mkdir -p "$WORK/.claude/skills/ce-code-review"
    echo "the user's own" > "$WORK/.claude/skills/ce-code-review/SKILL.md"
    run sk spawn::skill_provision "$WORK" "$MAN" ce-code-review
    [ "$status" -ne 0 ]
    run cat "$WORK/.claude/skills/ce-code-review/SKILL.md"
    [ "$output" = "the user's own" ]
}
