#!/usr/bin/env bats
# U4 — deterministic pre-pass signals (F/D/L/RS). Test-first.
#
# The fixture is built in a throwaway git repo inside each test (content authored
# here, never resolved from the plugin's own HEAD — the §8 baseline-pinning rule).

PREPASS="$BATS_TEST_DIRNAME/../../skills/multi-slice-review/scripts/prepass.sh"

# Build a temp git repo with a known base commit, then a change set spanning
# 4 subsystems (src/storage, src/net, src/api, root) with known risk surfaces.
# Golden signals: F=4, D=4, L=10, RS=api,concurrency,destructive,io,untrusted
setup() {
    REPO="$(mktemp -d)"
    cd "$REPO"
    git init -q
    git config user.email t@t.t
    git config user.name t
    printf 'seed\n' > seed.txt
    git add -A && git commit -qm base
    BASE="$(git rev-parse HEAD)"

    mkdir -p src/storage src/net src/api
    # 3 lines; destructive (DELETE FROM) + concurrency (threading)
    printf 'import threading\nlock = threading.Lock()\ncursor.execute("DELETE FROM users")\n' > src/storage/db.py
    # 2 lines; io (requests.)
    printf 'import requests\nrequests.get(url)\n' > src/net/client.py
    # 3 lines; untrusted (JSON.parse/req.body) + api (def signature)
    printf 'def handle(req, ctx, extra):\n    data = JSON.parse(req.body)\n    return data\n' > src/api/handler.py
    # 2 lines; root subsystem, no risk surface
    printf '# Project\nDocs here.\n' > README.md
    git add -A && git commit -qm change
}

teardown() {
    cd /
    rm -rf "$REPO"
}

sig() { # sig <KEY> -> value from prepass output
    bash "$PREPASS" "$BASE" | grep "^$1=" | cut -d= -f2-
}

@test "F counts changed files" {
    [ "$(sig F)" = "4" ]
}

@test "D counts distinct subsystems (top-2 path segments, root=.)" {
    [ "$(sig D)" = "4" ]
}

@test "L sums added+deleted lines" {
    [ "$(sig L)" = "10" ]
}

@test "RS is the sorted risk-surface set" {
    [ "$(sig RS)" = "api,concurrency,destructive,io,untrusted" ]
}

@test "reproducible: two runs on the same base are byte-identical" {
    run bash -c "bash '$PREPASS' '$BASE'; echo ---; bash '$PREPASS' '$BASE'"
    a="$(bash "$PREPASS" "$BASE")"
    b="$(bash "$PREPASS" "$BASE")"
    [ "$a" = "$b" ]
}

@test "no base ref → fails loudly (never silently diffs HEAD)" {
    run bash "$PREPASS"
    [ "$status" -ne 0 ]
}

@test "empty diff (base == HEAD) → non-zero, not a zero-signal blob" {
    run bash "$PREPASS" HEAD
    [ "$status" -ne 0 ]
}

@test "single-file single-subsystem change → D=1" {
    printf 'x=1\n' >> src/net/client.py
    git add -A && git commit -qm tweak
    base_one="$(git rev-parse HEAD~1)"
    run bash -c "bash '$PREPASS' '$base_one' | grep '^D=' | cut -d= -f2-"
    [ "$output" = "1" ]
}

@test "P1 #1: RS survives git color.ui=always (prepass forces --no-color)" {
    git config color.ui always
    git config color.diff always
    run bash -c "bash '$PREPASS' '$BASE' | grep '^RS=' | cut -d= -f2-"
    [ -n "$output" ]
    echo "$output" | grep -q destructive
}

@test "P1 #2: destructive long-flags / DROP DATABASE / ORM delete are detected" {
    printf 'os.system("rm --recursive --force /data")\ncursor.execute("DROP DATABASE prod")\nUser.objects.all().delete()\n' > src/storage/wipe.py
    git add -A && git commit -qm wipe
    base_one="$(git rev-parse HEAD~1)"
    run bash -c "bash '$PREPASS' '$base_one' | grep '^RS=' | cut -d= -f2-"
    echo "$output" | grep -q destructive
}

@test "benign diff → RS empty" {
    printf 'plain text line\n' >> README.md
    git add -A && git commit -qm doc
    base_one="$(git rev-parse HEAD~1)"
    run bash -c "bash '$PREPASS' '$base_one' | grep '^RS=' | cut -d= -f2-"
    [ "$output" = "" ]
}
