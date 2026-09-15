#!/usr/bin/env bats

load setup_common

# U11 — worktree removal. Every repository here is real and local: a bare
# remote, a main checkout under the projects root, and a linked worktree under
# the worktrees root. gh and the process lister are fakes on seams; nothing
# reads the network or this machine's processes.

bats_require_minimum_version 1.5.0

refute_match() {
    if grep "$@"; then
        printf 'refute_match: unexpectedly matched: %s\n' "$*" >&2
        return 1
    fi
    return 0
}

setup() {
    LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
    # shellcheck source=/dev/null
    . "$LIB_DIR/worktree-remove.sh"

    export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
    export GIT_CONFIG_NOSYSTEM=1
    git config --global user.name tester
    git config --global user.email tester@example.invalid
    git config --global init.defaultBranch main

    BIN="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$BIN" "$HERDR_LINEAR_PROJECTS_ROOT" "$HERDR_LINEAR_WORKTREES_ROOT"

    cat >"$BIN/lsof" <<'EOF'
#!/usr/bin/env bash
[ -e "$FAKE_LSOF_FAIL" ] && exit 1
[ -e "$FAKE_LSOF_EMPTY" ] && exit 0
printf 'p1\nfcwd\nn/\n'
[ -e "$FAKE_LSOF_EXTRA" ] && cat "$FAKE_LSOF_EXTRA"
exit 0
EOF
    cat >"$BIN/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_GH_CALLS"
[ -e "$FAKE_GH_REPLY" ] && cat "$FAKE_GH_REPLY"
exit 0
EOF
    chmod +x "$BIN/lsof" "$BIN/gh"
    export HERDR_LINEAR_LSOF_BIN="$BIN/lsof"
    export FAKE_LSOF_FAIL="$BATS_TEST_TMPDIR/lsof-fail"
    export FAKE_LSOF_EMPTY="$BATS_TEST_TMPDIR/lsof-empty"
    export FAKE_LSOF_EXTRA="$BATS_TEST_TMPDIR/lsof-extra"
    export FAKE_GH_REPLY="$BATS_TEST_TMPDIR/gh-reply"
    export FAKE_GH_CALLS="$BATS_TEST_TMPDIR/gh-calls"

    REMOTE="$BATS_TEST_TMPDIR/remote.git"
    MAIN="$HERDR_LINEAR_PROJECTS_ROOT/repo"
    WT="$HERDR_LINEAR_WORKTREES_ROOT/web-12"
    git init -q --bare "$REMOTE"
    git clone -q "$REMOTE" "$MAIN" 2>/dev/null
    git -C "$MAIN" commit -q --allow-empty -m base
    git -C "$MAIN" push -q origin main
    git -C "$MAIN" worktree add -q -b feature/web-12 "$WT"
    printf 'work\n' >"$WT/work.txt"
    git -C "$WT" add work.txt
    git -C "$WT" commit -q -m work
}

use_gh() { export HERDR_LINEAR_GH_BIN="$BIN/gh"; }

push_branch() { git -C "$WT" push -q origin feature/web-12 2>/dev/null; }

answer_nonce() { herdr_linear::worktree_remove_propose "$WT"; }

branch_exists() { git -C "$MAIN" show-ref --verify --quiet refs/heads/feature/web-12; }

@test "a clean worktree whose commits are all on a remote is removed with its branch" {
    push_branch
    nonce="$(answer_nonce)"
    run herdr_linear::worktree_remove "$WT" "$nonce"
    [ "$status" -eq 0 ]
    [[ "$output" == *"removed the worktree and branch feature/web-12"* ]]
    [ ! -e "$WT" ]
    run branch_exists
    [ "$status" -ne 0 ]
    run herdr_linear::board_questions_pending
    [ -z "$output" ]
}

@test "a worktree holding an ignored local file is kept, and a regenerable ignored directory does not block removal" {
    push_branch
    printf '.env\nnode_modules/\n' >"$WT/.gitignore"
    git -C "$WT" add .gitignore && git -C "$WT" -c user.email=t@t -c user.name=t commit -q -m ignore
    git -C "$WT" push -q origin HEAD 2>/dev/null
    printf 'SECRET=1\n' >"$WT/.env"
    mkdir -p "$WT/node_modules/x" && printf 'x\n' >"$WT/node_modules/x/index.js"
    nonce="$(answer_nonce)"
    run herdr_linear::worktree_remove "$WT" "$nonce"
    [ "$status" -eq 1 ]
    [[ "$output" == *"kept: it holds ignored local files git would delete: .env"* ]]
    [ -e "$WT/.env" ]
    rm "$WT/.env"
    nonce="$(answer_nonce)"
    run herdr_linear::worktree_remove "$WT" "$nonce"
    [ "$status" -eq 0 ]
    [ ! -e "$WT" ]
}

@test "a worktree with an uncommitted file is kept and the refusal names the reason" {
    push_branch
    nonce="$(answer_nonce)"
    printf 'draft\n' >"$WT/draft.txt"
    run herdr_linear::worktree_remove "$WT" "$nonce"
    [ "$status" -eq 1 ]
    [[ "$output" == *"kept: it has uncommitted changes"* ]]
    [ -e "$WT/draft.txt" ]
    branch_exists
}

@test "a worktree whose commits exist on no remote and in no merged pull request is kept" {
    use_gh
    printf 'OPEN %s\n' "$(git -C "$WT" rev-parse HEAD)" >"$FAKE_GH_REPLY"
    nonce="$(answer_nonce)"
    run herdr_linear::worktree_remove "$WT" "$nonce"
    [ "$status" -eq 1 ]
    [[ "$output" == *"kept: its commits are on no remote and in no merged pull request"* ]]
    [ -e "$WT/work.txt" ]
    branch_exists
    grep -q 'pr view feature/web-12' "$FAKE_GH_CALLS"
}

@test "without gh a worktree whose commits are only local is kept" {
    nonce="$(answer_nonce)"
    run herdr_linear::worktree_remove "$WT" "$nonce"
    [ "$status" -eq 1 ]
    [[ "$output" == *"kept: its commits are on no remote"* ]]
    [ -e "$WT/work.txt" ]
}

@test "a branch deleted on the remote but still tracked locally is kept" {
    push_branch
    git -C "$MAIN" fetch -q origin
    git -C "$MAIN" push -q origin --delete feature/web-12 2>/dev/null
    git -C "$MAIN" update-ref refs/remotes/origin/feature/web-12 "$(git -C "$WT" rev-parse HEAD)"
    nonce="$(answer_nonce)"
    run herdr_linear::worktree_remove "$WT" "$nonce"
    [ "$status" -eq 1 ]
    [[ "$output" == *"kept: its commits are on no remote"* ]]
    [ -e "$WT/work.txt" ]
}

@test "an unreachable remote is named when it keeps the worktree" {
    push_branch
    nonce="$(answer_nonce)"
    git -C "$MAIN" remote set-url origin "$BATS_TEST_TMPDIR/no-such-remote.git"
    run herdr_linear::worktree_remove "$WT" "$nonce"
    [ "$status" -eq 1 ]
    [[ "$output" == *"kept: its commits are on no reachable remote (could not reach: origin)"* ]]
    [ -e "$WT/work.txt" ]
}

@test "a branch that moves to an undelivered commit during removal is kept" {
    push_branch
    extra="$(git -C "$MAIN" commit-tree -p "$(git -C "$WT" rev-parse HEAD)" -m local "$(git -C "$WT" rev-parse 'HEAD^{tree}')")"
    cat >"$BIN/git" <<SCRIPT
#!/usr/bin/env bash
git "\$@"; rc=\$?
case " \$* " in *" worktree remove "*) git -C "$MAIN" update-ref refs/heads/feature/web-12 "$extra" ;; esac
exit \$rc
SCRIPT
    chmod +x "$BIN/git"
    nonce="$(answer_nonce)"
    HERDR_LINEAR_GIT_BIN="$BIN/git" run herdr_linear::worktree_remove "$WT" "$nonce"
    [ "$status" -eq 0 ]
    [[ "$output" == *"removed the worktree; kept branch feature/web-12: its commits are on no remote"* ]]
    [ ! -e "$WT" ]
    branch_exists
}

@test "a squash-merged branch whose remote branch was deleted is removed without a question" {
    use_gh
    push_branch
    git -C "$MAIN" merge -q --squash feature/web-12 >/dev/null
    git -C "$MAIN" commit -q -m "squash web-12"
    git -C "$MAIN" push -q origin main
    git -C "$MAIN" push -q origin --delete feature/web-12 2>/dev/null
    printf 'MERGED %s\n' "$(git -C "$WT" rev-parse HEAD)" >"$FAKE_GH_REPLY"
    nonce="$(answer_nonce)"
    run herdr_linear::worktree_remove "$WT" "$nonce"
    [ "$status" -eq 0 ]
    [[ "$output" == *"removed the worktree and branch feature/web-12"* ]]
    [ ! -e "$WT" ]
    run branch_exists
    [ "$status" -ne 0 ]
}

@test "a commit made after the pull request merged is kept" {
    use_gh
    printf 'MERGED %s\n' "$(git -C "$WT" rev-parse HEAD)" >"$FAKE_GH_REPLY"
    printf 'more\n' >>"$WT/work.txt"
    git -C "$WT" commit -q -am after
    nonce="$(answer_nonce)"
    run herdr_linear::worktree_remove "$WT" "$nonce"
    [ "$status" -eq 1 ]
    [[ "$output" == *"kept: its commits are on no remote and in no merged pull request"* ]]
    [ -e "$WT/work.txt" ]
}

@test "a removal without an answered question's nonce is refused" {
    push_branch
    run herdr_linear::worktree_remove "$WT" ""
    [ "$status" -eq 2 ]
    [[ "$output" == *"refused: removing a worktree needs the nonce of an answered question"* ]]

    run herdr_linear::worktree_remove "$WT" "0000000000000000000000000000dead"
    [ "$status" -eq 2 ]
    [[ "$output" == *"refused: there is no pending question to remove this worktree"* ]]

    answer_nonce >/dev/null
    run herdr_linear::worktree_remove "$WT" "0000000000000000000000000000dead"
    [ "$status" -eq 2 ]
    [[ "$output" == *"refused: the removal question was not answered"* ]]
    [ -e "$WT/work.txt" ]
    branch_exists
}

@test "the nonce of a question of another kind is refused" {
    push_branch
    key="$(herdr_linear::worktree_remove_key "$WT")"
    nonce="$(herdr_linear::board_question_propose "$key" move "$(herdr_linear::worktree_remove_preconditions "$WT")")"
    run herdr_linear::worktree_remove "$WT" "$nonce"
    [ "$status" -eq 2 ]
    [[ "$output" == *"refused: the pending question for this worktree is not a removal question"* ]]
    [ -e "$WT/work.txt" ]
}

@test "a question proposed before a new commit no longer authorises removal" {
    push_branch
    nonce="$(answer_nonce)"
    printf 'more\n' >>"$WT/work.txt"
    git -C "$WT" commit -q -am after
    git -C "$WT" push -q origin feature/web-12 2>/dev/null
    run herdr_linear::worktree_remove "$WT" "$nonce"
    [ "$status" -eq 2 ]
    [[ "$output" == *"refused: the removal question was not answered"* ]]
    [ -e "$WT/work.txt" ]
}

@test "a worktree with a process running inside it is kept" {
    push_branch
    mkdir -p "$WT/src"
    printf 'p4242\nfcwd\nn%s\n' "$WT/src" >"$FAKE_LSOF_EXTRA"
    nonce="$(answer_nonce)"
    run herdr_linear::worktree_remove "$WT" "$nonce"
    [ "$status" -eq 1 ]
    [[ "$output" == *"kept: process 4242 is running inside it"* ]]
    [ -e "$WT/work.txt" ]
    rmdir "$WT/src"
}

@test "a process in a sibling whose name starts with the worktree's does not keep it" {
    push_branch
    mkdir -p "${WT}-other"
    printf 'p4242\nfcwd\nn%s\n' "${WT}-other" >"$FAKE_LSOF_EXTRA"
    nonce="$(answer_nonce)"
    run herdr_linear::worktree_remove "$WT" "$nonce"
    [ "$status" -eq 0 ]
    [ ! -e "$WT" ]
}

@test "an unresolvable process working directory counts as in use" {
    push_branch
    printf 'p4242\nfcwd\nn%s\n' "$BATS_TEST_TMPDIR/deleted-dir" >"$FAKE_LSOF_EXTRA"
    nonce="$(answer_nonce)"
    run herdr_linear::worktree_remove "$WT" "$nonce"
    [ "$status" -eq 1 ]
    [[ "$output" == *"kept: process 4242 has a working directory that cannot be resolved"* ]]
    [ -e "$WT/work.txt" ]
}

@test "a process listed with no working directory counts as in use" {
    push_branch
    printf 'p4242\nfcwd\n' >"$FAKE_LSOF_EXTRA"
    nonce="$(answer_nonce)"
    run herdr_linear::worktree_remove "$WT" "$nonce"
    [ "$status" -eq 1 ]
    [[ "$output" == *"kept: process 4242 has a working directory that cannot be resolved"* ]]
    [ -e "$WT/work.txt" ]
}

@test "a process listed with no working directory before another process counts as in use" {
    push_branch
    printf 'p4242\nfcwd\np4343\nfcwd\nn/\n' >"$FAKE_LSOF_EXTRA"
    nonce="$(answer_nonce)"
    run herdr_linear::worktree_remove "$WT" "$nonce"
    [ "$status" -eq 1 ]
    [[ "$output" == *"kept: process 4242 has a working directory that cannot be resolved"* ]]
    [ -e "$WT/work.txt" ]
}

@test "an empty process list keeps the worktree" {
    push_branch
    touch "$FAKE_LSOF_EMPTY"
    nonce="$(answer_nonce)"
    run herdr_linear::worktree_remove "$WT" "$nonce"
    [ "$status" -eq 1 ]
    [[ "$output" == *"kept: the process list could not be read"* ]]
    [ -e "$WT/work.txt" ]
}

@test "a process list that cannot be read keeps the worktree" {
    push_branch
    touch "$FAKE_LSOF_FAIL"
    nonce="$(answer_nonce)"
    run herdr_linear::worktree_remove "$WT" "$nonce"
    [ "$status" -eq 1 ]
    [[ "$output" == *"kept: the process list could not be read"* ]]
    [ -e "$WT/work.txt" ]
}

@test "a path outside the worktrees root is refused" {
    outside="$BATS_TEST_TMPDIR/elsewhere"
    git -C "$MAIN" worktree add -q -b feature/outside "$outside"
    run herdr_linear::worktree_remove_propose "$outside"
    [ "$status" -eq 2 ]
    [[ "$output" == *"refused: that path is not inside the worktrees root"* ]]
    run herdr_linear::worktree_remove "$outside" "0000000000000000000000000000dead"
    [ "$status" -eq 2 ]
    [[ "$output" == *"refused: that path is not inside the worktrees root"* ]]
    [ -d "$outside" ]
}

@test "a symlink inside the worktrees root that points outside it is refused" {
    outside="$BATS_TEST_TMPDIR/elsewhere"
    git -C "$MAIN" worktree add -q -b feature/outside "$outside"
    ln -s "$outside" "$HERDR_LINEAR_WORKTREES_ROOT/link"
    run herdr_linear::worktree_remove "$HERDR_LINEAR_WORKTREES_ROOT/link" "0000000000000000000000000000dead"
    [ "$status" -eq 2 ]
    [[ "$output" == *"refused: that path is not inside the worktrees root"* ]]
    [ -d "$outside" ]
}

@test "a worktrees root that is the projects root is refused" {
    export HERDR_LINEAR_WORKTREES_ROOT="$HERDR_LINEAR_PROJECTS_ROOT"
    run herdr_linear::worktree_remove "$MAIN" "0000000000000000000000000000dead"
    [ "$status" -eq 2 ]
    [[ "$output" == *"refused: the worktrees root is the projects root"* ]]
    [ -d "$MAIN/.git" ]
}

@test "a main checkout inside the worktrees root is refused" {
    clone="$HERDR_LINEAR_WORKTREES_ROOT/clone"
    git clone -q "$REMOTE" "$clone" 2>/dev/null
    run herdr_linear::worktree_remove_propose "$clone"
    [ "$status" -eq 2 ]
    [[ "$output" == *"refused: that path is a main checkout, not a linked worktree"* ]]
    [ -d "$clone/.git" ]
}

@test "a directory inside a worktree is refused" {
    mkdir -p "$WT/src"
    run herdr_linear::worktree_remove_propose "$WT/src"
    [ "$status" -eq 2 ]
    [[ "$output" == *"refused: that path is inside a worktree, not the worktree itself"* ]]
}

@test "the worktrees root itself is refused" {
    run herdr_linear::worktree_remove "$HERDR_LINEAR_WORKTREES_ROOT" "0000000000000000000000000000dead"
    [ "$status" -eq 2 ]
    [[ "$output" == *"refused: that path is not inside the worktrees root"* ]]
}
