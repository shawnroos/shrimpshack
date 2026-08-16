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
    # OUTSIDE the worktree on purpose. A fixture source under $WORK makes the
    # containment assertions unfalsifiable — a preserved symlink still resolves
    # under $WORK — and the real sources (~/.agents/skills) are outside anyway.
    SRC="$(mktemp -d "${TMPDIR:-/tmp}/gw-skillsrc.XXXXXX")"; SRC="$(cd "$SRC" && pwd -P)"
}
teardown() { chmod -R u+w "$SRC" 2>/dev/null; rm -rf "$WORK" "$SRC"; }

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
    # A CHAIN: hop.md's own target resolves inside, and only the hop it points at
    # leaves. A containment check that resolves the target's parent rather than
    # the target itself reads this as safe.
    ln -s nested/escape.md "$root/real/hop.md"
}

# The two shapes every provisioning test needs, once. The `run env ... bash -c`
# incantation in particular is the kind of string a dropped quote breaks
# silently, so it is written in one place and not eight.
mk_linky_home() {
    HOME_FIXTURE="$WORK/fakehome"
    mkdir -p "$HOME_FIXTURE/skills"
    mk_skill_src "$SRC/src"
    ln -s "$SRC/src/link" "$HOME_FIXTURE/skills/linky"
    DEST="$WORK/.claude/skills/linky"
}

# Calls the real entry point. Assertions stay in the tests, where a failure
# names the case that failed.
provision() {
    env SPAWN_SKILLS_HOME="$HOME_FIXTURE" bash -c \
        '. "$1"; shift; spawn::skill_provision "$@"' _ "$LIB/skills.sh" "$WORK" "$MAN" "$@"
}

@test "a symlinked skill source provisions as a real directory the child can read" {
    mk_linky_home

    run provision linky
    [ "$status" -eq 0 ]

    local d="$DEST"
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
    mk_linky_home

    run provision linky

    local d="$DEST"
    # Neither a real file (that would place outside content in the worktree) nor
    # a surviving link (the ceiling refuses it and the reader blames permissions).
    [ ! -e "$d/nested/escape.md" ] && [ ! -L "$d/nested/escape.md" ] || {
        echo "escaping link survived provisioning: $(ls -l "$d/nested/escape.md")"; return 1; }
    run grep -rl SECRET "$d"
    [ -z "$output" ] || { echo "outside content was materialised inside the worktree"; return 1; }
    [ "$(cat "$SRC/src/outside/secret.md")" = "SECRET" ]

    # A link that stays inside the source root is still usable.
    [ -L "$d/inside.md" ]
    [ "$(cat "$d/inside.md")" = "nested content" ]

    # The chain head goes too. Resolving the target's PARENT reads hop.md as
    # safe (its parent is inside) and leaves it behind once the hop it points at
    # is pruned — reachability is the same, because a dangling link is ENOENT
    # rather than someone else's file, but the child is handed a broken path the
    # skill still references. Resolving the TARGET removes both.
    [ ! -L "$d/hop.md" ] || { echo "chain head survived as a dangling link"; return 1; }

    # The chain: nothing under the destination may RESOLVE outside it. A link
    # left dangling is fine — the child gets ENOENT, not someone else's file.
    run bash -c 'cd "$1" && for l in $(find . -type l); do
                     t="$(cd "$(dirname "$l")" && pwd -P)/$(readlink "$l")"
                     r="$(python3 -c "import os,sys;print(os.path.realpath(sys.argv[1]))" "$t")"
                     case "$r" in "$2"|"$2"/*) : ;; *) [ -e "$l" ] && echo "ESCAPES $l -> $r" ;; esac
                 done' _ "$d" "$(cd "$d" && pwd -P)"
    [ -z "$output" ] || { echo "$output"; return 1; }
}

@test "a real-directory source still provisions unchanged" {
    HOME_FIXTURE="$WORK/fakehome"; mkdir -p "$HOME_FIXTURE/skills/plain"
    echo "plain skill" > "$HOME_FIXTURE/skills/plain/SKILL.md"

    run provision plain
    [ "$status" -eq 0 ]
    [ ! -L "$WORK/.claude/skills/plain" ]
    [ "$(cat "$WORK/.claude/skills/plain/SKILL.md")" = "plain skill" ]
    run grep -c . "$MAN"
    [ "$output" = "1" ]
}

@test "teardown removes a symlink-sourced skill without touching its source" {
    mk_linky_home

    run provision linky
    [ "$status" -eq 0 ]
    # Without this, every assertion below passes vacuously when nothing landed.
    [ -d "$WORK/.claude/skills/linky" ]

    run sk spawn::skill_unprovision "$MAN"
    [ "$status" -eq 0 ]
    [ ! -e "$WORK/.claude/skills/linky" ]
    # The dereferenced copy means teardown deletes real files — the source must
    # not be one of them.
    [ "$(cat "$SRC/src/real/SKILL.md")" = "the skill" ]
    [ "$(cat "$SRC/src/real/nested/deep.md")" = "nested content" ]
    [ -L "$SRC/src/real/nested/escape.md" ]
}

# The prune is the only thing keeping an escaping link out of the worktree, so a
# prune that fails must not pass for one that worked. These two tests cover the
# ways it can go wrong quietly.

@test "a read-only source directory does not defeat the prune" {
    mk_linky_home
    # cp -R carries these modes to the copy, where they would make rm -f fail.
    chmod 555 "$SRC/src/real/nested"

    run provision linky
    [ "$status" -eq 0 ] || { echo "provisioning reported failure: $output"; return 1; }

    local d="$DEST"
    [ ! -e "$d/nested/escape.md" ] && [ ! -L "$d/nested/escape.md" ] || {
        echo "escaping link survived a read-only parent: $(ls -l "$d/nested/escape.md")"; return 1; }
}

@test "a prune it cannot perform is reported and fails, never silently skipped" {
    mkdir -p "$WORK/dest/nested" "$SRC/outside"
    echo SECRET > "$SRC/outside/secret.md"
    ln -s "$SRC/outside/secret.md" "$WORK/dest/nested/escape.md"
    chmod 555 "$WORK/dest/nested"

    run sk spawn::skill_prune_escaping_links "$WORK/dest" linky
    chmod 755 "$WORK/dest/nested"
    [ "$status" -ne 0 ] || { echo "a failed prune reported success"; return 1; }
    [[ "$output" == *skill_link_prune_failed* ]] || { echo "no diagnostic: $output"; return 1; }
    [ -L "$WORK/dest/nested/escape.md" ]
}

# rc is the ONLY channel bg-agent reads (it calls sup_reason on a non-zero return
# and nothing reads skills.err), so a pruner failure that does not reach rc is
# invisible to the job report. Stubbed because the chmod above removes the only
# reachable way to make a real prune fail.
@test "a pruner failure reaches the caller's exit status" {
    HOME_FIXTURE="$WORK/fakehome"; mkdir -p "$HOME_FIXTURE/skills/plain"
    echo "plain skill" > "$HOME_FIXTURE/skills/plain/SKILL.md"

    # Proven to land WITHOUT the stub first, so the assertion below cannot pass
    # because the skill failed to resolve.
    run provision plain
    [ "$status" -eq 0 ]
    rm -rf "$WORK/.claude/skills/plain"; : > "$MAN"

    run env SPAWN_SKILLS_HOME="$HOME_FIXTURE" bash -c \
        '. "$1"; spawn::skill_prune_escaping_links() { return 1; }
         spawn::skill_provision "$2" "$3" plain' _ "$LIB/skills.sh" "$WORK" "$MAN"
    [ "$status" -ne 0 ] || { echo "the pruner failed and provisioning still reported success"; return 1; }
    [ ! -e "$WORK/.claude/skills/plain" ] || { echo "a skill was published despite a failed prune"; return 1; }
}

@test "a skill whose SKILL.md is pruned away fails instead of reporting success" {
    HOME_FIXTURE="$WORK/fakehome"; mkdir -p "$HOME_FIXTURE/skills"
    mkdir -p "$SRC/gutted" "$SRC/elsewhere"
    echo "the real skill" > "$SRC/elsewhere/SKILL.md"
    ln -s ../elsewhere/SKILL.md "$SRC/gutted/SKILL.md"
    echo "extra" > "$SRC/gutted/other.md"
    ln -s "$SRC/gutted" "$HOME_FIXTURE/skills/gutted"

    run provision gutted
    [ "$status" -ne 0 ] || { echo "an empty skill was reported as provisioned"; return 1; }
    [[ "$output" == *skill_incomplete* ]] || { echo "no skill_incomplete diagnostic: $output"; return 1; }

    # Nothing published and nothing recorded: the child never sees a half skill,
    # and teardown has nothing to reason about.
    [ ! -e "$WORK/.claude/skills/gutted" ] || { echo "an incomplete skill was published"; return 1; }
    [ ! -s "$MAN" ] || { echo "manifest recorded a skill that never landed: $(cat "$MAN")"; return 1; }
    run bash -c 'ls -A "$1"' _ "$WORK/.claude/skills"
    [ -z "$output" ] || { echo "staging left behind: $output"; return 1; }
}

# The staging directory is what lets these three be assertions rather than
# apologies: a skill is published in one `mv` or not at all.

@test "a copy that fails partway publishes nothing and records nothing" {
    HOME_FIXTURE="$WORK/fakehome"; mkdir -p "$HOME_FIXTURE/skills/partial/sub"
    echo "the skill" > "$HOME_FIXTURE/skills/partial/SKILL.md"
    echo "readable" > "$HOME_FIXTURE/skills/partial/sub/ok.md"
    echo "secret" > "$HOME_FIXTURE/skills/partial/sub/denied.md"
    chmod 000 "$HOME_FIXTURE/skills/partial/sub/denied.md"

    run provision partial
    chmod 644 "$HOME_FIXTURE/skills/partial/sub/denied.md"
    [ "$status" -ne 0 ] || { echo "a failed copy reported success"; return 1; }

    [ ! -e "$WORK/.claude/skills/partial" ] || { echo "a half-copied skill was published"; return 1; }
    [ ! -s "$MAN" ] || { echo "manifest recorded a skill that never landed"; return 1; }
    run bash -c 'ls -A "$1"' _ "$WORK/.claude/skills"
    [ -z "$output" ] || { echo "staging left behind: $output"; return 1; }
}

@test "a skill that resolves paths against its own plugin root is refused" {
    HOME_FIXTURE="$WORK/fakehome"; mkdir -p "$HOME_FIXTURE/skills/rooted"
    printf 'read %s/lib/thing.sh\n' '${CLAUDE_PLUGIN_ROOT}' > "$HOME_FIXTURE/skills/rooted/SKILL.md"

    run provision rooted
    [ "$status" -ne 0 ] || { echo "a skill that cannot work when copied was provisioned"; return 1; }
    [[ "$output" == *skill_not_selfcontained* ]] || { echo "wrong diagnostic: $output"; return 1; }
    [ ! -e "$WORK/.claude/skills/rooted" ]
}

@test "an invalid name is reported as invalid, not as missing" {
    HOME_FIXTURE="$WORK/fakehome"; mkdir -p "$HOME_FIXTURE/skills"

    run provision "a..b"
    [ "$status" -ne 0 ]
    # Validating after resolution made this branch unreachable: every bad name
    # came back as `not found`, naming the wrong problem.
    [[ "$output" == *skill_name_invalid* ]] || { echo "wrong diagnostic: $output"; return 1; }
}

@test "provisioning refuses to overwrite a skill that already exists" {
    mkdir -p "$WORK/.claude/skills/ce-code-review"
    echo "the user's own" > "$WORK/.claude/skills/ce-code-review/SKILL.md"
    run sk spawn::skill_provision "$WORK" "$MAN" ce-code-review
    [ "$status" -ne 0 ]
    run cat "$WORK/.claude/skills/ce-code-review/SKILL.md"
    [ "$output" = "the user's own" ]
}
