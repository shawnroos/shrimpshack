#!/usr/bin/env bats

load setup_common

# U5 — bin/work-snapshot.sh, the one document the board reads.
#
# Every scenario runs the script under the fakes and compares the whole
# document with a fixture in tests/fixtures/snapshot/, after the two
# normalisations docs/snapshot.md names. Nothing here reaches herdr, the
# Keychain or Linear.

bats_require_minimum_version 1.5.0

setup() {
    ROOT="${BATS_TEST_DIRNAME}/../.."
    BIN="$ROOT/bin/work-snapshot.sh"
    FIX="${BATS_TEST_DIRNAME}/../fixtures"
    SNAPFIX="$FIX/snapshot"
    # Resolved, because the binding record stores the worktree's real path and
    # the normalisation below has to strip exactly that prefix.
    WORK="$(cd "$(mktemp -d)" && pwd -P)"

    export HERDR_LINEAR_STORE_DIR="$WORK/store"
    export HERDR_LINEAR_PIN_DIR="$WORK/pin"
    export HERDR_LINEAR_SHADOW_LOG="$WORK/shadow.log"
    export HERDR_LINEAR_CURL_BIN="$FIX/fake-linear.sh"
    export HERDR_LINEAR_SECURITY_BIN="$FIX/fake-security.sh"
    export FAKE_SECURITY_STORE_DIR="$WORK/kc"
    export FAKE_LINEAR_RECORD_DIR="$WORK/rec"
    export FAKE_HERDR_RECORD_DIR="$WORK/herdr-rec"
    export LINEAR_CACHE_DIR="$WORK/cache"
    export LINEAR_SECRETS_FILE="$WORK/secrets"
    export HERDR_BIN="$FIX/fake-herdr.sh"
    export FAKE_HERDR_MODE=running
    export FAKE_LINEAR_VIEWS=one
    export FAKE_LINEAR_ISSUES=project
    export HERDR_LINEAR_RETRY_BASE_MS=1
    mkdir -p "$FAKE_LINEAR_RECORD_DIR" "$FAKE_HERDR_RECORD_DIR" "$LINEAR_CACHE_DIR"
    printf 'LINEAR_API_KEY=%s\n' "lin_api""_SNAPSNAPSNAPSNAPSNAP" > "$LINEAR_SECRETS_FILE"

    # shellcheck source=/dev/null
    for f in secrets.sh binding.sh linear.sh; do . "$ROOT/lib/$f"; done

    PROJECT=44444444-4444-4444-8444-444444444444
    VIEW=cccccccc-cccc-4ccc-8ccc-cccccccccccc
    LAYOUT='{"grouping":"workflowState","column_order":[],"hidden":[]}'

    WT="$WORK/worktrees/web-3312"; mkdir -p "$WT"
    git -C "$WT" init -q -b feature/web-3312-separate-background
    git -C "$WT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
    local n
    n="$(herdr_linear::binding_propose "$WT" WEB-3312)"
    herdr_linear::binding_confirm "$WT" WEB-3312 "$n"
    herdr_linear::binding_set_tab "$WT" wA:t1

    n="$(herdr_linear::workspace_propose wA "$PROJECT")"
    herdr_linear::workspace_confirm wA "$PROJECT" "$n"
}

teardown() { [ -n "${WORK:-}" ] && rm -rf "$WORK"; }

refute_match() {   # refute_match <grep-args...> -- fails when grep MATCHES
    if grep "$@"; then
        printf 'refute_match: unexpectedly matched: %s\n' "$*" >&2
        return 1
    fi
}

with_view() { herdr_linear::workspace_set_view wA "$VIEW" "Canvas board" "$LAYOUT"; }

ws_file() { printf '%s/workspaces/%s.json' "$HERDR_LINEAR_STORE_DIR" "$1"; }
binding_file() { printf '%s/bindings/%s.json' "$HERDR_LINEAR_STORE_DIR" "$(herdr_linear::binding_key "$WT")"; }

# The two normalisations of docs/snapshot.md, then a sorted dump so the
# comparison is on the document and not on its whitespace.
normalise() {
    SANDBOX="$WORK" python3 -c '
import json, os, sys
d = json.load(sys.stdin)
sb = os.environ["SANDBOX"]
for issue in d.get("issues", {}).values():
    for b in issue.get("bindings", []):
        p = b.get("worktree_path")
        if isinstance(p, str) and p.startswith(sb):
            b["worktree_path"] = "$SANDBOX" + p[len(sb):]
if isinstance(d.get("linear", {}).get("cache_age_seconds"), (int, float)):
    d["linear"]["cache_age_seconds"] = 0
print(json.dumps(d, sort_keys=True, indent=2))
'
}

# Runs the script and compares its document with a fixture; a mismatch prints
# the diff so the failing key is named.
expect_fixture() {
    local fixture="$1" got want
    run --separate-stderr bash "$BIN" wA
    [ "$status" -eq 0 ] || { printf 'exit %s\nstderr: %s\n' "$status" "$stderr" >&2; return 1; }
    got="$(printf '%s' "$output" | normalise)"
    want="$(normalise < "$SNAPFIX/$fixture")"
    if [ "$got" != "$want" ]; then
        diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") >&2 || true
        return 1
    fi
}

field() {   # field <json> <python-expr over d>
    printf '%s' "$1" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(eval(sys.argv[1]))' "$2"
}

api_calls() { [ -f "$FAKE_LINEAR_RECORD_DIR/argv" ] && wc -l < "$FAKE_LINEAR_RECORD_DIR/argv" | tr -d ' ' || echo 0; }

# Pretty-printed, as bin/linear-cache-refresh.sh writes it: a cache file is
# several lines, never one.
cache_issue() {   # cache_issue <id> <title> <status> <fetchedAt>
    python3 -c '
import json, sys
json.dump({"id": sys.argv[1], "title": sys.argv[2], "project": "AI Canvas Tools",
           "status": sys.argv[3], "fetchedAt": sys.argv[4]}, open(sys.argv[5], "w"), indent=2)
' "$1" "$2" "$3" "$4" "$LINEAR_CACHE_DIR/$1.json"
}

# ------------------------------------------------------- the contract's hashes

# KTD15. The board vendors these fixtures with a sha256 per file in
# crates/board-core/tests/fixtures/linear-snapshot/VERSION; the lines below
# are that file's, so a change on either side fails here or there.
@test "every fixture matches the hash the board pins" {
    local expected="16bc3f5c801a85e5e0c6a6efa438cfd85ab246b02f7a9d8e7ea58431ed34487b  bound-no-view.json
ac1497a0e3dacb3c2eeacb76de43adb051bb8aa1c4169b459a106d1bdd494e04  bound-view-unsupported-grouping.json
81bbcde5ff03f72f1b9b568129ba718345df2e249dde9832ee3753c96b874370  bound-with-view.json
e05f5b0c04f858c7223b2ca9662c0959a37e8723c63ababa7aa11c34515dccb8  herdr-unavailable.json
1c7ee551b373b6a65576ed303debe7c69118886809f75b1d2af6fdc2561d3e2b  linear-unavailable.json
d70ddd3e9e77ef658362b5696623e87c9b7de97b6af3b00b912e76dd288ebc6c  record-unreadable.json
f2c2f12bff7a153bd8ddf4492eaaad28392ad169b3d5abc343c96a786f28dcf7  unbound.json
9eeb74fb70e28e6b32b3d9da9b4f1c571c8c6e12e21d677af89ae3422432dd1c  worktree-missing.json"
    local actual
    actual="$(cd "$SNAPFIX" && shasum -a 256 -- *.json)"
    [ "$(printf '%s' "$actual" | grep -c .)" -eq 8 ]
    [ "$actual" = "$expected" ]
}

# ------------------------------------------------------------ the fixtures

@test "AE1: a bound space with a recorded board view reproduces bound-with-view.json" {
    with_view
    expect_fixture bound-with-view.json
}

@test "AE9: a bound space with no view reproduces bound-no-view.json" {
    expect_fixture bound-no-view.json
}

@test "a view grouped by cycle reproduces bound-view-unsupported-grouping.json" {
    with_view
    export FAKE_LINEAR_VIEW_GROUPING=cycle
    expect_fixture bound-view-unsupported-grouping.json
}

@test "AE2: no record for the id reproduces unbound.json and makes no Linear call" {
    rm -f "$(ws_file wA)"
    expect_fixture unbound.json
    [ "$(api_calls)" = "0" ]
}

@test "AE4: Linear down with a warm cache reproduces linear-unavailable.json" {
    with_view
    cache_issue WEB-3312 "Separate Background leaves an empty layer after reload" "In Progress" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    export FAKE_LINEAR_OUTAGE=http_500
    expect_fixture linear-unavailable.json
    run bash "$BIN" wA
    [ "$(field "$output" 'd["linear"]["cache_age_seconds"] >= 0')" = "True" ]
}

@test "AE12: no keychain entry and no secrets file prints Linear unavailable and never reaches curl" {
    with_view
    rm -f "$LINEAR_SECRETS_FILE"
    run --separate-stderr bash "$BIN" wA
    [ "$status" -eq 0 ]
    [ "$(field "$output" 'd["linear"]["status"]')" = "unavailable" ]
    [ "$(field "$output" 'd["view"]["status"]')" = "unreadable" ]
    [ "$(api_calls)" = "0" ]
}

@test "herdr not running reproduces herdr-unavailable.json" {
    with_view
    export FAKE_HERDR_MODE=not_running
    expect_fixture herdr-unavailable.json
}

@test "a record the loader refuses reproduces record-unreadable.json" {
    # 664 is group-writable, which the loader refuses; 644 is world-readable
    # and accepted, so the plan's "mode 644" case cannot be staged as written.
    chmod 664 "$(ws_file wA)"
    expect_fixture record-unreadable.json
    [ "$(api_calls)" = "0" ]
}

@test "a binding whose worktree directory is gone reproduces worktree-missing.json" {
    with_view
    rm -rf "$WT"
    expect_fixture worktree-missing.json
}

# ------------------------------------------------------------ the details

@test "a binding with tab null, and again with tab empty, carries no tab and no panes" {
    with_view
    local f; f="$(binding_file)"
    local form
    for form in null '""' absent; do
        python3 -c '
import json, sys
p, form = sys.argv[1], sys.argv[2]
d = json.load(open(p))
if form == "absent":
    d.pop("tab", None)
else:
    d["tab"] = json.loads(form)
json.dump(d, open(p, "w"), indent=2)
' "$f" "$form"
        chmod 600 "$f"
        run --separate-stderr bash "$BIN" wA
        [ "$status" -eq 0 ]
        [ "$(field "$output" 'd["issues"]["WEB-3312"]["bindings"][0]["tab"]')" = "None" ]
        [ "$(field "$output" 'd["issues"]["WEB-3312"]["bindings"][0]["panes"]')" = "[]" ]
        # Nothing is inferred from a pane's cwd: the tab whose panes sit in
        # this worktree is unmapped like any other.
        [ "$(field "$output" '[u["tab_id"] for u in d["unmapped"]]')" = "['wA:t1', 'wA:t2']" ]
        [ "$(field "$output" 'd["unmapped"][0]["reason"]')" = "no_binding" ]
    done
}

@test "a rate-limited Linear under the daemon's budget prints a document marked unavailable" {
    with_view
    export FAKE_LINEAR_OUTAGE=rate_limited HERDR_LINEAR_TIMEOUT_SECONDS=8 HERDR_LINEAR_RETRY_MAX=1 HERDR_LINEAR_VIEW_PAGE_MAX=10
    local before after
    before="$(date +%s)"
    run --separate-stderr bash "$BIN" wA
    after="$(date +%s)"
    [ "$status" -eq 0 ]
    [ "$(field "$output" 'd["linear"]["status"]')" = "unavailable" ]
    [ "$(field "$output" 'd["schema"]')" = "1" ]
    # One retry-free call per read and no backoff: well inside the 8s the
    # daemon budgets per call.
    [ $(( after - before )) -lt 8 ]
    [ "$(api_calls)" = "1" ]
}

@test "a live tab with no binding appears under unmapped with reason no_binding" {
    with_view
    run --separate-stderr bash "$BIN" wA
    [ "$status" -eq 0 ]
    [ "$(field "$output" 'd["unmapped"]')" = "[{'label': 'Elsewhere', 'panes': ['wA:p9'], 'reason': 'no_binding', 'tab_id': 'wA:t2'}]" ]
}

@test "a tab claimed by a binding that is not listed carries that binding's state" {
    with_view
    # A second worktree bound to an issue of another project, on tab wA:t2,
    # whose branch has moved since confirmation: effective state proposed.
    local other="$WORK/worktrees/other" n
    mkdir -p "$other"
    git -C "$other" init -q -b feature/x-1
    git -C "$other" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
    n="$(herdr_linear::binding_propose "$other" WEB-9999)"
    herdr_linear::binding_confirm "$other" WEB-9999 "$n"
    herdr_linear::binding_set_tab "$other" wA:t2
    git -C "$other" checkout -q -b feature/x-2
    run --separate-stderr bash "$BIN" wA
    [ "$status" -eq 0 ]
    [ "$(field "$output" 'd["unmapped"][0]["reason"]')" = "proposed" ]
    [ "$(field "$output" 'sorted(d["issues"])')" = "['WEB-3312', 'WEB-3317', 'WEB-3318']" ]
}

@test "an argument that is not an identifier exits 2 with nothing on stdout" {
    run --separate-stderr bash "$BIN" '../x'
    [ "$status" -eq 2 ]
    [ -z "$output" ]
    run --separate-stderr bash "$BIN" ''
    [ "$status" -eq 2 ]
    [ -z "$output" ]
    run --separate-stderr bash "$BIN"
    [ "$status" -eq 2 ]
    [ -z "$output" ]
}

@test "an unknown id with herdr up and listing no such space exits 3 with nothing on stdout" {
    run --separate-stderr bash "$BIN" wZ
    [ "$status" -eq 3 ]
    [ -z "$output" ]
    [ "$(api_calls)" = "0" ]
}

@test "an unknown id with herdr down prints an unbound document with herdr unavailable and exits 0" {
    export FAKE_HERDR_MODE=dead
    run --separate-stderr bash "$BIN" wZ
    [ "$status" -eq 0 ]
    [ "$(field "$output" 'd["record"]')" = "{'project_id': None, 'state': 'unbound', 'status': 'missing'}" ]
    [ "$(field "$output" 'd["herdr"]')" = "{'status': 'unavailable', 'version': None}" ]
    [ "$(field "$output" 'd["workspace"]')" = "{'id': 'wZ', 'label': 'wZ', 'live': None}" ]
}

@test "a proposed workspace record stops before Linear with linear unknown" {
    rm -f "$(ws_file wA)"
    herdr_linear::workspace_propose wA "$PROJECT" >/dev/null
    run --separate-stderr bash "$BIN" wA
    [ "$status" -eq 0 ]
    [ "$(field "$output" 'd["record"]["state"]')" = "proposed" ]
    [ "$(field "$output" 'd["linear"]["status"]')" = "unknown" ]
    [ "$(field "$output" '(d["groups"], d["issues"], d["unmapped"])')" = "([], {}, [])" ]
    [ "$(api_calls)" = "0" ]
}

@test "a view Linear reports as not found falls back to the team's columns and says so" {
    with_view
    export FAKE_LINEAR_VIEW_MISSING=1
    run --separate-stderr bash "$BIN" wA
    [ "$status" -eq 0 ]
    [ "$(field "$output" 'd["view"]["status"]')" = "not_found" ]
    [ "$(field "$output" 'd["view"]["id"]')" = "$VIEW" ]
    [ "$(field "$output" 'd["view"]["layout"]')" = "None" ]
    [ "$(field "$output" '[g["key"] for g in d["groups"]]')" = "['st-backlog', 'st-todo', 'st-prog', 'st-devdone', 'st-done']" ]
    [ "$(field "$output" 'd["linear"]["status"]')" = "ok" ]
}

@test "an archived view is reported as archived and the columns fall back" {
    with_view
    export FAKE_LINEAR_VIEW_ARCHIVED=1
    run --separate-stderr bash "$BIN" wA
    [ "$status" -eq 0 ]
    [ "$(field "$output" 'd["view"]["status"]')" = "archived" ]
    [ "$(field "$output" 'len(d["groups"])')" = "5" ]
}

@test "a view whose columns were never arranged takes the team's order and hides nothing" {
    with_view
    export FAKE_LINEAR_VIEW_PREFS=unarranged
    run --separate-stderr bash "$BIN" wA
    [ "$status" -eq 0 ]
    [ "$(field "$output" 'd["view"]["status"]')" = "ok" ]
    [ "$(field "$output" 'd["view"]["layout"]["column_order"]')" = "[]" ]
    [ "$(field "$output" '[g["key"] for g in d["groups"]]')" = "['st-backlog', 'st-todo', 'st-prog', 'st-devdone', 'st-done', 'st-cancel']" ]
    [ "$(field "$output" 'd["groups"][5]["issues"]')" = "['WEB-3300']" ]
}

@test "a listing that hits the page cap is reported as truncated" {
    export FAKE_LINEAR_ISSUES=capped HERDR_LINEAR_VIEW_PAGE_MAX=2
    run --separate-stderr bash "$BIN" wA
    [ "$status" -eq 0 ]
    [ "$(field "$output" 'd["linear"]')" = "{'cache_age_seconds': None, 'status': 'truncated', 'truncated': True}" ]
}

@test "every string field survives a title and a label containing U+202E only in sanitised form" {
    with_view
    local rlo; rlo="$(printf '\xe2\x80\xae')"
    export FAKE_HERDR_WORKSPACES="wA=Plug${rlo}ins"
    cache_issue WEB-3312 "Separate ${rlo}Background" "In ${rlo}Progress" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    export FAKE_LINEAR_OUTAGE=http_500
    run --separate-stderr bash "$BIN" wA
    [ "$status" -eq 0 ]
    refute_match -F "$rlo" <<< "$output"
    [ "$(field "$output" 'd["workspace"]["label"]')" = "Plugins" ]
    [ "$(field "$output" 'd["issues"]["WEB-3312"]["title"]')" = "Separate Background" ]
    [ "$(field "$output" 'd["groups"][0]["key"]')" = "In Progress" ]
}

@test "under label grouping an issue with no label sits under nolabel" {
    with_view
    export FAKE_LINEAR_VIEW_GROUPING=label FAKE_LINEAR_VIEW_PREFS=unarranged
    run --separate-stderr bash "$BIN" wA
    [ "$status" -eq 0 ]
    [ "$(field "$output" 'd["view"]["layout"]["grouping"]')" = "label" ]
    [ "$(field "$output" '[g["issues"] for g in d["groups"] if g["key"] == "nolabel"][0].count("WEB-3317")')" = "1" ]
    [ "$(field "$output" '[g["label"] for g in d["groups"] if g["key"] == "nolabel"]')" = "['No label']" ]
    [ "$(field "$output" '[g["issues"] for g in d["groups"] if g["key"] == "77777777-7777-4777-8777-777777777777"]')" = "[['WEB-3318']]" ]
    [ "$(field "$output" '"WEB-3317" in d["issues"]')" = "True" ]
}

@test "a binding record the loader would refuse is left out of bindings and unmapped" {
    with_view
    # The worktree is gone, so the record is the only source of this binding;
    # group-writable, it is not one.
    local f; f="$(binding_file)"
    rm -rf "$WT"
    chmod 664 "$f"
    run --separate-stderr bash "$BIN" wA
    [ "$status" -eq 0 ]
    [ "$(field "$output" 'd["issues"]["WEB-3312"]["bindings"]')" = "[]" ]
    [ "$(field "$output" 'sorted(u["tab_id"] for u in d["unmapped"])')" = "['wA:t1', 'wA:t2']" ]
    [ "$(field "$output" '[u["reason"] for u in d["unmapped"]]')" = "['no_binding', 'no_binding']" ]
    refute_match -F worktree_missing <<< "$output"
}

@test "a project with no team takes team_key from the listing" {
    export FAKE_LINEAR_PROJECT_TEAMS=none
    run --separate-stderr bash "$BIN" wA
    [ "$status" -eq 0 ]
    [ "$(field "$output" 'd["project"]["team_key"]')" = "WEB" ]
    [ "$(field "$output" 'd["linear"]["status"]')" = "ok" ]
}

@test "a project spanning several teams takes the first team's key and columns" {
    export FAKE_LINEAR_PROJECT_TEAMS=many FAKE_LINEAR_ISSUES=empty
    run --separate-stderr bash "$BIN" wA
    [ "$status" -eq 0 ]
    [ "$(field "$output" 'd["project"]["team_key"]')" = "WEB" ]
    [ "$(field "$output" '[g["key"] for g in d["groups"]]')" = "['st-backlog', 'st-todo', 'st-prog', 'st-devdone', 'st-done']" ]
}

# The script carries its own copy of the display-control table because it
# cannot shell out to jq per string; this pins the two copies to one another.
@test "clean() in the script strips the same codepoints as HERDR_LINEAR_SANITIZE_JQ_DEF" {
    local got
    got="$(python3 - "$ROOT/lib/sanitize.sh" "$BIN" <<'PY'
import re, sys
lib = open(sys.argv[1]).read()
jq = lib[lib.index("HERDR_LINEAR_SANITIZE_JQ_DEF='"):]
jq = jq[:jq.index("\n'\n")]
script = open(sys.argv[2]).read()
py = script[script.index("def clean("):script.index("def deep_clean(")]
a = sorted(set(int(n) for n in re.findall(r"\b\d+\b", jq)))
b = sorted(set(int(n) for n in re.findall(r"\b\d+\b", py)))
print(len(a) > 10, a == b, sorted(set(a) ^ set(b)))
PY
)"
    [ "$got" = "True True []" ]
}

@test "a crash inside the script prints nothing and exits non-zero" {
    with_view
    # python3 assembles the document; one that dies mid-way is the crash the
    # exit table promises to print nothing for.
    mkdir -p "$WORK/badpy"
    printf '#!/bin/sh\nexit 7\n' > "$WORK/badpy/python3"
    chmod +x "$WORK/badpy/python3"
    run --separate-stderr env PATH="$WORK/badpy:$PATH" bash "$BIN" wA
    [ "$status" -eq 7 ]
    [ -z "$output" ]
}

@test "the fake herdr no longer pins the snapshot to 0.8.2" {
    run --separate-stderr bash "$BIN" wA
    [ "$(field "$output" 'd["herdr"]["version"]')" = "0.9.0" ]
}
