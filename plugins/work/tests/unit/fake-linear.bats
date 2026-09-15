#!/usr/bin/env bats

load setup_common

# U13 — the captured Linear response shapes, and the two boundaries the
# curl-substitute fixture enforces.
#
# The fixture stands in for curl rather than for the API, because the claim
# worth testing is about the INVOCATION: KTD9 says the credential travels on
# stdin via `--config -` and never on argv. Only something in curl's position
# can see argv and fail the run.
#
# These tests exist ahead of U5's client for one reason. Twice in this build a
# fixture was more permissive than the thing it stood in for, and each time the
# gap swallowed a real defect that seven reviewers and the whole suite missed.
# A fixture whose guards are unasserted is the same bet again. When U5 lands it
# consumes this file's shapes; until then this keeps them from rotting silently.

bats_require_minimum_version 1.5.0

setup() {
    FIXTURE="${BATS_TEST_DIRNAME}/../fixtures/fake-linear.sh"
    FAKE_LINEAR_RECORD_DIR="$(mktemp -d)"
    export FAKE_LINEAR_RECORD_DIR
    # Assembled at runtime: written whole it is a credential shape the repo's
    # own secret scan refuses to have in the tree.
    KEYLIKE="lin_api""_FAKEFAKEFAKEFAKEFAKE"
}

teardown() {
    [ -n "${FAKE_LINEAR_RECORD_DIR:-}" ] && rm -rf "$FAKE_LINEAR_RECORD_DIR"
}

# Reads one JSON field out of the fixture's stdout. python3 rather than jq:
# jq is not guaranteed on the box, and these assertions are the reason the
# file exists.
jfield() { python3 -c "$1"; }

@test "the credential on stdin is accepted and recorded as arriving there" {
    run --separate-stderr bash -c \
        "printf 'header = \"Authorization: %s\"\n' '$KEYLIKE' \
         | FAKE_LINEAR_MODE=found_child bash '$FIXTURE' --config - -X POST --data '{\"query\":\"{issue{id}}\"}'"
    [ "$status" -eq 0 ]
    [ "$(tail -1 "$FAKE_LINEAR_RECORD_DIR/auth_on_stdin")" = "yes" ]
}

@test "the credential on argv is refused with 98 -- KTD9's invariant" {
    run bash -c \
        "printf '' | FAKE_LINEAR_MODE=found_child bash '$FIXTURE' -H 'Authorization: $KEYLIKE' --data '{}'"
    [ "$status" -eq 98 ]
}

# Both guards started as enumerations of the ONE form each was tested with,
# which is default-allow: `-u <key>:`, a key in the request body, `--json`,
# `--data-binary` and `--data=<x>` all walked through exit 0. An allowlist never
# closes a class. Both now scan every argument and refuse on the credential
# shape or the `mutation` keyword wherever it appears.
@test "the credential is refused in argv in EVERY form, not only -H" {
    for form in "-u ${KEYLIKE}:" \
                "--header Authorization: ${KEYLIKE}" \
                "-H Authorization: ${KEYLIKE}"; do
        run bash -c "printf '' | FAKE_LINEAR_MODE=found_child bash '$FIXTURE' $form --data '{}'"
        [ "$status" -eq 98 ]
    done
    # and in the request body, where no header name appears at all
    run bash -c "printf '' | FAKE_LINEAR_MODE=found_child bash '$FIXTURE' --data '{\"apiKey\":\"${KEYLIKE}\"}'"
    [ "$status" -eq 98 ]
}

@test "a mutation is refused through EVERY data flag, not only --data" {
    for flag in "--data" "--data-raw" "--data-binary" "--json" "-d"; do
        run bash -c "printf '' | FAKE_LINEAR_MODE=found_child bash '$FIXTURE' $flag '{\"query\":\"mutation{x}\"}'"
        [ "$status" -eq 97 ]
    done
    # and in the --flag=value form, which is not a separate argument at all
    run bash -c "printf '' | FAKE_LINEAR_MODE=found_child bash '$FIXTURE' '--data={\"query\":\"mutation{x}\"}'"
    [ "$status" -eq 97 ]
}

@test "a child issue carries a non-null parent" {
    run bash -c "printf '' | FAKE_LINEAR_UNFILTERED=1 FAKE_LINEAR_MODE=found_child bash '$FIXTURE' --data '{}'"
    [ "$status" -eq 0 ]
    result="$(printf '%s' "$output" | jfield \
        'import sys,json;print(json.load(sys.stdin)["data"]["issue"]["parent"]["identifier"])')"
    [ "$result" = "WEB-2670" ]
}

# The parent case is not the child case minus a field. parent is explicitly
# null and labels.nodes is an empty array rather than absent -- a reader that
# treats "no parent" and "no labels" as missing keys passes on one and breaks
# on the other.
@test "a parent issue has parent null and an empty labels array" {
    run bash -c "printf '' | FAKE_LINEAR_UNFILTERED=1 FAKE_LINEAR_MODE=found_parent bash '$FIXTURE' --data '{}'"
    [ "$status" -eq 0 ]
    result="$(printf '%s' "$output" | jfield \
        'import sys,json;d=json.load(sys.stdin)["data"]["issue"];print(d["parent"],len(d["labels"]["nodes"]))')"
    [ "$result" = "None 0" ]
}

# The trap U5 would otherwise walk into. "No issue came back" arrives in three
# incompatible shapes, and `.data.issue == null` recognises none of them.
@test "not_found sets data to null beside errors, rather than nulling the issue" {
    run bash -c "printf '' | FAKE_LINEAR_UNFILTERED=1 FAKE_LINEAR_MODE=not_found bash '$FIXTURE' --data '{}'"
    result="$(printf '%s' "$output" | jfield \
        'import sys,json;d=json.load(sys.stdin);print("data" in d, d["data"] is None, len(d["errors"]))')"
    [ "$result" = "True True 1" ]
}

@test "auth_error omits the data key entirely" {
    run bash -c "printf '' | FAKE_LINEAR_UNFILTERED=1 FAKE_LINEAR_MODE=auth_error bash '$FIXTURE' --data '{}'"
    result="$(printf '%s' "$output" | jfield \
        'import sys,json;print("data" in json.load(sys.stdin))')"
    [ "$result" = "False" ]
}

@test "validation_error also omits the data key" {
    run bash -c "printf '' | FAKE_LINEAR_UNFILTERED=1 FAKE_LINEAR_MODE=validation_error bash '$FIXTURE' --data '{}'"
    result="$(printf '%s' "$output" | jfield \
        'import sys,json;d=json.load(sys.stdin);print("data" in d, d["errors"][0]["extensions"]["code"])')"
    [ "$result" = "False GRAPHQL_VALIDATION_FAILED" ]
}

@test "a mutation is refused with 97 unless the test permits it -- R30's boundary" {
    run bash -c \
        "printf '' | FAKE_LINEAR_MODE=found_child bash '$FIXTURE' --data '{\"query\":\"mutation { issueUpdate }\"}'"
    [ "$status" -eq 97 ]
}

@test "a permitted mutation is answered" {
    run bash -c \
        "printf '' | FAKE_LINEAR_ALLOW_MUTATION=1 FAKE_LINEAR_MODE=found_child bash '$FIXTURE' --data '{\"query\":\"mutation { issueUpdate }\"}'"
    [ "$status" -eq 0 ]
}

# The rate-limit headers are on every response, not only on a 429, so a client
# can watch its own budget without ever being throttled.
@test "the rate-limit headers appear only when curl was asked for headers" {
    run bash -c "printf '' | FAKE_LINEAR_UNFILTERED=1 FAKE_LINEAR_MODE=found_child bash '$FIXTURE' -i --data '{}'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"x-ratelimit-requests-limit: 2500"* ]]

    run bash -c "printf '' | FAKE_LINEAR_UNFILTERED=1 FAKE_LINEAR_MODE=found_child bash '$FIXTURE' --data '{}'"
    [ "$status" -eq 0 ]
    [[ "$output" != *"x-ratelimit-requests-limit"* ]]
}

# An unknown mode must not answer with an empty body, which a caller would read
# as a successful empty response.
@test "an unknown mode fails loudly instead of answering empty" {
    # --separate-stderr because the point is that STDOUT stays empty while the
    # complaint goes to stderr. Merged, a loud failure and a silent empty
    # response are indistinguishable, which is the case this test exists for.
    run --separate-stderr bash -c "printf '' | FAKE_LINEAR_MODE=nonsense bash '$FIXTURE' --data '{}'"
    [ "$status" -eq 2 ]
    [ -z "$output" ]
    [[ "$stderr" == *"unknown FAKE_LINEAR_MODE"* ]]
}

# Three non-JSON answers a real endpoint gives and a naive parser treats alike.
@test "http_500, empty_body and malformed_json are each distinguishable" {
    run bash -c "printf '' | FAKE_LINEAR_MODE=http_500 bash '$FIXTURE' --data '{}'"
    [[ "$output" == *"Internal Server Error"* ]]

    run bash -c "printf '' | FAKE_LINEAR_MODE=empty_body bash '$FIXTURE' --data '{}'"
    [ -z "$output" ]

    run bash -c "printf '' | FAKE_LINEAR_MODE=malformed_json bash '$FIXTURE' --data '{}'"
    [ "$output" = '{"data":{"issue":' ]
}

# --- the fixture answers the REQUEST, not the mode -------------------------
#
# Served whole, a canned payload answers fields the request never selected, so
# a field deleted from a query in lib/ still arrives and every test stays green.
# That was measured, not supposed: branchName was removed from
# HERDR_LINEAR_ISSUE_FIELDS and the entire suite passed. These pin the filter
# that closed it, in both directions and on both sides of the boundary.

@test "a read answers only the fields the request selected" {
    body='{"query":"query($id:String!){issue(id:$id){identifier state{name}}}"}'
    run bash -c "printf '' | FAKE_LINEAR_MODE=found_child bash '$FIXTURE' --data '$body'"
    [ "$status" -eq 0 ]
    result="$(printf '%s' "$output" | jfield \
        'import sys,json;d=json.load(sys.stdin)["data"]["issue"];print(sorted(d), sorted(d["state"]))')"
    [ "$result" = "['identifier', 'state'] ['name']" ]
}

# The word-matching version of this filter cannot do this one. `updatedAt`
# appears in the request as an ARGUMENT (orderBy:updatedAt) after being dropped
# from the selection, so matching field names against the request text keeps it
# and the mutation walks through.
@test "a field named only in the arguments is still dropped from the answer" {
    body='{"query":"query($f:IssueFilter,$n:Int){issues(first:$n,filter:$f,orderBy:updatedAt){nodes{identifier title}}}"}'
    run bash -c "printf '' | FAKE_LINEAR_MODE=candidates bash '$FIXTURE' --data '$body'"
    [ "$status" -eq 0 ]
    result="$(printf '%s' "$output" | jfield \
        'import sys,json;print(sorted(json.load(sys.stdin)["data"]["issues"]["nodes"][0]))')"
    [ "$result" = "['identifier', 'title']" ]
}

# The write side matters more than it looks: a branchName off a create response
# names a git branch, and an identifier off the same response reaches a
# filesystem path. An over-answering mutation arm hides a dropped field there
# exactly as it did on the read side.
@test "a mutation answers only the fields the mutation selected" {
    body='{"query":"mutation($i:IssueCreateInput!){issueCreate(input:$i){success issue{identifier}}}"}'
    run bash -c "printf '' | FAKE_LINEAR_ALLOW_MUTATION=1 bash '$FIXTURE' --data '$body'"
    [ "$status" -eq 0 ]
    result="$(printf '%s' "$output" | jfield \
        'import sys,json;d=json.load(sys.stdin)["data"]["issueCreate"];print(sorted(d), sorted(d["issue"]))')"
    [ "$result" = "['issue', 'success'] ['identifier']" ]
}

# A request with nothing to filter by is REFUSED, not answered whole. Answering
# it would restore the hole for any body the extractor cannot read, which is
# how the permissive path became the default one in the first place.
@test "a request carrying no query is refused, and says how to ask for the payload whole" {
    run --separate-stderr bash -c \
        "printf '' | FAKE_LINEAR_MODE=found_child bash '$FIXTURE' --data '{}'"
    [ "$status" -eq 95 ]
    [ -z "$output" ]
    [[ "$stderr" == *"FAKE_LINEAR_UNFILTERED"* ]]
}

# KTD8. The organisation arm is routed by content like every other, so it answers
# whatever mode a test happens to be in. Its key is brand-neutral: run-tests.sh's
# brand scan walks tests/fixtures/ too, so the real key here turns the suite red.
@test "the organisation query is answered by content, whatever the mode" {
    for m in found_child found_parent viewer; do
        run bash -c \
            "printf '' | FAKE_LINEAR_MODE=$m bash '$FIXTURE' --data '{\"query\":\"{organization{urlKey}}\"}'"
        [ "$status" -eq 0 ]
        result="$(printf '%s' "$output" | jfield \
            'import sys,json;print(json.load(sys.stdin)["data"]["organization"]["urlKey"])')"
        [ "$result" = "acme" ]
    done
}

# The caller's failure path needs a reachable endpoint that names no organisation.
@test "the organisation arm can answer with no organisation at all" {
    run bash -c \
        "printf '' | FAKE_LINEAR_ORGANIZATION=empty bash '$FIXTURE' --data '{\"query\":\"{organization{urlKey}}\"}'"
    [ "$status" -eq 0 ]
    result="$(printf '%s' "$output" | jfield \
        'import sys,json;print(json.load(sys.stdin)["data"]["organization"])')"
    [ "$result" = "None" ]
}

# The layout builds several columns in one test, and a fixture that answers
# every identifier with the same issue would derive one path for all of them.
@test "echo_issue answers with the identifier that was asked for" {
    for id in WEB-3001 WEB-3002; do
        run bash -c \
            "printf '' | FAKE_LINEAR_MODE=echo_issue bash '$FIXTURE' --data '{\"query\":\"query(\$id:String!){issue(id:\$id){identifier title}}\",\"variables\":{\"id\":\"$id\"}}'"
        [ "$status" -eq 0 ]
        result="$(printf '%s' "$output" | jfield \
            'import sys,json;i=json.load(sys.stdin)["data"]["issue"];print(i["identifier"]+"|"+i["title"])')"
        [ "$result" = "$id|Column $id" ]
    done
}

@test "echo_issue answers a listed missing identifier as not found" {
    run bash -c \
        "printf '' | FAKE_LINEAR_MODE=echo_issue FAKE_LINEAR_MISSING_IDS=WEB-3002 bash '$FIXTURE' --data '{\"query\":\"query(\$id:String!){issue(id:\$id){identifier}}\",\"variables\":{\"id\":\"WEB-3002\"}}'"
    [ "$status" -eq 0 ]
    result="$(printf '%s' "$output" | jfield 'import sys,json;print(json.load(sys.stdin)["data"])')"
    [ "$result" = "None" ]
}

# --- the view arms (U3) -----------------------------------------------------
#
# Routed by body text before the mode, like every arm above. The listing arm
# is keyed on the `$filter:IssueFilter` spelling so the candidate query, which
# spells `$f:IssueFilter`, stays on the mode path it always had.

PROJECT=44444444-4444-4444-8444-444444444444
LIST_Q='query($n:Int,$after:String,$filter:IssueFilter){issues(first:$n,after:$after,filter:$filter){nodes{identifier state{type}} pageInfo{hasNextPage endCursor}}}'

list_body() {   # list_body <filter-json> [after]
    python3 -c 'import sys,json;v={"n":50,"filter":json.loads(sys.argv[2])}
if len(sys.argv)>3: v["after"]=sys.argv[3]
print(json.dumps({"query":sys.argv[1],"variables":v}))' "$LIST_Q" "$@"
}

list_ids() { jfield 'import sys,json;d=json.load(sys.stdin)["data"]["issues"];print(",".join(n["identifier"] for n in d["nodes"]), d["pageInfo"]["hasNextPage"], d["pageInfo"]["endCursor"])'; }

@test "the listing arm applies the request's own filter to its pool" {
    run bash -c "printf '' | bash '$FIXTURE' --data '$(list_body '{"project":{"id":{"eq":"'"$PROJECT"'"}},"state":{"type":{"neq":"canceled"}}}')'"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | list_ids)" = "WEB-3318,WEB-3317,WEB-3312 False None" ]
    # No state clause: the canceled issue is in the pool and comes back.
    run bash -c "printf '' | bash '$FIXTURE' --data '$(list_body '{"project":{"id":{"eq":"'"$PROJECT"'"}}}')'"
    [ "$(printf '%s' "$output" | list_ids)" = "WEB-3318,WEB-3317,WEB-3312,WEB-3300 False None" ]
    # A project the pool does not carry yields nothing, not the pool whole.
    run bash -c "printf '' | bash '$FIXTURE' --data '$(list_body '{"project":{"id":{"eq":"99999999-9999-4999-8999-999999999999"}}}')'"
    [ "$(printf '%s' "$output" | list_ids)" = " False None" ]
}

@test "the listing arm honours and/or wrappers and the completed pool" {
    f='{"and":[{"project":{"id":{"in":["'"$PROJECT"'"]}}},{"or":[{"state":{"type":{"eq":"completed"}}},{"state":{"type":{"eq":"started"}}}]}]}'
    run bash -c "printf '' | FAKE_LINEAR_ISSUES=completed bash '$FIXTURE' --data '$(list_body "$f")'"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | list_ids)" = "WEB-3312,WEB-3303 False None" ]
}

@test "the listing arm ignores the mode, and the candidate spelling ignores the arm" {
    run bash -c "printf '' | FAKE_LINEAR_MODE=not_found bash '$FIXTURE' --data '$(list_body '{}')'"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | list_ids)" = "WEB-3318,WEB-3317,WEB-3312,WEB-3300 False None" ]
    body='{"query":"query($f:IssueFilter,$n:Int){issues(first:$n,filter:$f){nodes{identifier}}}","variables":{"f":{"project":{"id":{"eq":"nope"}}}}}'
    run bash -c "printf '' | FAKE_LINEAR_MODE=candidates bash '$FIXTURE' --data '$body'"
    [ "$status" -eq 0 ]
    result="$(printf '%s' "$output" | jfield 'import sys,json;print(",".join(n["identifier"] for n in json.load(sys.stdin)["data"]["issues"]["nodes"]))')"
    [ "$result" = "WEB-3318,WEB-3317,WEB-3312" ]
}

@test "paged answers two pages through after, and capped never ends" {
    run bash -c "printf '' | FAKE_LINEAR_ISSUES=paged bash '$FIXTURE' --data '$(list_body '{}')'"
    [ "$(printf '%s' "$output" | list_ids)" = "WEB-3318,WEB-3317 True c1" ]
    run bash -c "printf '' | FAKE_LINEAR_ISSUES=paged bash '$FIXTURE' --data '$(list_body '{}' c1)'"
    [ "$(printf '%s' "$output" | list_ids)" = "WEB-3312,WEB-3300 False None" ]
    run bash -c "printf '' | FAKE_LINEAR_ISSUES=capped bash '$FIXTURE' --data '$(list_body '{}' c7)'"
    [ "$(printf '%s' "$output" | list_ids)" = "WEB-3318,WEB-3317,WEB-3312,WEB-3300 True c8" ]
    run bash -c "printf '' | FAKE_LINEAR_ISSUES=empty bash '$FIXTURE' --data '$(list_body '{}')'"
    [ "$(printf '%s' "$output" | list_ids)" = " False None" ]
}

VIEWS_Q='{"query":"query($n:Int,$after:String){customViews(first:$n,after:$after){nodes{id name modelName archivedAt filterData} pageInfo{hasNextPage endCursor}}}","variables":{"n":50}}'

@test "customViews answers none, one or many views by content, whatever the mode" {
    for pair in none:0 one:1 many:7; do
        run bash -c "printf '' | FAKE_LINEAR_MODE=auth_error FAKE_LINEAR_VIEWS=${pair%%:*} bash '$FIXTURE' --data '$VIEWS_Q'"
        [ "$status" -eq 0 ]
        result="$(printf '%s' "$output" | jfield 'import sys,json;print(len(json.load(sys.stdin)["data"]["customViews"]["nodes"]))')"
        [ "$result" = "${pair##*:}" ]
    done
    run bash -c "printf '' | bash '$FIXTURE' --data '$VIEWS_Q'"
    result="$(printf '%s' "$output" | jfield 'import sys,json;v=json.load(sys.stdin)["data"]["customViews"]["nodes"][0];print(v["modelName"], v["filterData"]["and"][0]["project"]["id"]["in"][0])')"
    [ "$result" = "Issue $PROJECT" ]
}

# The `many` list carries every form the matcher has to decide on: the id
# under an `and` wrapper, bare with eq, in a two-project list, another
# project, a Project-model view, an archived one, and a `project` clause with
# no id under it.
@test "the many listing carries the filter forms the matcher must decide on" {
    run bash -c "printf '' | FAKE_LINEAR_VIEWS=many bash '$FIXTURE' --data '$VIEWS_Q'"
    result="$(printf '%s' "$output" | jfield '
import sys,json
vs=json.load(sys.stdin)["data"]["customViews"]["nodes"]
print(sum(1 for v in vs if v["modelName"]=="Project"), sum(1 for v in vs if v["archivedAt"]),
      sum(1 for v in vs if "and" not in v["filterData"] and "project" in v["filterData"]),
      sum(1 for v in vs if json.dumps(v["filterData"]).count("9999")))')"
    [ "$result" = "1 1 1 2" ]
}

VIEW_Q='{"query":"query($id:String!){customView(id:$id){id name archivedAt viewPreferencesValues{layout issueGrouping columnOrderBoard hiddenColumns}}}","variables":{"id":"c9c9c9c9-c9c9-4c9c-8c9c-c9c9c9c9c9c9"}}'

@test "customView(id:) echoes the id asked for, with a board layout" {
    run bash -c "printf '' | bash '$FIXTURE' --data '$VIEW_Q'"
    [ "$status" -eq 0 ]
    result="$(printf '%s' "$output" | jfield 'import sys,json;v=json.load(sys.stdin)["data"]["customView"];p=v["viewPreferencesValues"];print(v["id"], v["archivedAt"], p["layout"], p["issueGrouping"], len(p["columnOrderBoard"]), p["hiddenColumns"][0])')"
    [ "$result" = "c9c9c9c9-c9c9-4c9c-8c9c-c9c9c9c9c9c9 None board workflowState 6 st-cancel" ]
}

@test "customView(id:) can answer archived, another grouping, or unarranged columns" {
    run bash -c "printf '' | FAKE_LINEAR_VIEW_ARCHIVED=1 FAKE_LINEAR_VIEW_GROUPING=cycle bash '$FIXTURE' --data '$VIEW_Q'"
    result="$(printf '%s' "$output" | jfield 'import sys,json;v=json.load(sys.stdin)["data"]["customView"];print(bool(v["archivedAt"]), v["viewPreferencesValues"]["issueGrouping"])')"
    [ "$result" = "True cycle" ]
    run bash -c "printf '' | FAKE_LINEAR_VIEW_PREFS=unarranged bash '$FIXTURE' --data '$VIEW_Q'"
    result="$(printf '%s' "$output" | jfield 'import sys,json;p=json.load(sys.stdin)["data"]["customView"]["viewPreferencesValues"];print(p["columnOrderBoard"], p["hiddenColumns"])')"
    [ "$result" = "None None" ]
    run bash -c "printf '' | FAKE_LINEAR_VIEW_PROJECT=99999999-9999-4999-8999-999999999999 FAKE_LINEAR_UNFILTERED=1 bash '$FIXTURE' --data '$VIEW_Q'"
    result="$(printf '%s' "$output" | jfield 'import sys,json;v=json.load(sys.stdin)["data"]["customView"];print(v["filterData"]["and"][0]["project"]["id"]["in"][0])')"
    [ "$result" = "99999999-9999-4999-8999-999999999999" ]
}

# Captured 2026-09-14: the unknown-view answer has the not_found shape --
# errors[] beside "data": null -- naming the CustomView entity.
@test "customView(id:) on a missing view nulls data beside an INPUT_ERROR" {
    run bash -c "printf '' | FAKE_LINEAR_VIEW_MISSING=1 FAKE_LINEAR_UNFILTERED=1 bash '$FIXTURE' --data '$VIEW_Q'"
    [ "$status" -eq 0 ]
    result="$(printf '%s' "$output" | jfield 'import sys,json;d=json.load(sys.stdin);print(d["data"], d["errors"][0]["extensions"]["code"], "CustomView" in d["errors"][0]["message"])')"
    [ "$result" = "None INPUT_ERROR True" ]
}

CREATE_Q='{"query":"mutation($i:CustomViewCreateInput!){customViewCreate(input:$i){success customView{id}}}","variables":{"i":{"name":"x"}}}'
PREFS_Q='{"query":"mutation($i:ViewPreferencesCreateInput!){viewPreferencesCreate(input:$i){success}}","variables":{"i":{}}}'

@test "the view mutations are refused with 97 unless the test permits them" {
    for b in "$CREATE_Q" "$PREFS_Q"; do
        run --separate-stderr bash -c "printf '' | bash '$FIXTURE' --data '$b'"
        [ "$status" -eq 97 ]
        [ -z "$output" ]
        [[ "$stderr" == *"unpermitted mutation"* ]]
    done
}

@test "a permitted customViewCreate answers success and an id, or success:false on fail" {
    run bash -c "printf '' | FAKE_LINEAR_ALLOW_MUTATION=1 bash '$FIXTURE' --data '$CREATE_Q'"
    [ "$status" -eq 0 ]
    result="$(printf '%s' "$output" | jfield 'import sys,json;d=json.load(sys.stdin)["data"]["customViewCreate"];print(d["success"], d["customView"]["id"])')"
    [ "$result" = "True cccccccc-cccc-4ccc-8ccc-cccccccccccc" ]
    run bash -c "printf '' | FAKE_LINEAR_ALLOW_MUTATION=1 FAKE_LINEAR_MUTATION_RESULT=fail bash '$FIXTURE' --data '$CREATE_Q'"
    result="$(printf '%s' "$output" | jfield 'import sys,json;d=json.load(sys.stdin)["data"]["customViewCreate"];print(d["success"], d["customView"])')"
    [ "$result" = "False None" ]
}

@test "viewPreferencesCreate fails on prefs_fail while customViewCreate still succeeds" {
    run bash -c "printf '' | FAKE_LINEAR_ALLOW_MUTATION=1 FAKE_LINEAR_MUTATION_RESULT=prefs_fail bash '$FIXTURE' --data '$CREATE_Q'"
    [ "$(printf '%s' "$output" | jfield 'import sys,json;print(json.load(sys.stdin)["data"]["customViewCreate"]["success"])')" = "True" ]
    run bash -c "printf '' | FAKE_LINEAR_ALLOW_MUTATION=1 FAKE_LINEAR_MUTATION_RESULT=prefs_fail bash '$FIXTURE' --data '$PREFS_Q'"
    [ "$(printf '%s' "$output" | jfield 'import sys,json;print(json.load(sys.stdin)["data"]["viewPreferencesCreate"]["success"])')" = "False" ]
    run bash -c "printf '' | FAKE_LINEAR_ALLOW_MUTATION=1 bash '$FIXTURE' --data '$PREFS_Q'"
    [ "$(printf '%s' "$output" | jfield 'import sys,json;print(json.load(sys.stdin)["data"]["viewPreferencesCreate"]["success"])')" = "True" ]
}

@test "a teams id filter whose variable is String! is refused the way the real API refuses it" {
    run bash -c "printf '' | bash '$FIXTURE' --config - -d '{\"query\":\"query(\$id:String!){teams(filter:{id:{eq:\$id}},first:1){nodes{id}}}\",\"variables\":{\"id\":\"t\"}}'"
    [ "$status" -eq 0 ]
    [[ "$output" == *GRAPHQL_VALIDATION_FAILED* ]]
    [[ "$output" == *"expecting type"* ]]
    run bash -c "printf '' | bash '$FIXTURE' --config - -d '{\"query\":\"query(\$id:ID!){teams(filter:{id:{eq:\$id}},first:1){nodes{states{nodes{id}}}}}\",\"variables\":{\"id\":\"t\"}}'"
    [ "$status" -eq 0 ]
    [[ "$output" == *st-backlog* ]]
}
